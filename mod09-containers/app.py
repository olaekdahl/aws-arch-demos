"""Module 9 demo app — Flask server that surfaces ECS task metadata.

Each running Fargate task gets a distinct color (hashed from its task ID),
so reloading the ALB URL visibly rotates between tasks.
"""
import hashlib
import json
import os
import socket
import time
import urllib.request

from flask import Flask, jsonify

app = Flask(__name__)
START = time.time()
HOSTNAME = socket.gethostname()
REQUESTS = 0


def task_metadata():
    uri = os.environ.get("ECS_CONTAINER_METADATA_URI_V4")
    if not uri:
        return {}
    try:
        with urllib.request.urlopen(f"{uri}/task", timeout=0.5) as r:
            return json.load(r)
    except Exception:
        return {}


def color_for(seed):
    h = hashlib.md5(seed.encode()).hexdigest()
    r = int(h[0:2], 16) | 0x40
    g = int(h[2:4], 16) | 0x40
    b = int(h[4:6], 16) | 0x40
    return f"#{r:02x}{g:02x}{b:02x}"


@app.route("/health")
def health():
    return "ok", 200


@app.route("/api/info")
def api_info():
    md = task_metadata()
    arn = md.get("TaskARN", "")
    return jsonify({
        "task_id": arn.split("/")[-1] if arn else HOSTNAME,
        "task_arn": arn,
        "availability_zone": md.get("AvailabilityZone"),
        "cluster": md.get("Cluster"),
        "family": md.get("Family"),
        "revision": md.get("Revision"),
        "launch_type": md.get("LaunchType"),
        "hostname": HOSTNAME,
        "requests": REQUESTS,
        "uptime_s": int(time.time() - START),
    })


@app.route("/")
def index():
    global REQUESTS
    REQUESTS += 1
    md = task_metadata()
    arn = md.get("TaskARN", "")
    tid = arn.split("/")[-1] if arn else HOSTNAME
    az = md.get("AvailabilityZone") or "n/a"
    cluster = md.get("Cluster") or "n/a"
    family = md.get("Family") or "n/a"
    revision = md.get("Revision") or "n/a"
    color = color_for(tid)
    uptime = int(time.time() - START)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ECS Fargate — task {tid[:8]}</title>
  <style>
    * {{ box-sizing: border-box; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           margin: 0; min-height: 100vh; color: #fff;
           background: radial-gradient(circle at 30% 20%, {color}, #0b0d12 70%);
           display: flex; align-items: center; justify-content: center; padding: 2rem; }}
    .card {{ background: rgba(10, 14, 22, .72); backdrop-filter: blur(8px);
             padding: 2.2rem 2.6rem; border-radius: 14px; max-width: 720px; width: 100%;
             box-shadow: 0 20px 60px rgba(0,0,0,.45);
             border: 1px solid rgba(255,255,255,.08); }}
    h1 {{ margin: 0 0 .25rem; font-size: 1.6rem; font-weight: 600; }}
    .sub {{ color: rgba(255,255,255,.65); font-size: .95rem; margin-bottom: 1.6rem; }}
    .tid {{ display: inline-block; font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 1.05rem; color: #0b0d12; background: {color};
            padding: .35rem .8rem; border-radius: 6px; font-weight: 600;
            box-shadow: 0 0 0 3px rgba(255,255,255,.08); }}
    table {{ border-collapse: collapse; width: 100%; margin-top: 1.4rem; font-size: .95rem; }}
    th, td {{ text-align: left; padding: .55rem .8rem;
              border-bottom: 1px solid rgba(255,255,255,.08); }}
    th {{ width: 12rem; color: rgba(255,255,255,.6); font-weight: 500; }}
    td {{ font-family: ui-monospace, "SF Mono", Menlo, monospace; }}
    .pulse {{ display: inline-block; width: 10px; height: 10px; border-radius: 50%;
              background: #4ade80; margin-right: .55rem;
              box-shadow: 0 0 0 0 rgba(74,222,128,.6);
              animation: pulse 1.6s infinite; }}
    @keyframes pulse {{
      0%   {{ box-shadow: 0 0 0 0 rgba(74,222,128,.6); }}
      70%  {{ box-shadow: 0 0 0 14px rgba(74,222,128,0); }}
      100% {{ box-shadow: 0 0 0 0 rgba(74,222,128,0); }}
    }}
    .footer {{ margin-top: 1.4rem; font-size: .82rem; color: rgba(255,255,255,.55); }}
    .footer code {{ background: rgba(255,255,255,.08); padding: .1rem .35rem; border-radius: 4px; }}
  </style>
</head>
<body>
  <div class="card">
    <h1><span class="pulse"></span>Hello from ECS Fargate</h1>
    <p class="sub">Served by task <span class="tid">{tid}</span></p>
    <table>
      <tr><th>Task ID</th><td>{tid}</td></tr>
      <tr><th>Availability Zone</th><td>{az}</td></tr>
      <tr><th>Cluster</th><td>{cluster}</td></tr>
      <tr><th>Task definition</th><td>{family}:{revision}</td></tr>
      <tr><th>Container hostname</th><td>{HOSTNAME}</td></tr>
      <tr><th>Requests this task</th><td>{REQUESTS}</td></tr>
      <tr><th>Task uptime</th><td>{uptime}s</td></tr>
    </table>
    <p class="footer">Auto-refreshing every 2s — watch the task ID and color rotate as the
    ALB round-robins across tasks. Hit <code>/api/info</code> for JSON.</p>
  </div>
  <script>
    setTimeout(() => location.reload(), 2000);
  </script>
</body>
</html>"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
