"""Deterministic tests for the source-only iOS launch planning boundary."""

import ast
from pathlib import Path
import unittest

import ios_launch_plan as launch_plan


class IOSLaunchPlanTests(unittest.TestCase):
    RUN_UUID = "22222222-2222-4222-8222-222222222222"
    CANDIDATE_UUID = "33333333-3333-4333-8333-333333333333"
    RECEIPT_RELATIVE = (
        "Library/Caches/FluxKlangAuditReceipts/22222222-2222-4222-8222-222222222222"
    )

    def test_plan_records_candidate_and_fixed_run_keyed_relative_receipt_location(self):
        plan = launch_plan.plan_launch(
            self.RUN_UUID,
            self.CANDIDATE_UUID,
        )

        self.assertEqual(plan.run_uuid, self.RUN_UUID)
        self.assertEqual(plan.candidate_device_uuid, self.CANDIDATE_UUID)
        self.assertFalse(hasattr(plan, "owned_device_uuid"))
        self.assertFalse(hasattr(plan, "cleanup_target"))
        self.assertEqual(plan.simctl_path, launch_plan.CORE_SIMULATOR_SIMCTL)
        self.assertEqual(plan.simctl_path.rsplit("/", 1)[-1], "simctl")
        self.assertEqual(plan.receipt_directory_relative, self.RECEIPT_RELATIVE)
        self.assertNotIn(launch_plan.RECEIPT_ENVIRONMENT_KEY, vars(plan))

    def test_old_absolute_receipt_api_and_value_are_rejected(self):
        with self.assertRaises(TypeError):
            launch_plan.plan_launch(
                pre_inventory=[],
                created_uuid=self.CANDIDATE_UUID,
                create_returncode=0,
                receipt_directory="/tmp/receipt-dir",
            )
        with self.assertRaises(launch_plan.Refusal):
            launch_plan.LaunchPlan(
                self.RUN_UUID, self.CANDIDATE_UUID, "/tmp/receipt-dir",
            )

    def test_direct_construction_validates_uuid_and_receipt_path_invariants(self):
        for values in (
            ("not-a-uuid", self.CANDIDATE_UUID, self.RECEIPT_RELATIVE),
            (self.RUN_UUID, "not-a-uuid", self.RECEIPT_RELATIVE),
            (self.RUN_UUID, self.CANDIDATE_UUID, "/tmp/receipt-dir"),
            (self.RUN_UUID, self.CANDIDATE_UUID,
             "Library/Caches/../FluxKlangAuditReceipts/" + self.RUN_UUID),
            (self.RUN_UUID, self.CANDIDATE_UUID,
             "Library/Caches/FluxKlangAuditReceipts/11111111-1111-4111-8111-111111111111"),
        ):
            with self.subTest(values=values), self.assertRaises(launch_plan.Refusal):
                launch_plan.LaunchPlan(*values)

    def test_run_uuid_must_be_canonical_uuid4(self):
        for run_uuid in (
            "22222222-2222-1222-8222-222222222222",
            "22222222-2222-4222-8222-22222222222A",
        ):
            with self.subTest(run_uuid=run_uuid), self.assertRaises(launch_plan.Refusal):
                launch_plan.plan_launch(run_uuid, self.CANDIDATE_UUID)

    def test_fixed_signed_simctl_path_cannot_be_overridden(self):
        with self.assertRaises(TypeError):
            launch_plan.LaunchPlan(
                self.RUN_UUID,
                self.CANDIDATE_UUID,
                self.RECEIPT_RELATIVE,
                "/usr/bin/xcrun",
            )
        with self.assertRaises(TypeError):
            launch_plan.LaunchPlan(
                self.RUN_UUID,
                self.CANDIDATE_UUID,
                self.RECEIPT_RELATIVE,
                simctl_path="/usr/bin/xcrun",
            )

    def test_module_has_no_command_executor_or_cli_entrypoint(self):
        source = Path(launch_plan.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imported = {
            alias.name.split(".", 1)[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        }
        imported.update(
            node.module.split(".", 1)[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom) and node.module
        )
        self.assertFalse({"subprocess", "os", "sys", "xcrun"} & imported)
        self.assertFalse(any(
            isinstance(node, ast.If) and
            isinstance(node.test, ast.Compare) and
            isinstance(node.test.left, ast.Name) and node.test.left.id == "__name__"
            for node in ast.walk(tree)
        ))


if __name__ == "__main__":
    unittest.main()
