"""Pure same-job binding of a Products observation record to launch inputs.

No IO, execution or CLI: every value is supplied by the caller and only
compared. This is same-job consistency at the xctestrun level, not
provenance, custody, a whole-Products inventory or a launch-time byte check.
"""

import json
import re
import unicodedata

import ios_launch_plan as launch_plan
import ios_launch_runner as launch_runner
import ios_runtime
import observation_runner as products
import prepare
import source_snapshot_integration as integration
from ios_launch_plan import Refusal


RECORD_REFUSAL = "invalid Products observation record"
_INTENT_KEYS = ("schema_version", "profile", "qualification", "run_id", "targets",
                "input", "output", "intent_path", "provider_observation")
_TARGETS = ["FluxKlangTests", "FluxKlangUITests"]


def _require(condition, message):
    if not condition:
        raise Refusal(message)


def _shape(value, keys, message):
    _require(type(value) is dict and set(value) == set(keys) and len(value) == len(keys),
             message)
    return value


def _text(value, pattern, message):
    _require(type(value) is str
             and re.fullmatch(pattern, value, flags=re.ASCII) is not None, message)
    return value


def _exact(value, expected, message):
    _require(type(value) is type(expected) and value == expected, message)
    return value


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, RECORD_REFUSAL)
        result[key] = value
    return result


def _constant(_value):
    raise Refusal(RECORD_REFUSAL)


def _observation(line):
    """Return the strictly checked observation object of one record line."""
    message = RECORD_REFUSAL
    _require(type(line) is bytes and len(line) <= products._RECORD_LIMIT
             and line.endswith(b"\n") and line.count(b"\n") == 1, message)
    try:
        record = json.loads(line.decode("ascii"), object_pairs_hook=_pairs,
                            parse_constant=_constant)
        canonical = json.dumps(record, sort_keys=True, separators=(",", ":"),
                               ensure_ascii=True, allow_nan=False).encode("ascii") + b"\n"
    except Refusal:
        raise
    except Exception as error:
        raise Refusal(message) from error
    _require(canonical == line, message)

    def oid(value):
        return _text(value, r"[0-9a-f]{40}", message)

    def digest(value):
        return _text(value, r"[0-9a-f]{64}", message)

    def fixed(value, expected):
        _shape(value, tuple(expected), message)
        for key, wanted in expected.items():
            _exact(value[key], wanted, message)

    _shape(record, ("schema", "observation"), message)
    _exact(record["schema"], products._RECORD_SCHEMA, message)
    observation = _shape(record["observation"], (
        "assurance", "checkout", "workflow", "sources", "runner", "xcode", "runtime",
        "checker", "prepared"), message)
    _exact(observation["assurance"], products._RECORD_ASSURANCE, message)
    checkout = _shape(observation["checkout"], ("commit", "tree"), message)
    oid(checkout["commit"])
    oid(checkout["tree"])
    workflow = _shape(observation["workflow"], ("path", "sha", "blob"), message)
    _exact(workflow["path"], products._PRODUCTS_WORKFLOW, message)
    oid(workflow["sha"])
    oid(workflow["blob"])
    sources = _shape(observation["sources"], integration._PATHS_V5, message)
    for path in integration._PATHS_V5:
        source = _shape(sources[path], ("blob", "sha256"), message)
        oid(source["blob"])
        digest(source["sha256"])
    fixed(observation["runner"], products._RECORD_RUNNER)
    fixed(observation["xcode"], products._RECORD_XCODE)
    fixed(observation["runtime"], {"identifier": ios_runtime.RUNTIME,
                                   **products._RECORD_RUNTIME})
    fixed(observation["checker"], {"size": ios_runtime.LIBRARY_SIZE,
                                   "sha256": ios_runtime.LIBRARY_SHA256})
    prepared = _shape(observation["prepared"], ("input_sha256", "output_sha256"), message)
    digest(prepared["input_sha256"])
    digest(prepared["output_sha256"])
    return observation


def _file(value, message):
    _shape(value, ("path", "sha256"), message)
    _text(value["sha256"], r"[0-9a-f]{64}", message)
    _require(type(value["path"]) is str, message)
    return value


def _folded(path):
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", path).casefold())


def bind_launch(*, reviewed_head, products_record_line, intent, run_uuid,
                xctestrun_path, result_bundle_path):
    """Return (run_uuid, xctestrun_path, result_bundle_path) or refuse.

    Binds only supplied values: the reviewed head and the record's checkout,
    the record's prepared digests and the provider-profile intent, the intent's
    run-linked prepared path, and a result bundle outside the Products folder.
    """
    _text(reviewed_head, r"[0-9a-f]{40}", "reviewed head must be a lowercase commit ID")
    observation = _observation(products_record_line)
    _require(reviewed_head == observation["checkout"]["commit"],
             "reviewed head does not match the observed checkout")

    message = "intent is not a provider-profile intent"
    _shape(intent, _INTENT_KEYS, message)
    _exact(intent["schema_version"], 3, message)
    _exact(intent["profile"], prepare.IOS_PROVIDER_RUNTIME_PROFILE, message)
    _exact(intent["qualification"], "partial-regression", message)
    _exact(intent["targets"], _TARGETS, message)
    _require(all(type(target) is str for target in intent["targets"]), message)
    _require(type(intent["provider_observation"]) is dict, message)
    source = _file(intent["input"], message)
    output = _file(intent["output"], message)
    _require(type(intent["intent_path"]) is str, message)

    prepared = observation["prepared"]
    _require(source["sha256"] == prepared["input_sha256"]
             and output["sha256"] == prepared["output_sha256"],
             "intent digests do not match the observed prepared digests")

    run_uuid = launch_plan.canonical_run_uuid(run_uuid)
    run_id = intent["run_id"]
    _require(type(run_id) is str, "intent run ID does not match the run UUID")
    try:
        prepare.check_run_id(run_id)
    except prepare.Refusal as error:
        raise Refusal("intent run ID does not match the run UUID") from error
    _require(run_id == run_uuid, "intent run ID does not match the run UUID")

    input_path = launch_runner._absolute_path(source["path"], "intent input path",
                                              ".xctestrun")
    # prepare.Path is the concrete pathlib.Path; output_paths only uses
    # with_name/stem/with_suffix, which perform no IO.
    expected_output, expected_intent = prepare.output_paths(prepare.Path(input_path), run_id)
    _require((output["path"], intent["intent_path"])
             == (str(expected_output), str(expected_intent)),
             "intent paths are not the run-linked sibling paths")

    xctestrun = launch_runner._absolute_path(xctestrun_path, "xctestrun path", ".xctestrun")
    _require(xctestrun != input_path, "xctestrun path must not be the original candidate")
    _require(xctestrun == output["path"], "xctestrun path must be the prepared output")

    bundle = launch_runner._absolute_path(result_bundle_path, "result bundle path",
                                          ".xcresult")
    # Lexical only (symlinks are not resolved), folded conservatively for
    # case-insensitive, normalization-insensitive macOS file systems.
    root = _folded(input_path[:input_path.rindex("/")])
    folded = _folded(bundle)
    _require(not (folded == root or folded.startswith(root + "/")
                  or root.startswith(folded + "/")),
             "result bundle must be outside the Products directory")
    return run_uuid, xctestrun, bundle
