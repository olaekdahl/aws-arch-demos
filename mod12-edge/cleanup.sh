#!/usr/bin/env bash
# Module 12 — Empty bucket then delete stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-edge-cdn

BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Bucket'].OutputValue" --output text 2>/dev/null || true)
if [[ -n "${BUCKET:-}" ]]; then
  aws s3 rm "s3://$BUCKET" --recursive || true
fi
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
