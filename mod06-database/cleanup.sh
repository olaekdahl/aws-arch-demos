#!/usr/bin/env bash
# Module 6 Demo 2 — Tear down Aurora stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-db-aurora
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
