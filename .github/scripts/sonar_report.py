#!/usr/bin/env python3
"""Render a SonarQube analysis as Markdown and report the quality gate.

usage: sonar_report.py <out.md>

Reads .scannerwork/report-task.txt (written by the scanner), asks the server
(SONAR_HOST_URL, SONAR_TOKEN) for the quality gate status and the open
vulnerabilities, bugs and security hotspots of this analysis (the PR when it
is a PR analysis), and exits 1 when the gate is not OK or the analysis did
not complete. The server URL is never written to the report: some repos are
public and the URL is a secret.
"""
import base64
import json
import os
import sys
import urllib.parse
import urllib.request

MARKER = "<!-- sonarqube-pr-scan -->"
MAX_ROWS = 50  # PR comments are capped at 65536 chars
SEVERITY_ORDER = ["BLOCKER", "CRITICAL", "MAJOR", "MINOR", "INFO"]
METRIC_NAMES = {
    "new_reliability_rating": "Reliability rating on new code",
    "new_security_rating": "Security rating on new code",
    "new_maintainability_rating": "Maintainability rating on new code",
    "new_coverage": "Coverage on new code",
    "new_duplicated_lines_density": "Duplicated lines on new code (%)",
    "new_security_hotspots_reviewed": "Security hotspots reviewed on new code (%)",
    "new_violations": "New issues",
    "reliability_rating": "Reliability rating",
    "security_rating": "Security rating",
    "sqale_rating": "Maintainability rating",
    "coverage": "Coverage",
    "duplicated_lines_density": "Duplicated lines (%)",
    "security_hotspots_reviewed": "Security hotspots reviewed (%)",
}
RATINGS = {"1": "A", "2": "B", "3": "C", "4": "D", "5": "E"}


def cell(s):
    return str(s if s is not None else "").replace("|", "\\|").replace("\n", " ")[:120]


def read_task_file(path=".scannerwork/report-task.txt"):
    props = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                props[k] = v
    return props


class Sonar:
    def __init__(self):
        self.base = os.environ["SONAR_HOST_URL"].rstrip("/")
        token = os.environ["SONAR_TOKEN"]
        self.auth = "Basic " + base64.b64encode(f"{token}:".encode()).decode()

    def get(self, path, **params):
        url = f"{self.base}{path}?{urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})}"
        req = urllib.request.Request(url, headers={"Authorization": self.auth})
        with urllib.request.urlopen(req, timeout=60) as f:
            return json.load(f)


def fmt_value(metric, value):
    if value is None:
        return "—"
    if metric.endswith("_rating"):
        return RATINGS.get(str(value).split(".")[0], value)
    return value


def main():
    out_path = sys.argv[1]
    sha = os.environ.get("HEAD_SHA", "")[:9]
    run_url = os.environ.get("RUN_URL", "")
    footer = f"Analysed `{sha}`" if sha else "Analysed"
    if run_url:
        footer += f" · [workflow run]({run_url})"
    lines = [MARKER, "## SonarQube analysis", ""]

    def finish(failed):
        lines.extend(["", f"<sub>{footer}</sub>"])
        with open(out_path, "w") as f:
            f.write("\n".join(lines) + "\n")
        sys.exit(1 if failed else 0)

    try:
        task = read_task_file()
    except OSError:
        lines += ["### ❌ Analysis did not complete",
                  "",
                  "The scanner did not produce a report (outcome: "
                  f"`{os.environ.get('SCAN_OUTCOME', 'unknown')}`). See the workflow run log."]
        finish(True)

    project = task.get("projectKey", "")
    sonar = Sonar()
    try:
        ce = sonar.get("/api/ce/task", id=task["ceTaskId"])["task"]
        analysis_id = ce.get("analysisId")
        pr = ce.get("pullRequest")
        branch = ce.get("branch")
        gate = sonar.get("/api/qualitygates/project_status", analysisId=analysis_id)["projectStatus"] if analysis_id else {}
        scope = {"pullRequest": pr} if pr else {"branch": branch}
        issues = sonar.get("/api/issues/search", componentKeys=project, resolved="false",
                           types="VULNERABILITY,BUG", ps=MAX_ROWS, s="SEVERITY", asc="false",
                           facets="types,severities", **scope)
        hotspots = sonar.get("/api/hotspots/search", projectKey=project, status="TO_REVIEW", ps=1, **scope)
    except Exception as e:  # server/API problem: report it, fail the gate
        lines += ["### ❌ Could not read the analysis result", "", f"`{type(e).__name__}: {cell(e)}`"]
        finish(True)

    status = gate.get("status", "NONE")
    failed = status != "OK"
    target = f"pull request #{pr}" if pr else f"branch `{branch}`"
    if status == "OK":
        lines.append("### ✅ Quality gate passed")
    elif status == "NONE":
        lines.append("### ❌ No quality gate result (is a quality gate assigned to this project?)")
    else:
        lines.append(f"### ❌ Quality gate failed ({status})")
    lines += ["", f"Project `{project}`, {target}.", ""]

    conditions = gate.get("conditions") or []
    if conditions:
        lines += ["| Condition | Value | Threshold | Status |", "|---|---|---|---|"]
        for c in sorted(conditions, key=lambda c: c.get("status") == "OK"):
            m = c.get("metricKey", "")
            op = {"GT": ">", "LT": "<"}.get(c.get("comparator"), c.get("comparator", ""))
            mark = "✅" if c.get("status") == "OK" else "❌"
            lines.append(f"| {cell(METRIC_NAMES.get(m, m))} | {fmt_value(m, c.get('actualValue'))} "
                         f"| fails if {op} {fmt_value(m, c.get('errorThreshold'))} | {mark} |")
        lines.append("")

    facets = {f["property"]: {v["val"]: v["count"] for v in f["values"]} for f in issues.get("facets", [])}
    types, sevs = facets.get("types", {}), facets.get("severities", {})
    hs_total = (hotspots.get("paging") or {}).get("total", 0)
    lines += ["| Open findings | Count |", "|---|---|",
              f"| Vulnerabilities | **{types.get('VULNERABILITY', 0)}** |",
              f"| Bugs | **{types.get('BUG', 0)}** |",
              f"| Security hotspots to review | **{hs_total}** |",
              "", "By severity: " + " · ".join(f"{s.title()} {sevs.get(s, 0)}" for s in SEVERITY_ORDER), ""]

    rows = issues.get("issues") or []
    if rows:
        lines += [f"<details><summary>Vulnerabilities and bugs ({issues.get('total', len(rows))})</summary>", "",
                  "| Severity | Type | Rule | Message | File |", "|---|---|---|---|---|"]
        for i in rows[:MAX_ROWS]:
            comp = i.get("component", "").split(":", 1)[-1]
            loc = f"{comp}:{i['line']}" if i.get("line") else comp
            lines.append(f"| {i.get('severity')} | {i.get('type', '').title()} | {cell(i.get('rule'))} "
                         f"| {cell(i.get('message'))} | `{cell(loc)}` |")
        if issues.get("total", 0) > MAX_ROWS:
            lines.append(f"\n…and {issues['total'] - MAX_ROWS} more in SonarQube.")
        lines += ["", "</details>"]

    print(f"gate={status} vulnerabilities={types.get('VULNERABILITY', 0)} bugs={types.get('BUG', 0)} hotspots={hs_total}")
    finish(failed)


if __name__ == "__main__":
    main()
