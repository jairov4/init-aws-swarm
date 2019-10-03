#!/bin/bash
SWARM_PORT=2377
MAX_TRIES=10

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
export AWS_DEFAULT_REGION="$REGION"
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
NODE_TYPE=$(aws ec2 describe-tags --filters \
  "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=swarm-node-type" | jq -r .Tags[0].Value)

# Poor man's Debugger
echo "DYNAMODB_TABLE=$DYNAMODB_TABLE"
echo "NODE_TYPE=$NODE_TYPE"
echo "INSTANCE_ID=$INSTANCE_ID"
echo "PRIVATE_IP=$PRIVATE_IP"

# Validation
if [[ -z "$NODE_TYPE" ]]; then
  echo "No node type"
  exit 92
fi

if [[ -z "$DYNAMODB_TABLE" ]]; then
  echo "No DynamoDB table configured"
  exit 93
fi

managers() { aws ec2 describe-instances --filters \
  'Name=tag:swarm-node-type,Values=manager' 'Name=instance-state-name,Values=running' |
  jq -r '.Reservations[] | .Instances[] | .PrivateIpAddress'; }
manager_token() { aws dynamodb get-item --table-name "$DYNAMODB_TABLE" \
  --key '{"id":{"S": "manager_token"}}' | jq -r '.Item.value.S'; }
worker_token() { aws dynamodb get-item --table-name "$DYNAMODB_TABLE" \
  --key '{"id":{"S": "worker_token"}}' | jq -r '.Item.value.S'; }

swarm_state() { docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//'; }
swarm_id() { docker info | grep ClusterID | cut -f2 -d: | sed -e 's/^[ \t]*//'; }
node_id() { docker info | grep NodeID | cut -f2 -d: | sed -e 's/^[ \t]*//'; }
swarm_is_active() { [[ "$(swarm_state)" == active ]]; }
swarm_token() { ([[ "$NODE_TYPE" == manager ]] && manager_token) || worker_token; }
delete_token() {
  aws dynamodb delete-item --table-name "$DYNAMODB_TABLE" --key '{"id":{"S": "manager_token"}}' \
    --condition-expression 'attribute_exists(id)'
  aws dynamodb delete-item --table-name "$DYNAMODB_TABLE" --key '{"id":{"S": "worker_token"}}' \
    --condition-expression 'attribute_exists(id)'
}

join() {
  TOKEN="$(swarm_token)"
  [[ -n "$TOKEN" ]] || return 1
  for MANAGER_IP in $(managers); do
    [[ "$MANAGER_IP" != "$PRIVATE_IP" ]] || continue
    echo "Joining to $MANAGER_IP"
    docker swarm leave --force || echo "Left previous swarm"
    docker swarm join --token "$TOKEN" \
      --listen-addr "$PRIVATE_IP:$SWARM_PORT" \
      --advertise-addr "$PRIVATE_IP:$SWARM_PORT" \
      "$MANAGER_IP:$SWARM_PORT" || echo "Waiting to see if swarm goes up"
    local N=0
    until swarm_is_active || ((N == MAX_TRIES)); do
      ((N += 1))
      echo "Sleeping for 30 secs"
      sleep 10
    done
    if swarm_is_active; then return 0; fi
  done
  return 1
}

new_cluster() {
  [[ "$NODE_TYPE" == manager ]] || return 1
  if [[ -z "$(swarm_token)" ]] || delete_token; then
    echo "Initializing new cluster"
    docker swarm leave --force || echo "Left previous swarm"
    docker swarm init \
      --listen-addr "$PRIVATE_IP:$SWARM_PORT" \
      --advertise-addr "$PRIVATE_IP:$SWARM_PORT"

    # Get the join tokens and add them to dynamodb
    MANAGER_TOKEN=$(docker swarm join-token manager | grep token | awk '{ print $5 }')
    WORKER_TOKEN=$(docker swarm join-token worker | grep token | awk '{ print $5 }')

    echo "Storing tokens"
    aws dynamodb put-item \
      --table-name "$DYNAMODB_TABLE" \
      --item '{"id":{"S": "manager_token"},"value": {"S":"'"$MANAGER_TOKEN"'"}}' \
      --condition-expression 'attribute_not_exists(id)' \
    && aws dynamodb put-item \
        --table-name "$DYNAMODB_TABLE" \
        --item '{"id":{"S": "worker_token"},"value": {"S":"'"$WORKER_TOKEN"'"}}'
  else
    echo 'Other manager is initializing new cluster'
    return 1
  fi
}

finish() {
  echo "Show current status"
  docker info
  echo "Create tags for current instance"
  aws ec2 create-tags --resource "$INSTANCE_ID" --tags \
    "Key=swarm-node-id,Value=$(node_id)" "Key=swarm-id,Value=$(swarm_id)"
}

main() {
  local N=0
  until ((N == MAX_TRIES)); do
    ((N += 1))
    echo "Round $N"
    if join || new_cluster; then
      finish
      exit 0
    fi
    sleep 10
  done
  exit 1
}

main
