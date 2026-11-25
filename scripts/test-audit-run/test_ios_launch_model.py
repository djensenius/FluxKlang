"""Tests for the illustrative, source-only synthetic invocation model."""

import ast
from pathlib import Path
import unittest

import ios_launch_model as model


class SyntheticLaunchModelTests(unittest.TestCase):
    CANDIDATE = "synthetic-uuid-candidate"
    OTHER = "synthetic-uuid-other"
    INVENTORY_ARGV = ("ILLUSTRATIVE-ONLY", "synthetic-inventory")
    CREATE_ARGV = (
        "ILLUSTRATIVE-ONLY", "synthetic-create",
        "synthetic-device-parameter", "synthetic-runtime-parameter",
    )
    CLEANUP_ARGV = ("ILLUSTRATIVE-ONLY", "synthetic-cleanup", CANDIDATE)

    def invoke(self, **overrides):
        inputs = {
            "candidate": self.CANDIDATE,
            "inventory_complete": True,
            "inventory": (self.OTHER,),
            "create_returncode": 0,
            "created_uuids": (self.CANDIDATE,),
            "cleanup_returncode": 0,
        }
        inputs.update(overrides)
        return model.model_invocation(**inputs)

    def test_complete_transcript_and_transitions(self):
        result = self.invoke()
        self.assertEqual(result.states, (
            "inventory", "inventory-accepted", "create",
            "creation-confirmed", "cleanup", "cleanup-succeeded",
        ))
        self.assertEqual(result.events, (
            model.Event(self.INVENTORY_ARGV, (True, (self.OTHER,))),
            model.Event(self.CREATE_ARGV, (0, (self.CANDIDATE,))),
            model.Event(self.CLEANUP_ARGV, (0,)),
        ))
        self.assertEqual(result.reason, "ok")
        self.assertTrue(result.eligible_for_simulated_cleanup)

    def test_invalid_candidate_refuses_before_inventory(self):
        for candidate in (None, "", "candidate", "synthetic-uuid-", "synthetic-uuid-A"):
            with self.subTest(candidate=candidate):
                result = self.invoke(candidate=candidate)
                self.assertEqual((result.states, result.events, result.reason),
                                 (("refused",), (), "invalid-candidate"))
                self.assertFalse(result.eligible_for_simulated_cleanup)

    def test_inventory_refusals_never_create_or_cleanup(self):
        cases = (
            (False, (self.OTHER,), "invalid-inventory"),
            (None, (self.OTHER,), "invalid-inventory"),
            (1, (self.OTHER,), "invalid-inventory"),
            (True, None, "invalid-inventory"),
            (True, [self.OTHER], "invalid-inventory"),
            (True, ("bad",), "invalid-inventory"),
            (True, (self.OTHER, None), "invalid-inventory"),
            (True, (self.OTHER, self.OTHER), "invalid-inventory"),
            (True, (self.CANDIDATE,), "candidate-present"),
        )
        for complete, inventory, reason in cases:
            with self.subTest(complete=complete, inventory=inventory):
                result = self.invoke(inventory_complete=complete, inventory=inventory)
                self.assertEqual(result.states, ("inventory", "refused"))
                self.assertEqual(result.events, (
                    model.Event(self.INVENTORY_ARGV, (complete, inventory)),
                ))
                self.assertEqual(result.reason, reason)
                self.assertFalse(result.eligible_for_simulated_cleanup)

    def test_failed_ambiguous_or_mismatched_creation_never_cleans_up(self):
        cases = (
            (1, (self.CANDIDATE,), "creation-failed-or-ambiguous"),
            (None, (self.CANDIDATE,), "creation-failed-or-ambiguous"),
            (False, (self.CANDIDATE,), "creation-failed-or-ambiguous"),
            (0, None, "creation-failed-or-ambiguous"),
            (0, [], "creation-failed-or-ambiguous"),
            (0, (), "creation-failed-or-ambiguous"),
            (0, (self.CANDIDATE, self.CANDIDATE), "creation-failed-or-ambiguous"),
            (0, ("bad",), "creation-failed-or-ambiguous"),
            (0, (self.OTHER,), "created-uuid-mismatch"),
        )
        for code, created, reason in cases:
            with self.subTest(code=code, created=created):
                result = self.invoke(create_returncode=code, created_uuids=created)
                self.assertEqual(result.states, (
                    "inventory", "inventory-accepted", "create", "refused",
                ))
                self.assertEqual(result.events, (
                    model.Event(self.INVENTORY_ARGV, (True, (self.OTHER,))),
                    model.Event(self.CREATE_ARGV, (code, created)),
                ))
                self.assertEqual(result.reason, reason)
                self.assertFalse(result.eligible_for_simulated_cleanup)

    def test_cleanup_failure_is_failure_without_retry(self):
        for code in (1, -1, None, False):
            with self.subTest(code=code):
                result = self.invoke(cleanup_returncode=code)
                self.assertEqual(result.states[-2:], ("cleanup", "cleanup-failed"))
                self.assertEqual(result.reason, "cleanup-failed")
                self.assertTrue(result.eligible_for_simulated_cleanup)
                self.assertEqual(tuple(event.argv for event in result.events), (
                    self.INVENTORY_ARGV, self.CREATE_ARGV, self.CLEANUP_ARGV,
                ))
                self.assertEqual(result.events[-1].output, (code,))

    def test_eligibility_cannot_be_transferred_to_another_invocation(self):
        prior = self.invoke()
        result = self.invoke(candidate=prior)
        self.assertEqual(result.reason, "invalid-candidate")
        self.assertFalse(result.eligible_for_simulated_cleanup)
        result = self.invoke(inventory_complete=prior)
        self.assertEqual(result.reason, "invalid-inventory")
        self.assertFalse(result.eligible_for_simulated_cleanup)

    def test_source_has_no_execution_boundary_or_cli(self):
        source = Path(model.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imports = [node for node in ast.walk(tree)
                   if isinstance(node, (ast.Import, ast.ImportFrom))]
        self.assertEqual(len(imports), 1)
        self.assertIsInstance(imports[0], ast.ImportFrom)
        self.assertEqual(imports[0].module, "dataclasses")
        self.assertEqual([(alias.name, alias.asname) for alias in imports[0].names],
                         [("dataclass", None)])
        self.assertNotIn("__main__", source)
        self.assertFalse(any(isinstance(node, (ast.Global, ast.Nonlocal))
                             for node in ast.walk(tree)))
        # A closed call allowlist also rejects dynamic imports, shell/process
        # APIs, injected callbacks and indirect executable backends.
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                if isinstance(node.func, ast.Name):
                    self.assertIn(node.func.id, {
                        "type", "bool", "all", "len", "set", "Event", "Result",
                        "_synthetic_uuid", "dataclass",
                    })
                else:
                    self.assertIsInstance(node.func, ast.Attribute)
                    self.assertEqual(node.func.attr, "startswith")
                    self.assertIsInstance(node.func.value, ast.Name)
                    self.assertEqual(node.func.value.id, "value")


if __name__ == "__main__":
    unittest.main()
