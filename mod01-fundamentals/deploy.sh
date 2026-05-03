#!/usr/bin/env bash
# Module 1 — Deploy multi-AZ ALB + EC2 stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-fundamentals-multiaz

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM

URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AlbUrl'].OutputValue" --output text)
echo "ALB URL: $URL"
echo "Test (alternates between AZs):"
for i in 1 2 3 4 5 6; do curl -s "$URL"; done
