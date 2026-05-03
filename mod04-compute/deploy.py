"""Module 4 Demo 2 — Lambda quickstart.
In production: separate IaC (CFN/Terraform), src/, tests/."""
import sys, json, time, io, zipfile, boto3
from botocore.exceptions import ClientError

REGION = "us-east-1"
FN     = "demo-compute-hello"
ROLE   = "demo-compute-lambda-role"

HANDLER_SRC = '''
import os, json
def handler(event, context):
    return {"region": os.environ.get("AWS_REGION"),
            "echo": event,
            "msg": "Hello from Lambda"}
'''

iam, lam, sts = boto3.client("iam"), boto3.client("lambda", region_name=REGION), boto3.client("sts")

def _zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("app.py", HANDLER_SRC)
    return buf.getvalue()

def deploy():
    try:
        r = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(
            {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
              "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}))
        role_arn = r["Role"]["Arn"]
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists": raise
        role_arn = f"arn:aws:iam::{sts.get_caller_identity()['Account']}:role/{ROLE}"
    iam.attach_role_policy(RoleName=ROLE,
        PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
    time.sleep(10)
    try:
        lam.create_function(FunctionName=FN, Runtime="python3.12", Role=role_arn,
            Handler="app.handler", Code={"ZipFile": _zip()}, Timeout=10)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceConflictException": raise
        lam.update_function_code(FunctionName=FN, ZipFile=_zip())
    print(f"Deployed {FN}")

def invoke():
    r = lam.invoke(FunctionName=FN, Payload=json.dumps({"hello":"world"}).encode())
    print(r["Payload"].read().decode())

def cleanup():
    try: lam.delete_function(FunctionName=FN)
    except ClientError: pass
    try:
        iam.detach_role_policy(RoleName=ROLE,
          PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
        iam.delete_role(RoleName=ROLE)
    except ClientError: pass
    print("Done.")

if __name__ == "__main__":
    {"deploy": deploy, "invoke": invoke, "cleanup": cleanup}[sys.argv[1]]()
