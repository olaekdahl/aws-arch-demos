# Module 11: Serverless

**Topic:** Lambda, API Gateway, Step Functions, EventBridge, SQS/SNS.
**Focus:** Build a complete event-driven serverless API: API Gateway → Lambda → DynamoDB, plus an async path via EventBridge.

---

## Demo 1: Serverless REST API (CloudFormation, single template)

### 1. Overview
- **What it shows:** HTTP API (API Gateway v2) → Lambda → DynamoDB. POST `/items` writes; GET `/items/{id}` reads. Lambda code is inline.
- **Use case:** Cost-near-zero CRUD service.
- **Services:** API Gateway, Lambda, DynamoDB, IAM, CloudWatch Logs.

### 2. Architecture
```
   Client
     |
     v
[ HTTP API: demo-srv-api ]
     |
     v
[ Lambda: demo-srv-fn  ]
     |
     v
[ DynamoDB: demo-srv-items ]
```

### 3. Prerequisites
- Permissions: `cloudformation:*`, `lambda:*`, `apigateway:*`, `dynamodb:*`, `iam:PassRole`.

### 4. Step-by-Step
```bash
aws cloudformation deploy --region us-east-1 \
  --stack-name demo-srv-api --template-file template.yaml \
  --capabilities CAPABILITY_IAM

URL=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-srv-api \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)

curl -s -X POST $URL/items -H 'content-type: application/json' \
  -d '{"id":"a1","name":"widget"}'
curl -s $URL/items/a1
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 11 — Serverless REST API (HTTP API + Lambda + DDB)

Resources:
  Table:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: demo-srv-items
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions: [{AttributeName: id, AttributeType: S}]
      KeySchema: [{AttributeName: id, KeyType: HASH}]

  Role:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: lambda.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns: [arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]
      Policies:
        - PolicyName: ddb
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action: [dynamodb:GetItem, dynamodb:PutItem]
                Resource: !GetAtt Table.Arn

  Fn:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: demo-srv-fn
      Runtime: python3.12
      Handler: index.handler
      Role: !GetAtt Role.Arn
      Timeout: 10
      Environment: { Variables: { TABLE: !Ref Table } }
      Code:
        ZipFile: |
          import os, json, boto3
          ddb = boto3.resource("dynamodb").Table(os.environ["TABLE"])
          def handler(event, _):
              method = event["requestContext"]["http"]["method"]
              path   = event["requestContext"]["http"]["path"]
              if method == "POST" and path == "/items":
                  body = json.loads(event.get("body") or "{}")
                  if "id" not in body: return _r(400, {"error":"id required"})
                  ddb.put_item(Item=body)
                  return _r(201, body)
              if method == "GET" and path.startswith("/items/"):
                  iid = path.split("/")[-1]
                  r = ddb.get_item(Key={"id": iid}).get("Item")
                  return _r(200, r) if r else _r(404, {"error":"not found"})
              return _r(404, {"error":"route"})
          def _r(s, b): return {"statusCode": s, "headers":{"content-type":"application/json"},
                                "body": json.dumps(b)}

  Api:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: demo-srv-api
      ProtocolType: HTTP
      Target: !GetAtt Fn.Arn

  Perm:
    Type: AWS::Lambda::Permission
    Properties:
      Action: lambda:InvokeFunction
      FunctionName: !Ref Fn
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${Api}/*"

Outputs:
  ApiUrl: { Value: !GetAtt Api.ApiEndpoint }
```

### 6. Validation
```bash
curl -s -X POST $URL/items -H 'content-type: application/json' -d '{"id":"a1","name":"widget"}'
# -> {"id": "a1", "name": "widget"}
curl -s $URL/items/a1
# -> {"id": "a1", "name": "widget"}
```

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-srv-api
```

---

## Demo 2: EventBridge → SQS Fan-out (Python boto3)

### 1. Overview
- **What it shows:** Custom EventBridge bus, two SQS queues subscribed via rules with content-based filtering. Publish events; observe routing.
- **Use case:** Decoupled event-driven microservices.
- **Services:** EventBridge, SQS.

### 2. Architecture
```
[ publisher ] --PutEvents--> [ Bus: demo-srv-bus ]
                              |
                              +--rule: detail.type=order.created--> [ Q: demo-srv-orders ]
                              +--rule: detail.type=alert.fired----> [ Q: demo-srv-alerts ]
```

### 3–5. Code — `demo.py`
```python
"""Module 11 Demo 2 — EventBridge fan-out.
Production split: infra.py, publisher.py, consumer.py."""
import sys, json, time, boto3
from botocore.exceptions import ClientError

REGION = "us-east-1"
BUS = "demo-srv-bus"
QUEUES = {
    "demo-srv-orders": {"detail-type": ["order.created"]},
    "demo-srv-alerts": {"detail-type": ["alert.fired"]},
}
eb  = boto3.client("events", region_name=REGION)
sqs = boto3.client("sqs",    region_name=REGION)
sts = boto3.client("sts")

def up():
    acct = sts.get_caller_identity()["Account"]
    try: eb.create_event_bus(Name=BUS)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceAlreadyExistsException": raise

    for qn, pattern in QUEUES.items():
        q = sqs.create_queue(QueueName=qn)["QueueUrl"]
        arn = sqs.get_queue_attributes(QueueUrl=q, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        # Allow EventBridge to send
        sqs.set_queue_attributes(QueueUrl=q, Attributes={"Policy": json.dumps({
            "Version":"2012-10-17","Statement":[{
                "Effect":"Allow","Principal":{"Service":"events.amazonaws.com"},
                "Action":"sqs:SendMessage","Resource":arn,
                "Condition":{"ArnLike":{"aws:SourceArn":f"arn:aws:events:{REGION}:{acct}:rule/{BUS}/*"}}}]})})
        rule = f"{qn}-rule"
        eb.put_rule(Name=rule, EventBusName=BUS, EventPattern=json.dumps(pattern))
        eb.put_targets(Rule=rule, EventBusName=BUS, Targets=[{"Id":"1","Arn":arn}])
    print("Infra ready.")

def publish():
    eb.put_events(Entries=[
        {"EventBusName": BUS, "Source": "demo.app", "DetailType": "order.created",
         "Detail": json.dumps({"orderId": "1001"})},
        {"EventBusName": BUS, "Source": "demo.app", "DetailType": "alert.fired",
         "Detail": json.dumps({"severity": "high"})},
    ])
    print("Published 2 events.")

def receive():
    time.sleep(3)
    for qn in QUEUES:
        url = sqs.get_queue_url(QueueName=qn)["QueueUrl"]
        msgs = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=2).get("Messages", [])
        print(f"{qn}: {len(msgs)} msg(s)")
        for m in msgs:
            print("  ", m["Body"][:120])
            sqs.delete_message(QueueUrl=url, ReceiptHandle=m["ReceiptHandle"])

def down():
    for qn in QUEUES:
        rule = f"{qn}-rule"
        try:
            eb.remove_targets(Rule=rule, EventBusName=BUS, Ids=["1"])
            eb.delete_rule(Name=rule, EventBusName=BUS)
        except ClientError: pass
        try: sqs.delete_queue(QueueUrl=sqs.get_queue_url(QueueName=qn)["QueueUrl"])
        except ClientError: pass
    try: eb.delete_event_bus(Name=BUS)
    except ClientError: pass
    print("Cleanup done.")

if __name__ == "__main__":
    {"up":up,"publish":publish,"receive":receive,"down":down}[sys.argv[1]]()
```

### 6. Validation
```bash
python3 demo.py deploy
python3 demo.py publish
python3 demo.py receive
# Expect: demo-srv-orders: 1 msg(s), demo-srv-alerts: 1 msg(s)
```

### 7. Cleanup
```bash
python3 demo.py cleanup
```
