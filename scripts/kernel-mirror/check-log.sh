#!/usr/bin/env bash
# Checks one `swift test` log of the kernel mirror and prints its Swift Testing test count.
#
# Usage: scripts/kernel-mirror/check-log.sh <log> [<required passed test>]... \
#          [--expect-skipped <test> <reason substring>]...
#
# Fails when the log has any ThreadSanitizer report, no passing "Test run with N tests" summary or
# N = 0, when a required test is reported skipped or not reported passed (so a disabled probe
# cannot pass silently), or when an --expect-skipped test was not skipped with a reason containing
# the substring (e.g. the allocation probe's Thread Sanitizer skip proves the TSan runtime is
# loaded). The caller's own exit status still decides test failures.
set -euo pipefail

usage() { echo "usage: $0 <log> [<required passed test>]... [--expect-skipped <test> <reason>]..." >&2; exit 2; }
die() { echo "::error::kernel-mirror $log: $*" >&2; exit 1; }

[ "$#" -ge 1 ] || usage
log=$1; shift
[ -f "$log" ] && [ -s "$log" ] || die "log missing or empty"

if grep -n -e 'WARNING: ThreadSanitizer' -e 'ThreadSanitizer: reported' "$log" >&2; then
  die "ThreadSanitizer reported an issue"
fi

summary=$(grep -E 'Test run with [0-9]+ tests? .*passed' "$log" | tail -n 1 || true)
[ -n "$summary" ] || die "no passing Swift Testing run summary"
count=$(sed -E 's/.*Test run with ([0-9]+) test.*/\1/' <<< "$summary")
[ "$count" -gt 0 ] || die "the run executed no tests"

while [ "$#" -gt 0 ]; do
  if [ "$1" = --expect-skipped ]; then
    [ "$#" -ge 3 ] && [ -n "$2" ] && [ -n "$3" ] || usage
    name=$2 reason=$3; shift 3
    if grep -F "Test $name passed" "$log" >&2; then die "$name ran instead of being skipped for '$reason': that runtime condition is not active"; fi
    skip=$(grep -F "Test $name skipped" "$log" || true)
    [ -n "$skip" ] || die "$name did not report skipped for '$reason': that runtime condition is not active"
    grep -qF -- "$reason" <<< "$skip" || die "$name skipped without the reason '$reason': $skip"
  else
    name=$1; shift
    if grep -F "Test $name skipped" "$log" >&2; then die "$name was skipped"; fi
    grep -qF "Test $name passed" "$log" || die "$name did not report passed"
  fi
done
echo "$count"
