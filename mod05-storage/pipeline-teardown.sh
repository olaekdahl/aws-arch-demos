#!/usr/bin/env bash
# Module 5 Demo 3 — tear down the S3 -> Lambda -> DynamoDB pipeline.
set -euo pipefail
REGION="us-east-1"
STACK="demo-pipeline"

ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="demo-pipeline-uploads-${ACCT}-${REGION}"

# CFN can't delete a non-empty bucket, so empty it first. The pipeline bucket
# isn't versioned, so a recursive rm is sufficient.
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "==> Emptying s3://$BUCKET"
  aws s3 rm --region "$REGION" "s3://$BUCKET" --recursive >/dev/null
fi

echo "==> Deleting stack $STACK"
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"

# Lambda log group is created by the runtime, not CFN — clean it up so reruns
# start fresh.
aws logs delete-log-group --region "$REGION" \
  --log-group-name "/aws/lambda/demo-pipeline-processor" 2>/dev/null || true

echo "Done."
