"""
Module 0 Demo — Account discovery + Well-Architected workload creation.
In production, split into: inventory.py, wellarchitected.py, cli.py.
"""
import sys, boto3, json
from botocore.exceptions import ClientError

REGION = "us-east-1"
WORKLOAD_NAME = "demo-wa-intro-workload"

def _section(title):
    print()
    print(f"\033[1;36m── {title} {'─' * max(2, 60 - len(title))}\033[0m")

def _kv(k, v, width=22):
    print(f"  {k:<{width}} {v}")

def discover():
    sts = boto3.client("sts")
    ident = sts.get_caller_identity()
    account = ident["Account"]
    arn = ident["Arn"]

    _section("Identity")
    _kv("Account ID", account)
    try:
        aliases = boto3.client("iam").list_account_aliases().get("AccountAliases", [])
        _kv("Account alias", aliases[0] if aliases else "(none set)")
    except ClientError:
        pass
    _kv("Caller principal", arn)
    _kv("Default region", REGION)

    _section("Regions")
    ec2 = boto3.client("ec2", region_name=REGION)
    regions = sorted(r["RegionName"] for r in ec2.describe_regions()["Regions"])
    _kv("Enabled count", len(regions))
    # print up to 4 per line
    for i in range(0, len(regions), 4):
        print("    " + "  ".join(f"{r:<16}" for r in regions[i:i + 4]))

    _section("IAM Posture")
    iam = boto3.client("iam")
    summary = iam.get_account_summary()["SummaryMap"]
    mfa = summary.get("AccountMFAEnabled", 0)
    root_keys = summary.get("AccountAccessKeysPresent", 0)
    _kv("Users",          summary.get("Users", 0))
    _kv("Roles",          summary.get("Roles", 0))
    _kv("Groups",         summary.get("Groups", 0))
    _kv("Customer policies", summary.get("Policies", 0))
    _kv("Root MFA enabled", "✅ yes" if mfa else "⚠️  NO — enable immediately")
    _kv("Root access keys", "✅ none" if not root_keys else "⚠️  PRESENT — remove")
    try:
        iam.get_account_password_policy()
        _kv("Password policy",  "✅ set")
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            _kv("Password policy", "⚠️  not configured")
        else:
            _kv("Password policy", f"? {e.response['Error']['Code']}")

    _section("S3 Buckets")
    s3 = boto3.client("s3")
    buckets = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
    _kv("Total buckets", len(buckets))
    for b in buckets[:10]:
        print(f"    • {b}")
    if len(buckets) > 10:
        print(f"    … and {len(buckets) - 10} more")

    _section("Compute Footprint (current region)")
    running = ec2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}])
    inst_count = sum(len(r["Instances"]) for r in running["Reservations"])
    _kv("Running EC2 instances", inst_count)
    try:
        lam = boto3.client("lambda", region_name=REGION)
        fns = lam.list_functions(MaxItems=50).get("Functions", [])
        _kv("Lambda functions", f"{len(fns)}{'+' if len(fns) == 50 else ''}")
    except ClientError:
        pass

    _section("Cost (last 7 days, this account)")
    try:
        from datetime import datetime, timedelta, timezone
        ce = boto3.client("ce", region_name="us-east-1")
        end = datetime.now(timezone.utc).date()
        start = end - timedelta(days=7)
        r = ce.get_cost_and_usage(
            TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
            Granularity="DAILY",
            Metrics=["UnblendedCost"])
        total = sum(float(d["Total"]["UnblendedCost"]["Amount"]) for d in r["ResultsByTime"])
        unit = r["ResultsByTime"][0]["Total"]["UnblendedCost"]["Unit"] if r["ResultsByTime"] else "USD"
        _kv("Spend (7d)", f"{total:.2f} {unit}")
    except ClientError as e:
        _kv("Spend (7d)", f"unavailable ({e.response['Error']['Code']})")

    print()
    print("\033[1;32mDiscovery complete.\033[0m  Next: python3 demo.py create-workload")

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
