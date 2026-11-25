"""Source-only bind -> re-check -> launch composition for one iOS attempt.

The module performs no IO or execution of its own: reads happen only inside
the injected ``validate`` callable and commands only inside the injected
``command`` callback. It adds ordering and a bind-time digest snapshot; it
does not close the time-of-check/time-of-use window before xcodebuild reads
the prepared xctestrun.
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

    Order: the callbacks and expected test IDs are checked; ``bind_launch``
    binds the supplied values; ``bound_digests`` takes the input/output digests
    from the immutable Products record line and snapshots the canonical intent
    digest (refusing an intent that no longer carries the record's digests); ``recheck_before_launch`` re-validates
    on disk (through ``validate``) and requires those bound digests; only then
    does ``run_launch`` create the owned simulator and send commands. A refusal
    or exception at any stage stops every later stage. Stage semantics are
    unchanged: binder and checks raise ``Refusal``, ``validate`` exceptions
    become the re-check's closed refusal, runner exceptions propagate after the
    lifecycle's single cleanup attempt, and ``KeyboardInterrupt``/``SystemExit``
    are never converted.

    The re-check runs before, not inside, the owned-simulator operation: a bad
    input is then refused without creating or deleting any device, and
    ``run_launch`` exposes no pre-test hook. The window therefore also spans
    simulator creation and the ownership proof.
    """
    if not callable(command) or not callable(observe):
        raise Refusal("command and observe callbacks must be callable")
    launch_outcome._expected_ids(expected_test_ids)
    binding = launch_binding.bind_launch(
        reviewed_head=reviewed_head, products_record_line=products_record_line,
        intent=intent, run_uuid=run_uuid, xctestrun_path=xctestrun_path,
        result_bundle_path=result_bundle_path)
    digests = launch_recheck.bound_digests(products_record_line, intent)
    binding = launch_recheck.recheck_before_launch(binding, intent=intent, validate=validate,
                                                   bound_digests=digests)
    run_uuid, xctestrun, bundle = binding
    return launch_runner.run_launch(run_uuid, command, expected_test_ids=expected_test_ids,
                                    xctestrun_path=xctestrun, result_bundle_path=bundle,
                                    observe=observe)
