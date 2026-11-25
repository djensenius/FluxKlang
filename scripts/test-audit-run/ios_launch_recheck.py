"""Pre-launch re-check of the bound prepared inputs through an injected validator.

The module itself performs no IO or execution: all reads happen inside the
injected ``validate`` callable (``prepare.validate`` in bounded-material mode
by default). Re-checking narrows, but does not close, the window before
xcodebuild reads the prepared xctestrun.
"""

import ios_launch_binding as launch_binding
import ios_launch_plan as launch_plan
import prepare
from ios_launch_plan import Refusal


VALIDATE_REFUSAL = "prepared inputs failed the pre-launch re-check"
DIGEST_REFUSAL = "re-validated digests do not match the bound intent"
PATH_REFUSAL = "re-validated paths do not match the bound intent"
RECORD_REFUSAL = "re-validated intent does not match the bound intent"


def _require(condition, message):
    if not condition:
        raise Refusal(message)


def recheck_before_launch(binding, *, intent, validate=None):
    """Return ``binding`` unchanged after a fresh on-disk re-validation, or refuse.

    ``binding`` is the exact ``(run_uuid, xctestrun_path, result_bundle_path)``
    tuple returned by ``ios_launch_binding.bind_launch``; ``intent`` must be the
    same intent dict that was passed to that call (the binding carries no input
    path, pin or intent path). ``validate`` is called exactly once as
    ``validate(input_path, input_sha256, IOS_PROVIDER_RUNTIME_PROFILE,
    output_path, intent_path, bounded_material=True)`` and must return a
    record equal (type-exactly) to ``intent``.
    """
    message = "binding is not a bind_launch result"
    _require(type(binding) is tuple and len(binding) == 3
             and all(type(value) is str for value in binding), message)
    run_uuid, xctestrun, _bundle = binding
    _require(launch_plan.canonical_run_uuid(run_uuid) == run_uuid, message)

    message = "intent is not a provider-profile intent"
    launch_binding._shape(intent, launch_binding._INTENT_KEYS, message)
    launch_binding._exact(intent["profile"], prepare.IOS_PROVIDER_RUNTIME_PROFILE, message)
    source = launch_binding._file(intent["input"], message)
    output = launch_binding._file(intent["output"], message)
    _require(type(intent["intent_path"]) is str, message)
    _require(type(intent["run_id"]) is str and intent["run_id"] == run_uuid,
             "intent run ID does not match the binding")
    _require(output["path"] == xctestrun, "intent output path does not match the binding")

    if validate is None:
        validate = prepare.validate
    _require(callable(validate), "validate must be callable")
    try:
        record = validate(source["path"], source["sha256"],
                          prepare.IOS_PROVIDER_RUNTIME_PROFILE, output["path"],
                          intent["intent_path"], bounded_material=True)
    except Exception as error:
        raise Refusal(VALIDATE_REFUSAL) from error

    launch_binding._shape(record, launch_binding._INTENT_KEYS, RECORD_REFUSAL)
    checked_source = launch_binding._file(record["input"], RECORD_REFUSAL)
    checked_output = launch_binding._file(record["output"], RECORD_REFUSAL)
    _require((checked_source["sha256"], checked_output["sha256"])
             == (source["sha256"], output["sha256"]), DIGEST_REFUSAL)
    _require(type(record["intent_path"]) is str
             and (checked_source["path"], checked_output["path"], record["intent_path"])
             == (source["path"], output["path"], intent["intent_path"]), PATH_REFUSAL)
    try:
        prepare.require_equal(record, intent, "re-validated intent")
    except Exception as error:
        raise Refusal(RECORD_REFUSAL) from error
    return binding
