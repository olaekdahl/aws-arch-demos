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
