"""Module 8 Demo 2 — SSM patch automation.
In production: schedule via Maintenance Window."""
import sys, time, boto3

REGION = "us-east-1"
ssm = boto3.client("ssm", region_name=REGION)

def run():
    r = ssm.send_command(
        Targets=[{"Key":"tag:Patch","Values":["true"]}],
        DocumentName="AWS-RunPatchBaseline",
        Parameters={"Operation":["Scan"]},
        Comment="demo-auto-patch-scan")
    cid = r["Command"]["CommandId"]
    print(f"Command: {cid}")
    return cid

def status(cid=None):
    cid = cid or sys.argv[2]
    invs = ssm.list_command_invocations(CommandId=cid, Details=True)["CommandInvocations"]
    if not invs:
        print("No invocations yet — wait for SSM to enumerate targets.")
        return
    for i in invs:
        print(f"  {i['InstanceId']} -> {i['Status']}")

if __name__ == "__main__":
    {"run": run, "status": status}[sys.argv[1]]()
