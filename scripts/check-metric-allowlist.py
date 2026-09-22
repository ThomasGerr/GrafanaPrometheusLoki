#!/usr/bin/env python3
"""Every metric a rule or dashboard queries must survive an allowlist.

The agent only sends metrics its `keep` relabel rules name (agent/config.alloy,
agent/databases.alloy), and the central Prometheus keeps only listed metrics
from the stack's own services (metric_relabel_configs in prometheus.yml). A
panel or alert on anything else would quietly show no data or never fire, so
this fails instead.

Needs PyYAML; `make validate` runs it in the same throwaway container as the
generator.
"""
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent

# Scraped by the central Prometheus itself, not by any agent.
CENTRAL = re.compile(r"^(prometheus|alertmanager|loki|grafana|blackbox)_")
# Blackbox probe results. The per-site jobs in scrape/ keep everything.
PROBE = re.compile(r"^probe_")

PROMQL_KEYWORDS = {
    "by", "without", "on", "ignoring", "group_left", "group_right",
    "and", "or", "unless", "bool", "offset", "inf", "nan",
}


def allowlists():
    patterns = []
    for f in ("agent/config.alloy", "agent/databases.alloy"):
        text = (ROOT / f).read_text()
        for m in re.finditer(r'regex\s*=\s*"([^"]+)"\s*\n\s*action\s*=\s*"keep"', text):
            # Prometheus relabel regexes are anchored at both ends.
            patterns.append(re.compile(f"^(?:{m.group(1)})$"))
    if not patterns:
        sys.exit("no `keep` allowlists found in agent/*.alloy — has the format changed?")
    return patterns


def central_allowlists():
    config = yaml.safe_load((ROOT / "config/prometheus/prometheus.yml").read_text())
    patterns = []
    for job in config.get("scrape_configs", []):
        for rule in job.get("metric_relabel_configs", []):
            if rule.get("action") == "keep" and rule.get("source_labels") == ["__name__"]:
                patterns.append(re.compile(f"^(?:{rule['regex']})$"))
    return patterns


def expand(pattern):
    """All names a plain alternation regex like a_(b|c)_d|e can match.
    Returns None for anything using other regex features."""
    if re.search(r"[.*+?\[\]\\^$]", pattern):
        return None

    def alts(s):
        out, depth, cur = [], 0, ""
        for ch in s:
            if ch == "|" and depth == 0:
                out.append(cur); cur = ""
                continue
            depth += ch == "("
            depth -= ch == ")"
            cur += ch
        return out + [cur]

    def seq(s):
        m = re.search(r"\(", s)
        if not m:
            return [s]
        depth = 0
        for i in range(m.start(), len(s)):
            depth += s[i] == "("
            depth -= s[i] == ")"
            if depth == 0:
                break
        head, group, tail = s[:m.start()], s[m.start() + 1:i], s[i + 1:]
        return [head + g + t for alt in alts(group) for g in seq(alt) for t in seq(tail)]

    return [name for alt in alts(pattern) for name in seq(alt)]


def metric_names(expr):
    names = set()
    for m in re.finditer(r'__name__\s*(=~|=)\s*"([^"]*)"', expr):
        found = [m.group(2)] if m.group(1) == "=" else expand(m.group(2))
        if found is None:
            raise ValueError(f"cannot check __name__ regex {m.group(2)!r}")
        names.update(found)
    expr = re.sub(r'"(\\.|[^"\\])*"', '""', expr)   # string literals
    expr = re.sub(r"\{[^}]*\}", "", expr)           # label matchers
    expr = re.sub(r"\[[^\]]*\]", "", expr)          # ranges
    expr = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", expr)
    # Whole identifiers only: without (?![\w:]) the regex would back off
    # "rate(" to "rat" to satisfy the not-a-function lookahead.
    for m in re.finditer(r"(?<![\w$.:])([a-zA-Z_:][a-zA-Z0-9_:]*)(?![\w:])(?!\s*\()", expr):
        if m.group(1) not in PROMQL_KEYWORDS:
            names.add(m.group(1))
    return names


def queries():
    """Every Prometheus query in rules and dashboards as (where, promql), and
    the names the recording rules define."""
    found, records = [], set()
    for f in sorted((ROOT / "config/prometheus/rules").glob("*.yml")):
        for group in yaml.safe_load(f.read_text())["groups"]:
            for rule in group["rules"]:
                name = rule.get("alert") or rule.get("record")
                if "record" in rule:
                    records.add(rule["record"])
                found.append((f"{f.name}: {name}", rule["expr"]))
    for f in sorted((ROOT / "config/grafana/dashboards").glob("*.json")):
        d = json.loads(f.read_text())
        for v in d.get("templating", {}).get("list", []):
            if (v.get("datasource") or {}).get("type") != "prometheus":
                continue
            q = v.get("query")
            q = q.get("query", "") if isinstance(q, dict) else q or ""
            m = re.match(r"\s*label_values\((.*),\s*\w+\s*\)\s*$", q)
            if m:
                found.append((f"{f.name}: variable {v['name']}", m.group(1)))
            elif not q.startswith("label_values("):
                found.append((f"{f.name}: variable {v['name']}", q))
        for p in d.get("panels", []):
            for t in p.get("targets", []):
                ds = t.get("datasource") or p.get("datasource") or {}
                if ds.get("type") == "prometheus" and t.get("expr"):
                    found.append((f"{f.name}: {p.get('title')}", t["expr"]))
    return found, records


def main():
    keep = allowlists()
    central = central_allowlists()
    problems, checked = [], set()
    items, records = queries()
    for where, expr in items:
        try:
            names = metric_names(expr)
        except ValueError as e:
            problems.append(f"{where}: {e}")
            continue
        for name in sorted(names):
            checked.add(name)
            if ":" in name:
                if name not in records:
                    problems.append(f"{where}: recording rule {name} is not defined")
            elif name == "up" or PROBE.match(name):
                continue
            elif CENTRAL.match(name):
                if not any(p.match(name) for p in central):
                    problems.append(f"{where}: {name} is dropped by metric_relabel_configs"
                                    " in config/prometheus/prometheus.yml")
            elif not any(p.match(name) for p in keep):
                problems.append(f"{where}: {name} is dropped by the agent's allowlist"
                                " (agent/config.alloy, or the engine's in agent/databases.alloy)")
    if problems:
        sys.exit("metrics that never reach Prometheus:\n  " + "\n  ".join(problems))
    print(f"{len(checked)} metrics used by {len(items)} queries all reach Prometheus")


if __name__ == "__main__":
    main()
