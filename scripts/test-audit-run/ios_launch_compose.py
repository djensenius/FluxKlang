"""Source-only bind -> re-check -> launch composition for one iOS attempt.

The module performs no IO or execution of its own: reads happen only inside
the injected ``validate`` callable and commands only inside the injected
``command`` callback. It adds ordering, a bind-time digest snapshot and a
second re-check immediately before xcodebuild; that narrows, but does not
close, the time-of-check/time-of-use window before xcodebuild reads the
prepared xctestrun.
"""

import ios_launch_binding as launch_binding
import ios_launch_outcome as launch_outcome
import ios_launch_recheck as launch_recheck
import ios_launch_runner as launch_runner
from ios_launch_plan import Refusal


def bind_recheck_and_launch(*, reviewed_head, products_record_line, intent, run_uuid,
                            xctestrun_path, result_bundle_path, expected_test_ids,
                            command, observe, validate=None):
    """Return encoded closed outcome bytes, or raise after the failing stage.

    Order: the callbacks and expected test IDs are checked; ``bound_digests``
    takes the input/output digests from the immutable Products record line and
    snapshots the intent digest (refusing an intent that does not carry the
    record's digests); ``bind_launch`` binds the supplied values, including that
    same intent; an early ``recheck_before_launch`` re-validates on disk
    (through ``validate``) and requires the snapshotted digests; only then does
    ``run_launch`` create and prove ownership of the simulator, after which its
    ``before_test`` hook runs the same re-check (same binding, intent, digests
    and ``validate``) again immediately before the xcodebuild command. On
    success ``validate`` is therefore called exactly twice; a refusal at the
    early re-check sends no command, and a refusal at the hook re-check sends
    no xcodebuild command but still deletes the owned device once.

    A refusal or exception at any stage stops every later stage. Stage
    semantics are unchanged: binder and checks raise ``Refusal``, ``validate``
    exceptions become the re-check's closed refusal, runner (including hook)
    exceptions propagate after the lifecycle's single cleanup attempt, and
    ``KeyboardInterrupt``/``SystemExit`` are never converted.

    The early re-check fails fast without device churn; the hook re-check
    narrows the window to the time between it and xcodebuild opening the
    files, which remains: xcodebuild re-opens the xctestrun and the
    uninventoried Products bundles after the hook returns.
    """
    if not callable(command) or not callable(observe):
        raise Refusal("command and observe callbacks must be callable")
    launch_outcome._expected_ids(expected_test_ids)
    digests = launch_recheck.bound_digests(products_record_line, intent)
    binding = launch_binding.bind_launch(
        reviewed_head=reviewed_head, products_record_line=products_record_line,
        intent=intent, run_uuid=run_uuid, xctestrun_path=xctestrun_path,
        result_bundle_path=result_bundle_path)
    binding = launch_recheck.recheck_before_launch(binding, intent=intent, validate=validate,
                                                   digests=digests)

    def recheck_before_test():
        launch_recheck.recheck_before_launch(binding, intent=intent, validate=validate,
                                             digests=digests)

    run_uuid, xctestrun, bundle = binding
    return launch_runner.run_launch(run_uuid, command, expected_test_ids=expected_test_ids,
                                    xctestrun_path=xctestrun, result_bundle_path=bundle,
                                    observe=observe, before_test=recheck_before_test)
