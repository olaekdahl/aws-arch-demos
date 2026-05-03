#!/usr/bin/env bash
# Module 12 — Deploy CloudFront + S3 (OAC) + WAF, upload sample object
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-edge-cdn

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml

BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Bucket'].OutputValue" --output text)
URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Url'].OutputValue" --output text)

echo "<h1>Edge demo</h1>" > /tmp/index.html
aws s3 cp /tmp/index.html "s3://$BUCKET/index.html"
rm -f /tmp/index.html

echo "Bucket: $BUCKET"
echo "URL:    $URL"
echo "CloudFront takes ~5 minutes to deploy globally. Then test:"
echo "  curl -I $URL/index.html"
