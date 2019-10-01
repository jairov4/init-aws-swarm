#!/usr/bin/env bash
set -e
TAG=$(git describe --dirty --tags)
$(aws ecr get-login --no-include-email --region us-east-1)
docker build -t init-aws-swarm .
docker tag init-aws-swarm:latest 812177567419.dkr.ecr.us-east-1.amazonaws.com/init-aws-swarm:$TAG
docker push 812177567419.dkr.ecr.us-east-1.amazonaws.com/init-aws-swarm:$TAG
