#!/usr/bin/env bash
# Module 3 — Validate route tables + flow logs for the deployed VPC
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net-vpc

VPC=$(aws cloudformation describe-stacks --region "$REGION" \
  --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text)
echo "VPC: $VPC"

echo
echo "== Route tables =="
aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'RouteTables[*].{RT:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[*].[DestinationCidrBlock,GatewayId,NatGatewayId]}' \
  --output json

echo
echo "== Recent flow log records (last 5 min) =="
aws logs tail /demo/vpc/flowlogs --region "$REGION" --since 5m 2>/dev/null \
  || echo "(no records yet — flow logs typically appear within a few minutes of deploy)"
