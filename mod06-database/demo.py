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
