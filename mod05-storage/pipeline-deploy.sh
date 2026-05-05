#!/usr/bin/env bash
# Module 5 Demo 3 — deploy S3 -> Lambda -> DynamoDB pipeline, upload a sample
# CSV, and verify items land in DynamoDB.
set -euo pipefail
REGION="us-east-1"
STACK="demo-pipeline"
TEMPLATE="$(dirname "$0")/pipeline-template.yaml"

ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="demo-pipeline-uploads-${ACCT}-${REGION}"
FN="demo-pipeline-processor"
TABLE="demo-pipeline-records"

echo "==> Deploying stack $STACK in $REGION"
aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM

# Wire S3 -> Lambda. Done out-of-band to avoid the CFN circular dep between
# the bucket's NotificationConfiguration and the Lambda invoke permission.
echo "==> Attaching S3 ObjectCreated notification -> $FN"
FN_ARN=$(aws lambda get-function --region "$REGION" --function-name "$FN" \
  --query 'Configuration.FunctionArn' --output text)
aws s3api put-bucket-notification-configuration --region "$REGION" \
  --bucket "$BUCKET" \
  --notification-configuration "$(cat <<JSON
{
  "LambdaFunctionConfigurations": [{
    "Id": "csv-and-json",
    "LambdaFunctionArn": "$FN_ARN",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "incoming/"}]}}
  }]
}
JSON
)"

echo "==> Uploading sample CSV"
TMP=$(mktemp --suffix=.csv)
cat >"$TMP" <<'CSV'
id,name,amount
1,alice,12.50
2,bob,7.25
3,carol,99.00
CSV
KEY="incoming/sample-$(date +%s).csv"
aws s3 cp --region "$REGION" "$TMP" "s3://$BUCKET/$KEY" >/dev/null
rm -f "$TMP"
echo "    s3://$BUCKET/$KEY"

echo "==> Waiting for Lambda to process (polling DynamoDB)"
for i in $(seq 1 20); do
  COUNT=$(aws dynamodb query --region "$REGION" \
    --table-name "$TABLE" \
    --key-condition-expression "pk = :k" \
    --expression-attribute-values "{\":k\":{\"S\":\"$KEY\"}}" \
    --select COUNT --query Count --output text 2>/dev/null || echo 0)
  if [[ "$COUNT" -gt 0 ]]; then
    echo "    Found $COUNT items after ${i}s"
    break
  fi
  sleep 1
done

echo "==> Sample items in DynamoDB ($TABLE):"
aws dynamodb query --region "$REGION" \
  --table-name "$TABLE" \
  --key-condition-expression "pk = :k" \
  --expression-attribute-values "{\":k\":{\"S\":\"$KEY\"}}" \
  --query 'Items' --output json

cat <<EOF

Done. Try uploading more files:
  aws s3 cp <file>.csv  s3://$BUCKET/incoming/
  aws s3 cp <file>.json s3://$BUCKET/incoming/

View Lambda logs:
  aws logs tail /aws/lambda/$FN --region $REGION --follow

Tear down:
  ./pipeline-teardown.sh
EOF
