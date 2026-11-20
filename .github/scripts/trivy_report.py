#!/usr/bin/env python3
"""Render a Trivy JSON report as Markdown and apply the PR quality gate.

usage: trivy_report.py <trivy-report.json> <out.md>

Gate (exit 1 when any of these exist):
  - CRITICAL/HIGH vulnerabilities that have a fixed version available
  - CRITICAL/HIGH secrets
Everything else (unfixed vulns, MEDIUM/LOW, misconfigurations) is reported
only. Accepted risks go in .trivyignore at the repo root (one CVE/rule ID per
line).
"""

import json
import os
import sys

GATE_SEVERITIES = ("CRITICAL", "HIGH")
SEVERITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
# PR comments are capped at 65536 chars; the full list is in the artifact.
MAX_ROWS = 50
MARKER = "<!-- trivy-pr-scan -->"
VULN_HEADER = [
    "| Severity | ID | Package | Installed | Fixed in | File |",
    "|---|---|---|---|---|---|",
]


def sev_rank(s):
    """Sort key for a severity name: CRITICAL first, unknown values last."""
    if s in SEVERITY_ORDER:
        return SEVERITY_ORDER.index(s)
    return len(SEVERITY_ORDER)


def by_severity(item):
    """Sort key for a finding, by its severity."""
    return sev_rank(item.get("Severity"))


def counts(items):
    """Number of findings per severity."""
    c = {s: 0 for s in SEVERITY_ORDER}
    for i in items:
        sev = i.get("Severity", "UNKNOWN")
        c[sev] = c.get(sev, 0) + 1
    return c


def count_line(c):
    """One summary-table cell: 'Critical **n** · High **n** · ...'."""
    return " · ".join(f"{s.title()} **{c[s]}**" for s in SEVERITY_ORDER[:4])


def cell(s):
    """Make a value safe for a Markdown table cell."""
    return str(s or "").replace("|", "\\|").replace("\n", " ")[:120]


def row(*cells):
    """One Markdown table row."""
    return "| " + " | ".join(str(c) for c in cells) + " |"


def is_gated(item):
    """True for CRITICAL/HIGH findings."""
    return item.get("Severity") in GATE_SEVERITIES


def is_blocking_vuln(v):
    """True for CRITICAL/HIGH vulnerabilities that have a fixed version."""
    fixable = bool(v.get("FixedVersion"))
    return fixable and is_gated(v)


def plural(n, one, many):
    """Pick the singular or plural suffix for n."""
    return one if n == 1 else many


def collect(report):
    """Flatten the report into vulnerabilities, secrets, misconfigurations."""
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
    return vulns, secrets, misconfigs


def summary_section(failed, vulns, secrets, misconfigs, blocking):
    """Heading, gate result and the per-scanner summary table."""
    blocking_vulns, blocking_secrets = blocking
    lines = [MARKER, "## Trivy security scan", ""]
    if failed:
        nv, ns = len(blocking_vulns), len(blocking_secrets)
        lines.append(
            f"### ❌ Quality gate failed: {nv} fixable CRITICAL/HIGH "
            f"vulnerabilit{plural(nv, 'y', 'ies')}, "
            f"{ns} secret{plural(ns, '', 's')}"
        )
    else:
        lines.append("### ✅ Quality gate passed")
    return lines + [
        "",
        "Gate: fails on CRITICAL/HIGH vulnerabilities that have a fix, "
        "and on CRITICAL/HIGH secrets. "
        "Unfixed vulnerabilities and misconfigurations are reported only. "
        "To accept a finding, add its ID to `.trivyignore` "
        "with a comment saying why.",
        "",
        "| Scanner | Findings |",
        "|---|---|",
        row(f"Vulnerabilities ({len(vulns)})", count_line(counts(vulns))),
        row(f"Secrets ({len(secrets)})", count_line(counts(secrets))),
        row(
            f"Misconfigurations ({len(misconfigs)})",
            count_line(counts(misconfigs)),
        ),
        "",
    ]


def secrets_section(blocking_secrets):
    """Table of blocking secrets (file, line and rule only, no values)."""
    if not blocking_secrets:
        return []
    lines = [
        "#### Secrets (blocking)",
        "",
        "| Severity | File | Line | Rule |",
        "|---|---|---|---|",
    ]
    for s in sorted(blocking_secrets, key=by_severity)[:MAX_ROWS]:
        lines.append(
            row(
                s.get("Severity"),
                f"`{cell(s['_target'])}`",
                s.get("StartLine", ""),
                f"{cell(s.get('RuleID'))}: {cell(s.get('Title'))}",
            )
        )
    return lines + [""]


def blocking_vulns_section(blocking_vulns):
    """Table of fixable CRITICAL/HIGH vulnerabilities."""
    if not blocking_vulns:
        return []
    lines = ["#### Vulnerabilities to fix (blocking)", ""] + VULN_HEADER
    rows = sorted(
        blocking_vulns,
        key=lambda v: (sev_rank(v.get("Severity")), v.get("PkgName", "")),
    )
    for v in rows[:MAX_ROWS]:
        vid = v.get("VulnerabilityID", "")
        avd = f"https://avd.aquasec.com/nvd/{vid.lower()}"
        link = v.get("PrimaryURL") or avd
        lines.append(
            row(
                v.get("Severity"),
                f"[{vid}]({link})",
                cell(v.get("PkgName")),
                cell(v.get("InstalledVersion")),
                cell(v.get("FixedVersion")),
                f"`{cell(v['_target'])}`",
            )
        )
    if len(rows) > MAX_ROWS:
        more = len(rows) - MAX_ROWS
        lines.append(f"\n…and {more} more in the report artifact.")
    return lines + [""]


def non_blocking_section(others, misconfigs):
    """Collapsed tables of non-blocking vulnerabilities and misconfigs."""
    if not (others or misconfigs):
        return []
    lines = [
        "<details><summary>Non-blocking findings "
        f"({len(others)} vulnerabilities, "
        f"{len(misconfigs)} misconfigurations)</summary>",
        "",
    ]
    if others:
        lines += VULN_HEADER
        for v in sorted(others, key=by_severity)[:MAX_ROWS]:
            lines.append(
                row(
                    v.get("Severity"),
                    cell(v.get("VulnerabilityID")),
                    cell(v.get("PkgName")),
                    cell(v.get("InstalledVersion")),
                    cell(v.get("FixedVersion")) or "—",
                    f"`{cell(v['_target'])}`",
                )
            )
        lines.append("")
    if misconfigs:
        lines += ["| Severity | ID | Title | File |", "|---|---|---|---|"]
        for m in sorted(misconfigs, key=by_severity)[:MAX_ROWS]:
            lines.append(
                row(
                    m.get("Severity"),
                    cell(m.get("ID")),
                    cell(m.get("Title")),
                    f"`{cell(m['_target'])}`",
                )
            )
        lines.append("")
    return lines + ["</details>", ""]


def footer_line():
    """Scanned commit and a link to the workflow run."""
    sha = os.environ.get("HEAD_SHA", "")[:9]
    run_url = os.environ.get("RUN_URL", "")
    footer = f"Scanned `{sha}`" if sha else "Scanned"
    if run_url:
        footer += f" · [workflow run and full report]({run_url})"
    return f"<sub>{footer}</sub>"


def main():
    """Write the Markdown report and exit 1 if the quality gate fails."""
    report_path, out_path = sys.argv[1], sys.argv[2]
    with open(report_path, encoding="utf-8") as f:
        report = json.load(f)

    vulns, secrets, misconfigs = collect(report)
    blocking_vulns = [v for v in vulns if is_blocking_vuln(v)]
    blocking_secrets = [s for s in secrets if is_gated(s)]
    failed = bool(blocking_vulns or blocking_secrets)
    others = [v for v in vulns if v not in blocking_vulns]

    lines = summary_section(
        failed,
        vulns,
        secrets,
        misconfigs,
        (blocking_vulns, blocking_secrets),
    )
    lines += secrets_section(blocking_secrets)
    lines += blocking_vulns_section(blocking_vulns)
    lines += non_blocking_section(others, misconfigs)
    lines.append(footer_line())

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(
        f"vulnerabilities={len(vulns)} secrets={len(secrets)} "
        f"misconfigurations={len(misconfigs)} "
        f"blocking_vulns={len(blocking_vulns)} "
        f"blocking_secrets={len(blocking_secrets)}"
    )
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
