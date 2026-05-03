"""Module 14 Demo — Programmatic Well-Architected review (capstone).
Production split: workload.py, lens.py, report.py."""
import sys, boto3
from botocore.exceptions import ClientError

REGION = "us-east-1"
NAME   = "demo-wa-summary-workload"
LENS   = "wellarchitected"
wa = boto3.client("wellarchitected", region_name=REGION)

def _wid():
    for w in wa.list_workloads().get("WorkloadSummaries", []):
        if w["WorkloadName"] == NAME:
            return w["WorkloadId"]
    r = wa.create_workload(
        WorkloadName=NAME, Description="Course summary capstone",
        Environment="PREPRODUCTION", AwsRegions=[REGION],
        ReviewOwner="architect@example.com", Lenses=[LENS],
        ClientRequestToken=NAME)
    return r["WorkloadId"]

def review():
    wid = _wid()
    answers = wa.list_answers(WorkloadId=wid, LensAlias=LENS)["AnswerSummaries"]
    print(f"{len(answers)} questions in lens.")
    # Mark first 3 questions per pillar as answered with a teaching note.
    seen = {}
    for a in answers:
        p = a["PillarId"]
        seen.setdefault(p, 0)
        if seen[p] >= 3: continue
        seen[p] += 1
        choice_ids = [c["ChoiceId"] for c in a["Choices"][:1]]  # pick first choice
        try:
            wa.update_answer(
                WorkloadId=wid, LensAlias=LENS, QuestionId=a["QuestionId"],
                SelectedChoices=choice_ids,
                Notes=f"[demo] Reviewed during course module 14 — pillar {p}.")
        except ClientError as e:
            print("  skip:", a["QuestionId"], e.response["Error"]["Code"])
    print("Review answers updated:", seen)

def milestone():
    wid = _wid()
    r = wa.create_milestone(WorkloadId=wid, MilestoneName="post-course-review",
        ClientRequestToken=f"{wid}-post-course")
    print("Milestone:", r["MilestoneNumber"])

def summary():
    wid = _wid()
    w = wa.get_workload(WorkloadId=wid)["Workload"]
    risks = w.get("RiskCounts", {})
    print(f"Workload: {w['WorkloadName']}")
    print(f"Risks: HIGH={risks.get('HIGH',0)} MEDIUM={risks.get('MEDIUM',0)} "
          f"NONE={risks.get('NONE',0)} UNANSWERED={risks.get('UNANSWERED',0)}")

def cleanup():
    wid = _wid()
    wa.delete_workload(WorkloadId=wid, ClientRequestToken=f"del-{wid}")
    print("Deleted workload.")

if __name__ == "__main__":
    {"review": review, "milestone": milestone, "summary": summary, "cleanup": cleanup}[sys.argv[1]]()
