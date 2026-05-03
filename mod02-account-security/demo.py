"""Module 2 — Least-privilege IAM role + simulator.
Production split: roles.py, policies.py, simulator.py.
"""
import sys, json, boto3
from botocore.exceptions import ClientError

ROLE = "demo-iam-app-role"
POLICY = "demo-iam-app-policy"
BUCKET_PREFIX = "demo-iam-app-data"

TRUST = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole",
    }],
}

DOC = {
    "Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Action": ["s3:GetObject"],
         "Resource": [f"arn:aws:s3:::{BUCKET_PREFIX}-*/*"]},
        {"Effect": "Allow", "Action": ["s3:ListBucket"],
         "Resource": [f"arn:aws:s3:::{BUCKET_PREFIX}-*"]},
    ],
}

iam = boto3.client("iam")

def create():
    try:
        role = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(TRUST))
        print("Role:", role["Role"]["Arn"])
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists": raise
        print("Role exists.")
    try:
        pol = iam.create_policy(PolicyName=POLICY, PolicyDocument=json.dumps(DOC))
        arn = pol["Policy"]["Arn"]
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists": raise
        acct = boto3.client("sts").get_caller_identity()["Account"]
        arn = f"arn:aws:iam::{acct}:policy/{POLICY}"
    iam.attach_role_policy(RoleName=ROLE, PolicyArn=arn)
    print("Attached:", arn)

def simulate():
    acct = boto3.client("sts").get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{acct}:role/{ROLE}"
    cases = [
        ("s3:GetObject",   f"arn:aws:s3:::{BUCKET_PREFIX}-prod/file.txt", "allowed"),
        ("s3:GetObject",   "arn:aws:s3:::other-bucket/file.txt",          "implicitDeny"),
        ("s3:DeleteObject",f"arn:aws:s3:::{BUCKET_PREFIX}-prod/file.txt", "implicitDeny"),
    ]
    for action, resource, expect in cases:
        r = iam.simulate_principal_policy(
            PolicySourceArn=role_arn, ActionNames=[action], ResourceArns=[resource])
        verdict = r["EvaluationResults"][0]["EvalDecision"]
        ok = "OK" if verdict == expect else "MISMATCH"
        print(f"[{ok}] {action} on {resource} -> {verdict} (expected {expect})")

def cleanup():
    acct = boto3.client("sts").get_caller_identity()["Account"]
    arn = f"arn:aws:iam::{acct}:policy/{POLICY}"
    try: iam.detach_role_policy(RoleName=ROLE, PolicyArn=arn)
    except ClientError: pass
    try: iam.delete_role(RoleName=ROLE)
    except ClientError: pass
    try: iam.delete_policy(PolicyArn=arn)
    except ClientError: pass
    print("Cleanup done.")

if __name__ == "__main__":
    {"create": create, "simulate": simulate, "cleanup": cleanup}[sys.argv[1]]()
