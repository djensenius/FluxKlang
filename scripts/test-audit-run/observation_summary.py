#!/usr/bin/env python3
"""Summary-only formatter for the hosted Mac observation workflow (#693).

Standard library only (Python 3.7+). Reads step results from the environment,
the xcresult summary via `xcresulttool`, and receipt-directory entry counts.
Receipt contents are never read, and receipt filenames are never written:
every text from xcresult is redacted before it is truncated or stored.
"""

import json
import os
import re
import subprocess
import sys

NA = "not available"
REDACTED_RECEIPT = "<receipt-file>"
REDACTED_UUID = "<uuid>"

# ProductionAccessScope names receipts `production-access-<scope>-<UUID>.json`; the sink's
# errors also name the hidden `.<name>.partial`, sometimes after a directory path. Match any
# token from that prefix (optional leading dot and path) through the filename characters, so
# partial, truncated-upstream and case variants are covered.
RECEIPT_NAME = re.compile(
    r"(?:[^\s'\"`<>|;,()\[\]{}]*/)?\.?production-access-[A-Za-z0-9._-]*", re.IGNORECASE)
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)
AUDIT = re.compile(r"productionaccess|production access|audit", re.IGNORECASE)

DEVIATIONS = [
    "CODE_SIGNING_ALLOWED=NO: host ad-hoc signed by the linker without entitlements; unsandboxed",
    "receipt directory supplied via TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR (delivery unverified)",
]


def redact(value, run_id=""):
    """Redact receipt filenames, then any UUID other than the already-recorded run ID."""
    value = RECEIPT_NAME.sub(REDACTED_RECEIPT, str(value))
    keep = run_id.lower()
    return UUID.sub(lambda m: m.group(0) if keep and m.group(0).lower() == keep else REDACTED_UUID, value)


def text(value, limit=300, run_id=""):
    """Redact first, then a single line without backticks, then truncate."""
    return " ".join(redact(value, run_id).split()).replace("`", "'")[:limit]


def summarize(env, results, error, counts):
    """Return (summary dict, markdown). Pure: no I/O."""
    def get(key):
        return env.get(key) or NA

    run_id = env.get("RUN_ID") or ""
    summary = {
        "head_sha": get("HEAD_SHA"), "event_sha": get("GITHUB_SHA"), "pr_head_sha": get("PR_HEAD_SHA"),
        "xcode": get("XCODE"), "macos": get("MACOS"), "python": get("PYTHON"),
        "xctestrun": get("XCTESTRUN"), "xctestrun_sha256": get("XCTESTRUN_SHA256"),
        "preparation": get("PREPARE_OUTCOME"), "run_id": get("RUN_ID"),
        "start_utc": get("TEST_START"), "end_utc": get("TEST_END"),
        "exit_code": get("TEST_STATUS"), "test_argv": get("TEST_ARGV"),
        "deviations": list(DEVIATIONS),
        "xcresult_error": text(error, 500, run_id) if error else None,
    }
    if isinstance(results, dict):
        for key, name in (("result", "result"), ("totalTestCount", "total"), ("passedTests", "passed"),
                          ("failedTests", "failed"), ("skippedTests", "skipped"),
                          ("expectedFailures", "expected_failures_known_issues"),
                          ("startTime", "xcresult_start"), ("finishTime", "xcresult_finish")):
            value = results.get(key, NA)
            summary[name] = text(value, 200, run_id) if isinstance(value, str) else value
        failures = results.get("testFailures") or []
        failures = [f for f in failures if isinstance(f, dict)] if isinstance(failures, list) else []
        summary["failure_count"] = len(failures)
        # Counted on the full, unredacted and untruncated text; only the count is kept.
        summary["audit_failure_count"] = sum(
            1 for f in failures
            if AUDIT.search("%s %s" % (f.get("testName", ""), f.get("failureText", ""))))
        summary["first_failures"] = [
            {"target": text(f.get("targetName", NA), 100, run_id),
             "test": text(f.get("testName", NA), 200, run_id),
             "message": text(f.get("failureText", NA), 300, run_id)}
            for f in failures[:20]]
    else:
        for name in ("result", "total", "passed", "failed", "skipped", "expected_failures_known_issues",
                     "failure_count", "audit_failure_count"):
            summary[name] = NA
        summary["first_failures"] = []
    summary.update(counts)

    rows = [
        ("HEAD SHA", "head_sha"), ("Event SHA", "event_sha"), ("PR head SHA", "pr_head_sha"),
        ("Xcode", "xcode"), ("macOS", "macos"),
        ("xctestrun sha256", "xctestrun_sha256"), ("Preparation", "preparation"), ("Run ID", "run_id"),
        ("Start (UTC)", "start_utc"), ("End (UTC)", "end_utc"), ("Exit code", "exit_code"),
        ("Result", "result"), ("Total", "total"), ("Passed", "passed"), ("Failed", "failed"),
        ("Skipped", "skipped"), ("Expected failures (known issues)", "expected_failures_known_issues"),
        ("Failures mentioning productionAccess/audit", "audit_failure_count"),
        ("Published receipt files", "receipts_published"),
        ("Hidden .partial leftovers", "receipts_partial_leftovers"),
        ("Other receipt-dir entries", "receipts_other_entries"),
    ]
    lines = ["## Observation result", "", "| Field | Value |", "| --- | --- |"]
    lines += ["| %s | %s |" % (label, text(summary.get(key, NA), 200, run_id).replace("|", "\\|"))
              for label, key in rows]
    if summary["xcresult_error"]:
        lines += ["", "xcresult summary: " + summary["xcresult_error"]]
    lines += ["", "Test argv (exact):", "", "```text", text(summary["test_argv"], 4000, run_id), "```"]
    lines += ["", "Deviations: " + "; ".join(summary["deviations"]) + ".", ""]
    if summary["first_failures"]:
        lines += ["### First failures (trimmed)", "", "```text"]
        lines += ["%s / %s: %s" % (f["target"], f["test"], f["message"]) for f in summary["first_failures"]]
        lines += ["```", ""]
    return summary, "\n".join(lines)


def receipt_counts(receipt_dir):
    """Entry counts only; names are classified in memory and never returned."""
    keys = ("receipts_published", "receipts_partial_leftovers", "receipts_other_entries")
    if not receipt_dir or not os.path.isdir(receipt_dir) or os.path.islink(receipt_dir):
        return dict.fromkeys(keys, NA)
    names = os.listdir(receipt_dir)
    partial = [n for n in names if n.startswith(".") and n.endswith(".partial")]
    published = [n for n in names if not n.startswith(".")
                 and os.path.isfile(os.path.join(receipt_dir, n))
                 and not os.path.islink(os.path.join(receipt_dir, n))]
    return dict(zip(keys, (len(published), len(partial), len(names) - len(published) - len(partial))))


def xcresult_summary(bundle):
    """Return (results, error); the error is raw here and redacted by summarize()."""
    if not os.path.isdir(bundle):
        return None, "no result bundle"
    try:
        proc = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=600)
        if proc.returncode == 0:
            return json.loads(proc.stdout), None
        return None, proc.stderr.strip() or "exit %d" % proc.returncode
    except Exception as exc:  # keep the summary robust
        return None, str(exc)


def main():
    env = os.environ
    results, error = xcresult_summary(env["RESULT_BUNDLE"])
    summary, markdown = summarize(env, results, error, receipt_counts(env.get("RECEIPT_DIR", "")))
    out = env["SUMMARY_DIR"]
    with open(os.path.join(out, "summary.json"), "w") as stream:
        json.dump(summary, stream, indent=2, sort_keys=True)
        stream.write("\n")
    with open(os.path.join(out, "summary.md"), "w") as stream:
        stream.write(markdown + "\n")
    with open(env["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write(markdown + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
