#!/usr/bin/env python3
"""Summary-only iOS adapter. No receipt contents; no Mac transport/qualification claims."""

import json
import os
from pathlib import Path
import re
import stat
from urllib.parse import unquote

from observation_summary import AUDIT, NA, text

RECEIPT = re.compile(
    r"production-access-(?:suiteExit|testCaseExit)-"
    r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\.json")
COUNT_KEYS = ("receipts_published", "receipts_partial_leftovers", "receipts_other_entries")
LIMITATIONS = [
    "Observation only; not #60 qualification or earliest-host isolation proof.",
    "CODE_SIGNING_ALLOWED=NO, ARCHS=arm64; no claim that the iOS host is unsandboxed.",
    "Run-local xctestrun pin, not independently reviewed.",
    "TEST_RUNNER_ delivery and iOS sandbox access are not proven by host preflight. "
    "The #703 unit-scope guard must refuse before its body if file transport is unavailable.",
    "UI runner/app audit transport is separate and unchanged; file counts cover unit transport only.",
]


def safe_text(value, limit, run_id):
    # Also handle URL-encoded and escaped path forms before using the reviewed primitives.
    value = str(value)
    for _ in range(8):
        decoded = unquote(value)
        if decoded == value:
            break
        value = decoded
    else:
        return "<encoded-text>"
    return text(value.replace("\\", "/"), limit, run_id)


def sanitized(value, run_id="", limit=1000):
    if isinstance(value, dict):
        return {safe_text(k, 100, run_id): sanitized(v, run_id, 4000 if k == "test_argv" else limit)
                for k, v in value.items()}
    if isinstance(value, list):
        return [sanitized(v, run_id, limit) for v in value]
    if isinstance(value, str):
        return safe_text(value, limit, run_id)
    return value


def receipt_counts(directory):
    """Classify entries in memory; never return filenames or open their contents."""
    counts = dict.fromkeys(COUNT_KEYS, NA)
    if directory is None:
        return counts
    try:
        info = Path(directory).lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            return counts
        values = [0, 0, 0]
        for entry in Path(directory).iterdir():
            regular = stat.S_ISREG(entry.lstat().st_mode)
            name = entry.name
            if regular and RECEIPT.fullmatch(name):
                values[0] += 1
            elif regular and name.startswith(".") and name.endswith(".partial") and RECEIPT.fullmatch(name[1:-8]):
                values[1] += 1
            else:
                values[2] += 1
        return dict(zip(COUNT_KEYS, values))
    except OSError:
        return counts


def summarize(state, results=None, error=None, counts=None):
    """Pure formatter: unavailable evidence is never a zero."""
    summary = dict(state)
    summary["limitations"] = LIMITATIONS
    summary["xcresult_error"] = error
    results = results if isinstance(results, dict) else {}
    summary["result"] = results.get("result", NA)
    for source, dest in (("totalTestCount", "total"), ("passedTests", "passed"),
                         ("failedTests", "failed"), ("skippedTests", "skipped"),
                         ("expectedFailures", "expected_failures_known_issues")):
        value = results.get(source)
        summary[dest] = value if type(value) is int and value >= 0 else NA
    failures = results.get("testFailures")
    valid = isinstance(failures, list) and all(isinstance(f, dict) for f in failures)
    summary["failure_count"] = len(failures) if valid else NA
    summary["audit_failure_count"] = sum(
        bool(AUDIT.search(str(f.get("testName", "")) + " " + str(f.get("failureText", ""))))
        for f in failures) if valid else NA
    summary["first_failures"] = [
        {key: f.get(key, NA) for key in ("targetName", "testName", "failureText")}
        for f in failures[:20]] if valid else []
    summary.update(counts or dict.fromkeys(COUNT_KEYS, NA))
    summary = sanitized(summary, state.get("run_id", ""))
    lines = ["## iOS isolated observation", "", "| Field | Value |", "| --- | --- |"]
    for key, value in summary.items():
        if not isinstance(value, (dict, list)):
            lines.append("| %s | %s |" % (key, str(value).replace("|", "\\|")))
    lines += ["", "Test argv (sanitized, possibly truncated; not exact):", "",
              "```text", json.dumps(summary.get("test_argv", NA), ensure_ascii=True), "```", "",
              "### First failures (sanitized/trimmed)", "```json",
              json.dumps(summary["first_failures"], indent=2, ensure_ascii=True), "```", "",
              "### Cleanup failures", "```json",
              json.dumps(summary.get("cleanup_failures", []), indent=2, ensure_ascii=True), "```", ""]
    for key in ("metadata_fields", "metadata_mismatches", "runtime_evidence"):
        if key in summary:
            lines += ["### " + key + " (sanitized; evidence only)", "```json",
                      json.dumps(summary[key], indent=2, ensure_ascii=True), "```", ""]
    lines += ["- " + item for item in summary["limitations"]]
    return summary, "\n".join(lines) + "\n"


def write_summary(directory, state, results=None, error=None, counts=None, step_summary=None):
    summary, markdown = summarize(state, results, error, counts)
    directory = Path(directory)
    # Caller owns this fresh directory. Atomic replacement keeps an earlier sanitized summary
    # available if a later write is interrupted; raw state/logs are never persisted here.
    for name, content in (("summary.json", json.dumps(summary, indent=2, sort_keys=True) + "\n"),
                          ("summary.md", markdown)):
        temporary = directory / (name + ".new")
        with temporary.open("x", encoding="utf-8") as stream:
            stream.write(content)
        temporary.replace(directory / name)
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as stream:
            stream.write(markdown)
    return summary
