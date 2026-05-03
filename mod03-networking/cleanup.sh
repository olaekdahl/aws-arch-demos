#!/usr/bin/env bash
# Module 3 — Tear down VPC stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net-vpc
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
