#!/usr/bin/env python3
"""Every alert's `runbook:` annotation must point at a real heading."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
runbook = (ROOT / "docs/alert-runbook.md").read_text()

anchors = {
    re.sub(r"[^a-z0-9 -]", "", line.lstrip("#").strip().lower()).replace(" ", "-")
    for line in runbook.splitlines()
    if line.startswith("#")
}

missing, total, unlinked = [], 0, []
rule_files = sorted((ROOT / "config/prometheus/rules").glob("*.yml"))
# Security alerts live in Loki. Check the template, not the per-tenant copies.
rule_files.append(ROOT / "config/loki/security.rules.yml")

for f in rule_files:
    text = f.read_text()
    for m in re.finditer(r'runbook:\s*"docs/alert-runbook\.md#([^"]+)"', text):
        total += 1
        if m.group(1) not in anchors:
            missing.append(f"{f.name} -> #{m.group(1)}")
    # An alert with no runbook link leaves whoever is on call with nothing.
    for block in re.split(r"(?=- alert:)", text)[1:]:
        name = re.match(r"- alert:\s*(\w+)", block)
        if name and "runbook:" not in block:
            unlinked.append(f"{f.name} -> {name.group(1)}")

problems = []
if missing:
    problems.append("dangling runbook links:\n  " + "\n  ".join(missing))
if unlinked:
    problems.append("alerts with no runbook link:\n  " + "\n  ".join(unlinked))
if problems:
    sys.exit("\n".join(problems))

print(f"{total} runbook links resolve across {len(anchors)} headings")
