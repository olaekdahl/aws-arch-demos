# Module 14: Course Summary

**Topic:** Recap & Well-Architected review.
**Focus:** Run a Well-Architected lens review programmatically against the workload created in Module 0 — closing the loop on the course.

---

## Demo 1: Programmatic Well-Architected Lens Review (Python boto3)

### 1. Overview
- **What it shows:** Look up the WA workload from Module 0 (or create a fresh one), iterate the Well-Architected lens questions, answer them in code (use `notes` to leave architectural reasoning), and generate a milestone + summary report.
- **Use case:** Capstone — practice using the WA Tool API to review designs from earlier modules.
- **Services:** AWS Well-Architected Tool.

### 2. Architecture
```
[demo.py] -> WA Tool API
            list_workloads / get_workload
            list_answers (per pillar/lens)
            update_answer (mark Q answered + notes)
            create_milestone -> "post-course-review"
            get_workload (final summary)
```

### 3. Prerequisites
- Permissions: `wellarchitected:*`.
- Module 0 demo workload exists (or this script creates one).

### 4. Step-by-Step
```bash
python3 demo.py review
python3 demo.py milestone
python3 demo.py summary
python3 demo.py cleanup    # optional
```

### 5. Code — `demo.py`
```python
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
```

### 6. Validation
- `summary` prints risk counts (UNANSWERED count drops as you answer more questions).
- `milestone` returns a numeric milestone ID.
- Console: WA Tool → workload → see review answers + milestone history.

### 7. Cleanup
```bash
python3 demo.py cleanup
```

---

## Course Recap Checklist

Use this as a teach-back at the end of class. For each, point at the demo where students saw it:

- [ ] **WAF Pillars** — Modules 0 & 14 (`demo.py review`)
- [ ] **Multi-AZ** — Module 1 (CFN ALB+EC2)
- [ ] **Least-privilege IAM** — Module 2 (`simulate_principal_policy`)
- [ ] **VPC design** — Modules 3 & 10 (public/private subnets, TGW)
- [ ] **EC2 vs Lambda** — Module 4 (SSM session vs lambda invoke)
- [ ] **S3 lifecycle** — Module 5 (versioning + tiering)
- [ ] **NoSQL design** — Module 6 (single-table + GSI)
- [ ] **Auto Scaling** — Module 7 (target tracking + stress test)
- [ ] **IaC** — Module 8 (change sets) and most templates throughout
- [ ] **Containers** — Module 9 (Fargate + ALB)
- [ ] **Serverless event-driven** — Module 11 (HTTP API + EventBridge)
- [ ] **Edge protection** — Module 12 (CloudFront + OAC + WAF)
- [ ] **Backup/DR** — Module 13 (AWS Backup + DR helper)
