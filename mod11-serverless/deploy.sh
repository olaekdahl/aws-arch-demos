#!/usr/bin/env bash
# Module 11 — Deploy serverless REST API and exercise it
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-srv-api

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM

URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
echo "API: $URL"
echo "POST /items:"
curl -s -X POST "$URL/items" -H 'content-type: application/json' \
  -d '{"id":"a1","name":"widget"}'; echo
echo "GET /items/a1:"
curl -s "$URL/items/a1"; echo
