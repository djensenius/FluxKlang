"""Pure closed honest-outcome record for a future iOS launch attempt.

Every result and receipt observation is supplied as data. Nothing here
launches, inspects, reads or writes anything. A "passed" record states only
that the supplied observations were complete and passing; it is a
provider-trusted labeled regression observation, not provenance, custody,
production-access proof or #60 qualification.
"""

import json

import ios_launch_plan as launch_plan
from ios_launch_plan import Refusal


SCHEMA = "fluxklang-ios-launch-outcome"
SCHEMA_VERSION = 1

# Observed per-test statuses a caller may supply. "absent" is assigned only by
# the evaluator, to an expected test with no observation.
OBSERVED_TEST_STATUSES = ("passed", "failed", "skipped")
TEST_STATUSES = OBSERVED_TEST_STATUSES + ("absent",)
RECEIPT_STATUSES = ("present", "unavailable", "irregular")
OUTCOMES = ("passed", "failed", "incomplete", "unavailable")
RECEIPT_KEYS = ("published", "partial_leftovers", "other_entries")

MAX_TESTS = 4096
MAX_TEST_ID_LENGTH = 256
# Escaped ASCII-JSON size per ID, so MAX_TESTS IDs always fit MAX_RECORD_BYTES.
MAX_TEST_ID_JSON_BYTES = 1024
MAX_RECEIPT_ENTRIES = 1_000_000
MAX_RECORD_BYTES = 8 * 1024 * 1024

# Fixed statements; no parameter can replace, remove or extend them.
_DISCLAIMERS = (
    ("scope", "provider-trusted labeled regression observation only"),
    ("provenance", "not provenance or custody evidence"),
    ("production_access", "not production-access proof"),
    ("qualification", "not #60 qualification"),
)


def _test_id(value):
    if type(value) is not str or not 1 <= len(value) <= MAX_TEST_ID_LENGTH:
        raise Refusal("test ID must be bounded non-empty text")
    if value != value.strip():
        raise Refusal("test ID must not have surrounding whitespace")
    if any(
        ord(char) < 0x20
        or 0x7f <= ord(char) <= 0x9f
        or char in ("\u2028", "\u2029")
        for char in value
    ):
        raise Refusal("test ID must not contain control or line separators")
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise Refusal("test ID must be UTF-8") from error
    if len(json.dumps(value, ensure_ascii=True)) > MAX_TEST_ID_JSON_BYTES:
        raise Refusal("test ID encoded size limit")
    return value


def _expected_ids(expected):
    if type(expected) is not tuple or not 1 <= len(expected) <= MAX_TESTS:
        raise Refusal("expected test IDs must be a bounded non-empty tuple")
    ids = tuple(_test_id(item) for item in expected)
    if len(set(ids)) != len(ids):
        raise Refusal("expected test IDs must be unique")
    return ids


def _observed_statuses(observed, expected_ids):
    """Unknown or duplicate observed IDs are refused, never counted or dropped."""
    if type(observed) is not tuple or len(observed) > len(expected_ids):
        raise Refusal("observed results must be a tuple within the expected count")
    known = set(expected_ids)
    statuses = {}
    for entry in observed:
        if type(entry) is not tuple or len(entry) != 2:
            raise Refusal("observed result must be a (test ID, status) tuple")
        test_id, status = _test_id(entry[0]), entry[1]
        if type(status) is not str or status not in OBSERVED_TEST_STATUSES:
            raise Refusal("observed status must be passed, failed or skipped")
        if test_id not in known:
            raise Refusal("observed test ID was not expected")
        if test_id in statuses:
            raise Refusal("observed test ID is duplicated")
        statuses[test_id] = status
    return statuses


def _receipt(observation):
    """None means no receipt observation: unavailable, never a pass."""
    if observation is None:
        return dict(dict.fromkeys(RECEIPT_KEYS), status="unavailable")
    if type(observation) is not dict or set(observation) != set(RECEIPT_KEYS):
        raise Refusal("receipt observation must be None or exact counts")
    for key in RECEIPT_KEYS:
        value = observation[key]
        if type(value) is not int or not 0 <= value <= MAX_RECEIPT_ENTRIES:
            raise Refusal("receipt counts must be bounded non-negative integers")
    if observation["partial_leftovers"] or observation["other_entries"]:
        status = "irregular"
    elif observation["published"] == 0:
        status = "unavailable"
    else:
        status = "present"
    return dict({key: observation[key] for key in RECEIPT_KEYS}, status=status)


def _evaluate(run_uuid, expected_test_ids, observed_results, receipt_observation):
    run_uuid = launch_plan.canonical_run_uuid(run_uuid)
    expected_ids = _expected_ids(expected_test_ids)
    statuses = _observed_statuses(observed_results, expected_ids)
    receipt = _receipt(receipt_observation)
    tests = [{"id": test_id, "status": statuses.get(test_id, "absent")}
             for test_id in expected_ids]
    counts = {status: 0 for status in TEST_STATUSES}
    for test in tests:
        counts[test["status"]] += 1

    if counts["failed"] or receipt["status"] == "irregular":
        outcome = "failed"
    elif counts["absent"] or counts["skipped"]:
        outcome = "incomplete"
    elif receipt["status"] != "present":
        outcome = "unavailable"
    else:
        outcome = "passed"
    return {
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "run_uuid": run_uuid,
        "outcome": outcome,
        "exit_code": 0 if outcome == "passed" else 1,
        "tests": tests,
        "test_counts": dict(counts, expected=len(tests)),
        "receipt": receipt,
        "disclaimers": dict(_DISCLAIMERS),
    }


def evaluate(plan, expected_test_ids, observed_results, receipt_observation):
    """Return a new closed outcome record; exit_code is 0 only for "passed".

    plan: an actual LaunchPlan (only its run UUID is recorded).
    expected_test_ids: non-empty tuple of unique test IDs.
    observed_results: tuple of (test ID, "passed"|"failed"|"skipped") tuples.
    receipt_observation: None, or a dict of exactly the RECEIPT_KEYS counts.

    Precedence: any failed test or irregular receipt is "failed"; otherwise
    any absent or skipped expected test is "incomplete"; otherwise a missing
    or empty receipt is "unavailable"; only then "passed". Unknown or
    duplicate observed IDs and malformed values raise Refusal, which callers
    must treat as a non-zero failure.
    """
    if type(plan) is not launch_plan.LaunchPlan:
        raise Refusal("plan must be a LaunchPlan")
    # Rebuilding re-runs every plan invariant, so a plan mutated after
    # construction (e.g. a run UUID that no longer keys its receipt location)
    # is refused rather than recorded.
    rebuilt = launch_plan.LaunchPlan(plan.run_uuid, plan.candidate_device_uuid,
                                     plan.receipt_directory_relative)
    if rebuilt != plan:
        raise Refusal("plan fields are inconsistent")
    return _evaluate(plan.run_uuid, expected_test_ids, observed_results,
                     receipt_observation)


def _canonical_bytes(record):
    try:
        text = json.dumps(record, sort_keys=True, separators=(",", ":"),
                          ensure_ascii=True, allow_nan=False)
    except (TypeError, ValueError, RecursionError) as error:
        raise Refusal("outcome record must be JSON data") from error
    return (text + "\n").encode("ascii")


def encode(record):
    """Canonical ASCII JSON bytes for a record that decode() accepts."""
    data = _canonical_bytes(record)
    if len(data) > MAX_RECORD_BYTES:
        raise Refusal("outcome record byte limit")
    if decode(data) != record:
        raise Refusal("record is not a closed outcome record")
    return data


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal("duplicate JSON key")
        result[key] = value
    return result


def _invalid_constant(value):
    raise Refusal(f"invalid JSON constant {value}")


def decode(data):
    """Parse canonical bytes and require the exact record its data re-derives.

    Recomputing from the recorded run UUID, tests and receipt counts enforces
    exact keys, the closed vocabularies, derived outcome/exit code/counts and
    the fixed disclaimers in one comparison.
    """
    if type(data) is not bytes or len(data) > MAX_RECORD_BYTES:
        raise Refusal("outcome record must be bounded bytes")
    try:
        record = json.loads(data.decode("utf-8"), object_pairs_hook=_unique_pairs,
                            parse_constant=_invalid_constant)
    except (UnicodeError, RecursionError, ValueError) as error:
        if isinstance(error, Refusal):
            raise
        raise Refusal("outcome record must be JSON") from error
    try:
        tests = record["tests"]
        expected = tuple(test["id"] for test in tests)
        observed = tuple((test["id"], test["status"]) for test in tests
                         if test["status"] != "absent")
        receipt = record["receipt"]
        counts = None if receipt["status"] == "unavailable" and all(
            receipt[key] is None for key in RECEIPT_KEYS
        ) else {key: receipt[key] for key in RECEIPT_KEYS}
        derived = _evaluate(record["run_uuid"], expected, observed, counts)
    except (TypeError, KeyError) as error:
        raise Refusal("outcome record has an invalid shape") from error
    if derived != record:
        raise Refusal("outcome record is not closed or consistent")
    if _canonical_bytes(derived) != data:
        raise Refusal("outcome record bytes are not canonical")
    return derived
