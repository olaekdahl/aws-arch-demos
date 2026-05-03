#!/usr/bin/env bash
# Module 3 — Deploy production-shaped VPC
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net-vpc

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM

aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs" --output table
