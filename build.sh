#!/usr/bin/env bash
set -e
$(aws ecr get-login --no-include-email --region us-east-1)
docker build -t init-aws-swarm .
docker tag init-aws-swarm:latest 812177567419.dkr.ecr.us-east-1.amazonaws.com/init-aws-swarm:latest
docker push 812177567419.dkr.ecr.us-east-1.amazonaws.com/init-aws-swarm:latest
