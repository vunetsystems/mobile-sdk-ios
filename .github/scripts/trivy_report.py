#!/usr/bin/env python3
"""Render a Trivy JSON report as Markdown and apply the PR quality gate.

usage: trivy_report.py <trivy-report.json> <out.md>

Gate (exit 1 when any of these exist):
  - CRITICAL/HIGH vulnerabilities that have a fixed version available
  - CRITICAL/HIGH secrets
Everything else (unfixed vulns, MEDIUM/LOW, misconfigurations) is reported only.
Accepted risks go in .trivyignore at the repo root (one CVE/rule ID per line).
"""
import json
import os
import sys

GATE_SEVERITIES = ("CRITICAL", "HIGH")
SEVERITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
MAX_ROWS = 50  # PR comments are capped at 65536 chars; the full list is in the artifact
MARKER = "<!-- trivy-pr-scan -->"


def sev_rank(s):
    return SEVERITY_ORDER.index(s) if s in SEVERITY_ORDER else len(SEVERITY_ORDER)


def counts(items):
    c = {s: 0 for s in SEVERITY_ORDER}
    for i in items:
        c[i.get("Severity", "UNKNOWN")] = c.get(i.get("Severity", "UNKNOWN"), 0) + 1
    return c


def count_line(c):
    return " · ".join(f"{s.title()} **{c[s]}**" for s in SEVERITY_ORDER[:4])


def cell(s):
    return str(s or "").replace("|", "\\|").replace("\n", " ")[:120]


def main():
    report_path, out_path = sys.argv[1], sys.argv[2]
    with open(report_path) as f:
        report = json.load(f)

    vulns, secrets, misconfigs = [], [], []
    for r in report.get("Results") or []:
        target = r.get("Target", "")
        for v in r.get("Vulnerabilities") or []:
            vulns.append({**v, "_target": target})
        for s in r.get("Secrets") or []:
            secrets.append({**s, "_target": target})
        for m in r.get("Misconfigurations") or []:
            if m.get("Status", "FAIL") == "FAIL":
                misconfigs.append({**m, "_target": target})

    blocking_vulns = [v for v in vulns if v.get("Severity") in GATE_SEVERITIES and v.get("FixedVersion")]
    blocking_secrets = [s for s in secrets if s.get("Severity") in GATE_SEVERITIES]
    failed = bool(blocking_vulns or blocking_secrets)

    sha = os.environ.get("HEAD_SHA", "")[:9]
    run_url = os.environ.get("RUN_URL", "")
    lines = [MARKER, "## Trivy security scan", ""]
    if failed:
        lines.append(f"### ❌ Quality gate failed: {len(blocking_vulns)} fixable CRITICAL/HIGH "
                     f"vulnerabilit{'y' if len(blocking_vulns) == 1 else 'ies'}, "
                     f"{len(blocking_secrets)} secret{'' if len(blocking_secrets) == 1 else 's'}")
    else:
        lines.append("### ✅ Quality gate passed")
    lines += [
        "",
        "Gate: fails on CRITICAL/HIGH vulnerabilities that have a fix, and on CRITICAL/HIGH secrets. "
        "Unfixed vulnerabilities and misconfigurations are reported only. "
        "To accept a finding, add its ID to `.trivyignore` with a comment saying why.",
        "",
        "| Scanner | Findings |",
        "|---|---|",
        f"| Vulnerabilities ({len(vulns)}) | {count_line(counts(vulns))} |",
        f"| Secrets ({len(secrets)}) | {count_line(counts(secrets))} |",
        f"| Misconfigurations ({len(misconfigs)}) | {count_line(counts(misconfigs))} |",
        "",
    ]

    if blocking_secrets:
        lines += ["#### Secrets (blocking)", "", "| Severity | File | Line | Rule |", "|---|---|---|---|"]
        for s in sorted(blocking_secrets, key=lambda x: sev_rank(x.get("Severity")))[:MAX_ROWS]:
            lines.append(f"| {s.get('Severity')} | `{cell(s['_target'])}` | {s.get('StartLine', '')} "
                         f"| {cell(s.get('RuleID'))}: {cell(s.get('Title'))} |")
        lines.append("")

    if blocking_vulns:
        lines += ["#### Vulnerabilities to fix (blocking)", "",
                  "| Severity | ID | Package | Installed | Fixed in | File |", "|---|---|---|---|---|---|"]
        rows = sorted(blocking_vulns, key=lambda v: (sev_rank(v.get("Severity")), v.get("PkgName", "")))
        for v in rows[:MAX_ROWS]:
            vid = v.get("VulnerabilityID", "")
            link = v.get("PrimaryURL") or f"https://avd.aquasec.com/nvd/{vid.lower()}"
            lines.append(f"| {v.get('Severity')} | [{vid}]({link}) | {cell(v.get('PkgName'))} "
                         f"| {cell(v.get('InstalledVersion'))} | {cell(v.get('FixedVersion'))} "
                         f"| `{cell(v['_target'])}` |")
        if len(rows) > MAX_ROWS:
            lines.append(f"\n…and {len(rows) - MAX_ROWS} more in the report artifact.")
        lines.append("")

    others = [v for v in vulns if v not in blocking_vulns]
    if others or misconfigs:
        lines += ["<details><summary>Non-blocking findings "
                  f"({len(others)} vulnerabilities, {len(misconfigs)} misconfigurations)</summary>", ""]
        if others:
            lines += ["| Severity | ID | Package | Installed | Fixed in | File |", "|---|---|---|---|---|---|"]
            for v in sorted(others, key=lambda v: sev_rank(v.get("Severity")))[:MAX_ROWS]:
                lines.append(f"| {v.get('Severity')} | {cell(v.get('VulnerabilityID'))} | {cell(v.get('PkgName'))} "
                             f"| {cell(v.get('InstalledVersion'))} | {cell(v.get('FixedVersion')) or '—'} "
                             f"| `{cell(v['_target'])}` |")
            lines.append("")
        if misconfigs:
            lines += ["| Severity | ID | Title | File |", "|---|---|---|---|"]
            for m in sorted(misconfigs, key=lambda m: sev_rank(m.get("Severity")))[:MAX_ROWS]:
                lines.append(f"| {m.get('Severity')} | {cell(m.get('ID'))} | {cell(m.get('Title'))} "
                             f"| `{cell(m['_target'])}` |")
            lines.append("")
        lines += ["</details>", ""]

    footer = f"Scanned `{sha}`" if sha else "Scanned"
    if run_url:
        footer += f" · [workflow run and full report]({run_url})"
    lines.append(f"<sub>{footer}</sub>")

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"vulnerabilities={len(vulns)} secrets={len(secrets)} misconfigurations={len(misconfigs)} "
          f"blocking_vulns={len(blocking_vulns)} blocking_secrets={len(blocking_secrets)}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
