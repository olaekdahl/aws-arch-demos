#!/usr/bin/env bash
# Module 5 Demo 3 — tear down the S3 -> Lambda -> DynamoDB pipeline.
set -euo pipefail
REGION="us-east-1"
STACK="demo-pipeline"

ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="demo-pipeline-uploads-${ACCT}-${REGION}"

# CFN can't delete a non-empty bucket, so empty it first.
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "==> Emptying s3://$BUCKET (objects + versions + delete markers)"
  aws s3api delete-objects --region "$REGION" --bucket "$BUCKET" \
    --delete "$(aws s3api list-object-versions --region "$REGION" --bucket "$BUCKET" \
      --query '{Objects: (Versions[].{Key:Key,VersionId:VersionId} || `[]`) + (DeleteMarkers[].{Key:Key,VersionId:VersionId} || `[]`)}' \
      --output json)" >/dev/null 2>&1 || true
  aws s3 rm --region "$REGION" "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
fi

echo "==> Deleting stack $STACK"
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"

# Lambda log group is created by the runtime, not CFN — clean it up so reruns
# start fresh.
aws logs delete-log-group --region "$REGION" \
  --log-group-name "/aws/lambda/demo-pipeline-processor" 2>/dev/null || true

echo "Done."
