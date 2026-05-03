#!/usr/bin/env bash
# Module 1 — Tear down stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-fundamentals-multiaz
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
echo "Delete initiated. Waiting…"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
