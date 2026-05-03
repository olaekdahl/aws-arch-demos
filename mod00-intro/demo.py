"""
Module 0 Demo — Account discovery + Well-Architected workload creation.
In production, split into: inventory.py, wellarchitected.py, cli.py.
"""
import sys, boto3, json
from botocore.exceptions import ClientError

REGION = "us-east-1"
WORKLOAD_NAME = "demo-wa-intro-workload"

def discover():
    sts = boto3.client("sts")
    ident = sts.get_caller_identity()
    print(f"Account: {ident['Account']}  Principal: {ident['Arn']}")

    ec2 = boto3.client("ec2", region_name=REGION)
    regions = [r["RegionName"] for r in ec2.describe_regions()["Regions"]]
    print(f"Enabled regions ({len(regions)}): {', '.join(regions)}")

    s3 = boto3.client("s3")
    buckets = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
    print(f"S3 buckets ({len(buckets)}): {buckets[:5]}{'…' if len(buckets) > 5 else ''}")

    iam = boto3.client("iam")
    summary = iam.get_account_summary()["SummaryMap"]
    print(f"IAM users={summary.get('Users')} roles={summary.get('Roles')} "
          f"policies={summary.get('Policies')} mfa={summary.get('AccountMFAEnabled')}")

def create_workload():
    wa = boto3.client("wellarchitected", region_name=REGION)
    try:
        resp = wa.create_workload(
            WorkloadName=WORKLOAD_NAME,
            Description="Intro module demo workload",
            Environment="PREPRODUCTION",
            AwsRegions=[REGION],
            ReviewOwner="architect@example.com",
            Lenses=["wellarchitected"],
            ClientRequestToken=WORKLOAD_NAME,
        )
        print(f"Workload created: {resp['WorkloadId']}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConflictException":
            print("Workload already exists — skipping.")
        else:
            raise

def cleanup():
    wa = boto3.client("wellarchitected", region_name=REGION)
    for w in wa.list_workloads().get("WorkloadSummaries", []):
        if w["WorkloadName"] == WORKLOAD_NAME:
            wa.delete_workload(WorkloadId=w["WorkloadId"], ClientRequestToken=f"del-{w['WorkloadId']}")
            print(f"Deleted workload {w['WorkloadId']}")
            return
    print("Nothing to delete.")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "discover"
    {"discover": discover, "create-workload": create_workload, "cleanup": cleanup}[cmd]()
