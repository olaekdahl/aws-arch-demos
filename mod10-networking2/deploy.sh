#!/usr/bin/env bash
# Module 10 — Deploy TGW hub-and-spoke and ping cross-VPC
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net2-tgw

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM

A=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceA'].OutputValue" --output text)
B_IP=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceBPrivateIp'].OutputValue" --output text)

echo "Waiting 90s for SSM agent registration…"
sleep 90

echo "Pinging $B_IP from instance A ($A) via TGW…"
CID=$(aws ssm send-command --region "$REGION" --instance-ids "$A" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"ping -c 3 $B_IP\"]" \
  --query 'Command.CommandId' --output text)
sleep 8
aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CID" --instance-id "$A" \
  --query '{Status:Status,Output:StandardOutputContent}'
