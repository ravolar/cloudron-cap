#!/usr/bin/env -S python3 -I
"""Delete the on-disk state of finished Cap workflow runs.

Cap's video processing runs as a durable workflow ("world-local" backend), which writes one
record per run plus its steps, events and lock files under WORKFLOW_LOCAL_DATA_DIR and never
deletes them. Cap itself never reads finished runs back (processing status lives in MySQL), so
runs that ended more than WORKFLOW_RETENTION_DAYS ago (default 30) are removed. Runs that are
still pending or running are never touched.

Runs from the Cloudron scheduler (see CloudronManifest.json). Pass --dry-run to only report.
Python runs isolated (-I): no user site-packages, PYTHON* variables or script-dir imports, since the
app user's home links into app-writable /run.
"""
import json
import os
import sys
import time
from datetime import datetime

DATA_DIR = os.environ.get("WORKFLOW_LOCAL_DATA_DIR", "/app/data/workflow-data")
FINISHED = {"completed", "failed", "cancelled"}


def retention_days():
    # Operator override lives in env.sh, which is not sourced in scheduler containers.
    days = os.environ.get("WORKFLOW_RETENTION_DAYS")
    try:
        with open("/app/data/env.sh") as f:
            for line in f:
                if line.startswith("WORKFLOW_RETENTION_DAYS="):
                    days = line.split("=", 1)[1].split("#")[0].strip().strip("\"'")
    except OSError:
        pass
    try:
        return max(1, int(days or 30))
    except ValueError:
        return 30


def finished_at(run):
    stamp = run.get("completedAt") or run.get("updatedAt")
    if not stamp:
        return None
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None  # unknown format: keep the run


def main():
    dry_run = "--dry-run" in sys.argv
    runs_dir = os.path.join(DATA_DIR, "runs")
    if not os.path.isdir(runs_dir):
        print(f"prune-workflows: {runs_dir} does not exist, nothing to do")
        return

    cutoff = time.time() - retention_days() * 86400
    expired = []
    for name in os.listdir(runs_dir):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(runs_dir, name)) as f:
                run = json.load(f)
        except (OSError, ValueError):
            continue
        run_id = run.get("runId")
        ended = finished_at(run)
        if run_id and run_id.startswith("wrun_") and run.get("status") in FINISHED and ended and ended < cutoff:
            expired.append(run_id)

    removed = 0
    for root, _dirs, files in os.walk(DATA_DIR):
        for name in files:
            if any(name == f"{run_id}.json" or name.startswith(f"{run_id}-") for run_id in expired):
                removed += 1
                if not dry_run:
                    os.unlink(os.path.join(root, name))

    action = "would remove" if dry_run else "removed"
    print(f"prune-workflows: {len(expired)} finished runs older than {retention_days()} days, {action} {removed} files")


if __name__ == "__main__":
    main()
