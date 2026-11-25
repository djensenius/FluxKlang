"""Source-only composition of one owned-simulator iOS launch attempt.

Every command goes through the caller's injected callback as a direct argv
tuple; there is no default executor. The xcodebuild/simctl argv syntax, the
xctestrun shape and all result parsing are UNVERIFIED: result interpretation
is delegated to a strictly shaped injected observation callback.
"""

import ios_launch_outcome as launch_outcome
import ios_launch_plan as launch_plan
import ios_runtime
import ios_simulator_lifecycle as lifecycle
from ios_launch_plan import Refusal


XCODEBUILD = ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"
APP_BUNDLE_IDENTIFIER = "org.davidjensenius.FluxKlang"
TEST_TIMEOUT_SECONDS = 1800
MAX_PATH_BYTES = 1024


def _absolute_path(value, label, suffix):
    if type(value) is not str or not value.endswith(suffix):
        raise Refusal(f"{label} must be text ending in {suffix}")
    try:
        launch_plan._canonical_absolute_root(value)
    except Refusal as error:
        raise Refusal(f"{label} must be a canonical absolute path") from error
    if len(value.encode("utf-8")) > MAX_PATH_BYTES:
        raise Refusal(f"{label} exceeds the path byte limit")
    return value


def xcodebuild_argv(xctestrun_path, result_bundle_path, device_uuid):
    """The fixed, UNVERIFIED xcodebuild argv; DEVELOPER_DIR is not carried."""
    return (
        XCODEBUILD, "test-without-building",
        "-xctestrun", xctestrun_path,
        "-destination", f"id={device_uuid}",
        "-parallel-testing-enabled", "NO",
        "-test-iterations", "1",
        "-resultBundlePath", result_bundle_path,
    )


def container_argv(device_uuid):
    """The fixed, UNVERIFIED data-container query argv."""
    return (launch_plan.CORE_SIMULATOR_SIMCTL, "get_app_container",
            device_uuid, APP_BUNDLE_IDENTIFIER, "data")


def _container_root(result):
    """One canonical absolute path line on success; otherwise None."""
    if result.returncode != 0:
        return None
    try:
        text = result.stdout.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise Refusal("container output must be UTF-8") from error
    if text.endswith("\n"):
        text = text[:-1]
    if "\n" in text or "\r" in text:
        raise Refusal("container output must be one path line")
    if len(text.encode("utf-8")) > MAX_PATH_BYTES:
        raise Refusal("container path exceeds the path byte limit")
    return launch_plan._canonical_absolute_root(text)


def _observation(value, receipt_directory):
    if type(value) is not tuple or len(value) != 2:
        raise Refusal("observation must be (observed results, receipt counts)")
    observed, receipt = value
    if receipt_directory is None and receipt is not None:
        raise Refusal("receipt counts require a located receipt directory")
    return observed, receipt


def run_launch(run_uuid, command, *, expected_test_ids, xctestrun_path,
               result_bundle_path, observe):
    """Return encoded closed outcome bytes for one owned-simulator attempt.

    Inputs are validated before any command. Inside the lifecycle operation it
    plans with the owned UUID, invokes xcodebuild_argv (1800 s, 2 MiB) then
    container_argv (30 s, 2 MiB) through the same command callback, and calls
    observe(plan=, test_result=, receipt_directory=) which must return
    (observed_results, receipt_observation) in ios_launch_outcome shapes;
    receipt_directory is None when no container was located, and then
    receipt_observation must be None. A record that would be "passed" despite
    a non-zero (including negative) xcodebuild return code is refused, never
    returned or downgraded; other outcomes are returned. Refusals, operation errors
    and termination propagate after the lifecycle's single cleanup attempt.
    """
    run_uuid = launch_plan.canonical_run_uuid(run_uuid)
    expected = launch_outcome._expected_ids(expected_test_ids)
    xctestrun = _absolute_path(xctestrun_path, "xctestrun path", ".xctestrun")
    bundle = _absolute_path(result_bundle_path, "result bundle path", ".xcresult")
    if not callable(command) or not callable(observe):
        raise Refusal("command and observe callbacks must be callable")

    def operation(owned_uuid):
        plan = launch_plan.plan_launch(run_uuid, owned_uuid)
        test_result = lifecycle._command_result(command(
            xcodebuild_argv(xctestrun, bundle, owned_uuid),
            timeout=TEST_TIMEOUT_SECONDS,
            max_output_bytes=lifecycle.MAX_OUTPUT_BYTES,
        ))
        root = _container_root(lifecycle._invoke(command, container_argv(owned_uuid)))
        directory = None if root is None else launch_plan.receipt_environment_overlay(
            plan, root)[launch_plan.RECEIPT_ENVIRONMENT_KEY]
        observed, receipt = _observation(observe(
            plan=plan, test_result=test_result, receipt_directory=directory,
        ), directory)
        record = launch_outcome.evaluate(plan, expected, observed, receipt)
        if record["outcome"] == "passed" and test_result.returncode != 0:
            raise Refusal("passing observations contradict a non-zero test exit")
        return launch_outcome.encode(record)

    return lifecycle.with_owned_simulator(run_uuid, command, operation)
