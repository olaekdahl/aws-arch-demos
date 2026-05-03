# Module 6: Database Services

**Topic:** RDS, Aurora, DynamoDB, ElastiCache — relational vs NoSQL, managed vs self-hosted.
**Focus:** Provision a DynamoDB table with on-demand pricing + GSI, and an RDS-equivalent demo via Aurora Serverless v2 (alternative).

---

## Demo 1: DynamoDB Single-Table Design with GSI (Python boto3)

### 1. Overview
- **What it shows:** Create a DynamoDB on-demand table using single-table-design (PK/SK), add a GSI for an alternate access pattern, perform writes + queries.
- **Use case:** Cost-effective, auto-scaling NoSQL backend for a SaaS app (orders by customer + by status).
- **Services:** DynamoDB.

### 2. Architecture
```
[boto3 client]
    |
    v
[ Table: demo-db-orders  PK=PK SK=SK  PAY_PER_REQUEST  PITR=ON ]
    |     PK=CUSTOMER#<id>   SK=ORDER#<orderId>
    |
    +--> [GSI1]  PK=GSI1PK=STATUS#<status>  SK=GSI1SK=<createdAt>

Access patterns:
  - Get all orders for a customer  -> Query main table by PK
  - Get all orders by status       -> Query GSI1 by GSI1PK
```

### 3. Prerequisites
- Permissions: `dynamodb:*` on `demo-db-orders`.

### 4. Step-by-Step
```bash
python3 demo.py deploy
python3 demo.py seed
python3 demo.py query
python3 demo.py cleanup
```

### 5. Code — `demo.py`
```python
"""Module 6 Demo 1 — DynamoDB single-table + GSI.
Production split: schema.py, repository.py, app.py."""
import sys, time, boto3
from botocore.exceptions import ClientError

REGION = "us-east-1"
TABLE  = "demo-db-orders"
ddb  = boto3.client("dynamodb", region_name=REGION)
res  = boto3.resource("dynamodb", region_name=REGION)

def up():
    try:
        ddb.create_table(
            TableName=TABLE,
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName":"PK","AttributeType":"S"},
                {"AttributeName":"SK","AttributeType":"S"},
                {"AttributeName":"GSI1PK","AttributeType":"S"},
                {"AttributeName":"GSI1SK","AttributeType":"S"}],
            KeySchema=[
                {"AttributeName":"PK","KeyType":"HASH"},
                {"AttributeName":"SK","KeyType":"RANGE"}],
            GlobalSecondaryIndexes=[{
                "IndexName":"GSI1",
                "KeySchema":[
                    {"AttributeName":"GSI1PK","KeyType":"HASH"},
                    {"AttributeName":"GSI1SK","KeyType":"RANGE"}],
                "Projection":{"ProjectionType":"ALL"}}])
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException": raise
    ddb.get_waiter("table_exists").wait(TableName=TABLE)
    ddb.update_continuous_backups(TableName=TABLE,
        PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": True})
    print(f"Table {TABLE} ready (PITR on).")

def seed():
    t = res.Table(TABLE)
    items = [
        {"PK":"CUSTOMER#alice","SK":"ORDER#1001","status":"NEW","total":99.50,
         "GSI1PK":"STATUS#NEW","GSI1SK":"2026-05-01T10:00"},
        {"PK":"CUSTOMER#alice","SK":"ORDER#1002","status":"SHIPPED","total":42.00,
         "GSI1PK":"STATUS#SHIPPED","GSI1SK":"2026-05-02T11:00"},
        {"PK":"CUSTOMER#bob","SK":"ORDER#1003","status":"NEW","total":120.00,
         "GSI1PK":"STATUS#NEW","GSI1SK":"2026-05-02T12:00"},
    ]
    with t.batch_writer() as bw:
        for it in items: bw.put_item(Item=it)
    print(f"Seeded {len(items)} orders.")

def query():
    t = res.Table(TABLE)
    print("All orders for alice:")
    r = t.query(KeyConditionExpression=boto3.dynamodb.conditions.Key("PK").eq("CUSTOMER#alice"))
    for i in r["Items"]: print(" ", i)
    print("All NEW orders (via GSI1):")
    r = t.query(IndexName="GSI1",
        KeyConditionExpression=boto3.dynamodb.conditions.Key("GSI1PK").eq("STATUS#NEW"))
    for i in r["Items"]: print(" ", i)

def down():
    try: ddb.delete_table(TableName=TABLE); print("Deleting…")
    except ClientError as e: print(e)

if __name__ == "__main__":
    {"up": up, "seed": seed, "query": query, "down": down}[sys.argv[1]]()
```

### 6. Validation
- `query` returns 2 orders for alice and 2 NEW orders (alice + bob).

### 7. Cleanup
```bash
python3 demo.py cleanup
```

---

## Demo 2: Aurora Serverless v2 PostgreSQL (CloudFormation, optional)

### 1. Overview
- **What it shows:** Create a small Aurora Serverless v2 PostgreSQL cluster (0.5–2 ACU), connect via Data API — no client driver needed.
- **Services:** RDS Aurora, Secrets Manager.
- **Cost note:** Serverless v2 minimum 0.5 ACU ≈ $0.06/hr — tear down ASAP.

### 2. Architecture
```
[ Aurora Serverless v2 cluster: demo-db-aurora-pg ]
   - Engine: aurora-postgresql 16
   - Min/Max ACU: 0.5 / 2
   - Data API: ENABLED
   - Secret: demo-db-aurora-secret  (Secrets Manager)

[ aws rds-data execute-statement ] --> Aurora (no driver)
```

### 3. Prerequisites
- Default VPC + 2 subnets in different AZs.

### 4. Step-by-Step
```bash
aws cloudformation deploy --region us-east-1 \
  --stack-name demo-db-aurora --template-file template.yaml \
  --capabilities CAPABILITY_IAM

CLUSTER_ARN=$(aws cloudformation describe-stacks --stack-name demo-db-aurora \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterArn'].OutputValue" --output text)
SECRET_ARN=$(aws cloudformation describe-stacks --stack-name demo-db-aurora \
  --query "Stacks[0].Outputs[?OutputKey=='SecretArn'].OutputValue" --output text)

aws rds-data execute-statement --region us-east-1 \
  --resource-arn "$CLUSTER_ARN" --secret-arn "$SECRET_ARN" \
  --database postgres --sql "select version();"
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 6 Demo 2 — Aurora Serverless v2 with Data API

Parameters:
  VpcId:
    Type: AWS::EC2::VPC::Id
  SubnetIds:
    Type: List<AWS::EC2::Subnet::Id>

Resources:
  Secret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: demo-db-aurora-secret
      GenerateSecretString:
        SecretStringTemplate: '{"username":"appuser"}'
        GenerateStringKey: password
        ExcludeCharacters: '"@/\'
        PasswordLength: 24

  SubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupDescription: demo
      SubnetIds: !Ref SubnetIds

  Sg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: aurora
      VpcId: !Ref VpcId

  Cluster:
    Type: AWS::RDS::DBCluster
    Properties:
      DBClusterIdentifier: demo-db-aurora-pg
      Engine: aurora-postgresql
      EngineVersion: "16.4"
      DatabaseName: postgres
      MasterUsername: !Sub '{{resolve:secretsmanager:${Secret}::username}}'
      MasterUserPassword: !Sub '{{resolve:secretsmanager:${Secret}::password}}'
      DBSubnetGroupName: !Ref SubnetGroup
      VpcSecurityGroupIds: [!Ref Sg]
      EnableHttpEndpoint: true
      ServerlessV2ScalingConfiguration:
        MinCapacity: 0.5
        MaxCapacity: 2
      StorageEncrypted: true

  Instance:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceIdentifier: demo-db-aurora-pg-instance
      DBClusterIdentifier: !Ref Cluster
      DBInstanceClass: db.serverless
      Engine: aurora-postgresql

Outputs:
  ClusterArn: { Value: !Sub "arn:aws:rds:${AWS::Region}:${AWS::AccountId}:cluster:${Cluster}" }
  SecretArn:  { Value: !Ref Secret }
```

### 6. Validation
- `execute-statement` returns the PostgreSQL version string.

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-db-aurora
```
