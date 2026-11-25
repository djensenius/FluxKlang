"""Tests for the pure, closed iOS launch outcome record."""

import ast
from pathlib import Path
import unittest

import ios_launch_outcome as outcome
import ios_launch_plan as launch_plan


class IOSLaunchOutcomeTests(unittest.TestCase):
    RUN_UUID = "22222222-2222-4222-8222-222222222222"
    CANDIDATE_UUID = "33333333-3333-4333-8333-333333333333"
    NONCANONICAL_UUID = "aaaaaaaa-2222-4222-8222-222222222222".upper()
    NON_V4_UUID = "22222222-2222-1222-8222-222222222222"
    EXPECTED = ("FluxKlangTests/SuiteA/testOne()", "FluxKlangTests/SuiteB/testTwo()")
    RECEIPT = {"published": 2, "partial_leftovers": 0, "other_entries": 0}
    DISCLAIMERS = {
        "scope": "provider-trusted labeled regression observation only",
        "provenance": "not provenance or custody evidence",
        "production_access": "not production-access proof",
        "qualification": "not #60 qualification",
    }

    def setUp(self):
        self.plan = launch_plan.plan_launch(self.RUN_UUID, self.CANDIDATE_UUID)

    def evaluate(self, **overrides):
        inputs = {
            "plan": self.plan,
            "expected_test_ids": self.EXPECTED,
            "observed_results": tuple((test_id, "passed") for test_id in self.EXPECTED),
            "receipt_observation": dict(self.RECEIPT),
        }
        inputs.update(overrides)
        return outcome.evaluate(**inputs)

    def test_all_expected_passed_with_receipt_is_the_only_zero_exit(self):
        record = self.evaluate()
        self.assertEqual(record, {
            "schema": "fluxklang-ios-launch-outcome",
            "schema_version": 1,
            "run_uuid": self.RUN_UUID,
            "outcome": "passed",
            "exit_code": 0,
            "tests": [{"id": test_id, "status": "passed"} for test_id in self.EXPECTED],
            "test_counts": {"expected": 2, "passed": 2, "failed": 0,
                            "skipped": 0, "absent": 0},
            "receipt": dict(self.RECEIPT, status="present"),
            "disclaimers": self.DISCLAIMERS,
        })
        self.assertNotIn(self.CANDIDATE_UUID, outcome.encode(record).decode("ascii"))

    def test_missing_or_empty_receipt_is_unavailable_and_nonzero(self):
        for observation, counts in (
            (None, dict.fromkeys(outcome.RECEIPT_KEYS)),
            ({"published": 0, "partial_leftovers": 0, "other_entries": 0},
             {"published": 0, "partial_leftovers": 0, "other_entries": 0}),
        ):
            with self.subTest(observation=observation):
                record = self.evaluate(receipt_observation=observation)
                self.assertEqual(record["receipt"], dict(counts, status="unavailable"))
                self.assertEqual((record["outcome"], record["exit_code"]),
                                 ("unavailable", 1))

    def test_irregular_receipt_directory_fails(self):
        for key in ("partial_leftovers", "other_entries"):
            for published in (0, 2):
                with self.subTest(key=key, published=published):
                    record = self.evaluate(receipt_observation=dict(
                        self.RECEIPT, published=published, **{key: 1}))
                    self.assertEqual(record["receipt"]["status"], "irregular")
                    self.assertEqual((record["outcome"], record["exit_code"]),
                                     ("failed", 1))
        record = self.evaluate(
            observed_results=(),
            receipt_observation=dict(self.RECEIPT, partial_leftovers=1))
        self.assertEqual((record["outcome"], record["exit_code"]), ("failed", 1))

    def test_absent_or_skipped_expected_tests_are_incomplete(self):
        for observed, status in (
            ((), "absent"),
            (((self.EXPECTED[0], "passed"),), "absent"),
            (((self.EXPECTED[0], "passed"), (self.EXPECTED[1], "skipped")), "skipped"),
        ):
            with self.subTest(observed=observed):
                record = self.evaluate(observed_results=observed)
                self.assertEqual(record["tests"][1],
                                 {"id": self.EXPECTED[1], "status": status})
                self.assertEqual((record["outcome"], record["exit_code"]),
                                 ("incomplete", 1))
        for observed in ((), ((self.EXPECTED[0], "skipped"),
                              (self.EXPECTED[1], "passed"))):
            record = self.evaluate(observed_results=observed,
                                   receipt_observation=None)
            self.assertEqual((record["outcome"], record["exit_code"]),
                             ("incomplete", 1))
            self.assertEqual(record["receipt"]["status"], "unavailable")

    def test_failed_test_fails_and_takes_precedence(self):
        record = self.evaluate(
            observed_results=((self.EXPECTED[1], "failed"),),
            receipt_observation=None,
        )
        self.assertEqual(record["tests"], [
            {"id": self.EXPECTED[0], "status": "absent"},
            {"id": self.EXPECTED[1], "status": "failed"},
        ])
        self.assertEqual((record["outcome"], record["exit_code"]), ("failed", 1))

    def test_unknown_or_duplicate_observed_ids_are_refused(self):
        for observed in (
            (("FluxKlangTests/Other/testThree()", "passed"),),
            ((self.EXPECTED[0], "passed"), (self.EXPECTED[0], "passed")),
            ((self.EXPECTED[0], "passed"), (self.EXPECTED[0], "failed")),
        ):
            with self.subTest(observed=observed), self.assertRaises(outcome.Refusal):
                self.evaluate(observed_results=observed)

    def test_malformed_inputs_are_refused(self):
        class TextSubclass(str):
            pass

        class PlanSubclass(launch_plan.LaunchPlan):
            pass

        tampered = launch_plan.plan_launch(self.RUN_UUID, self.CANDIDATE_UUID)
        object.__setattr__(tampered, "run_uuid", self.NONCANONICAL_UUID)
        rekeyed = launch_plan.plan_launch(self.RUN_UUID, self.CANDIDATE_UUID)
        object.__setattr__(rekeyed, "run_uuid",
                           "44444444-4444-4444-8444-444444444444")
        cases = [
            {"plan": None},
            {"plan": self.RUN_UUID},
            {"plan": vars(self.plan)},
            {"plan": PlanSubclass(self.RUN_UUID, self.CANDIDATE_UUID,
                                  self.plan.receipt_directory_relative)},
            {"plan": tampered},
            {"plan": rekeyed},
            {"expected_test_ids": ()},
            {"expected_test_ids": list(self.EXPECTED)},
            {"expected_test_ids": frozenset(self.EXPECTED)},
            {"expected_test_ids": self.EXPECTED + self.EXPECTED[:1]},
            {"expected_test_ids": ("x",) * (outcome.MAX_TESTS + 1)},
            {"observed_results": [(self.EXPECTED[0], "passed")]},
            {"observed_results": ([self.EXPECTED[0], "passed"],)},
            {"observed_results": ((self.EXPECTED[0],),)},
            {"observed_results": ((self.EXPECTED[0], "passed", "extra"),)},
            {"observed_results": ((self.EXPECTED[0], "absent"),)},
            {"observed_results": ((self.EXPECTED[0], "PASSED"),)},
            {"observed_results": ((self.EXPECTED[0], True),)},
            {"observed_results": ((self.EXPECTED[0], None),)},
            {"receipt_observation": "not available"},
            {"receipt_observation": (2, 0, 0)},
            {"receipt_observation": {"published": 1}},
            {"receipt_observation": dict(self.RECEIPT, extra=0)},
            {"receipt_observation": dict(self.RECEIPT, published=True)},
            {"receipt_observation": dict(self.RECEIPT, published=-1)},
            {"receipt_observation": dict(self.RECEIPT, published=1.0)},
            {"receipt_observation": dict(
                self.RECEIPT, published=outcome.MAX_RECEIPT_ENTRIES + 1)},
        ]
        for test_id in (
            "", " leading", "trailing ", "a\nb", "a\tb", "a\0b", "a\x7fb",
            "a\u0085b", "a\u2028b", "a\u2029b", "a\udcffb",
            "x" * (outcome.MAX_TEST_ID_LENGTH + 1), "\U0001f3b9" * 100, None,
            b"id", 1,
            TextSubclass("id"),
        ):
            cases.append({"expected_test_ids": (test_id,)})
            cases.append({"observed_results": ((test_id, "passed"),)})
        for overrides in cases:
            with self.subTest(overrides=overrides), self.assertRaises(outcome.Refusal):
                self.evaluate(**overrides)

    def test_largest_accepted_input_still_encodes(self):
        # Each non-BMP character escapes to 12 ASCII bytes, the worst case.
        filler = "\U0001f3b9" * ((outcome.MAX_TEST_ID_JSON_BYTES - 6) // 12)
        expected = tuple(f"{index:04d}{filler}" for index in range(outcome.MAX_TESTS))
        record = self.evaluate(
            expected_test_ids=expected,
            observed_results=tuple((test_id, "passed") for test_id in expected))
        self.assertEqual(outcome.decode(outcome.encode(record)), record)

    def test_disclaimers_are_fixed_and_not_overridable(self):
        with self.assertRaises(TypeError):
            self.evaluate(disclaimers={})
        first = self.evaluate()
        first["disclaimers"]["qualification"] = "qualifies #60"
        del first["disclaimers"]["scope"]
        for record in (self.evaluate(), self.evaluate(receipt_observation=None)):
            self.assertEqual(record["disclaimers"], self.DISCLAIMERS)

    def test_encode_decode_round_trip_is_exact_and_closed(self):
        for overrides in ({}, {"receipt_observation": None},
                          {"observed_results": ((self.EXPECTED[1], "failed"),)}):
            with self.subTest(overrides=overrides):
                record = self.evaluate(**overrides)
                data = outcome.encode(record)
                self.assertEqual(outcome.decode(data), record)

        record = self.evaluate()
        mutations = (
            lambda r: r.update(extra=1),
            lambda r: r.pop("disclaimers"),
            lambda r: r["disclaimers"].update(qualification="qualifies #60"),
            lambda r: r["disclaimers"].update(extra="x"),
            lambda r: r.update(outcome="failed"),
            lambda r: r.update(exit_code=1),
            lambda r: r.update(exit_code=False),
            lambda r: r.update(schema_version=2),
            lambda r: r["tests"][0].update(status="failed"),
            lambda r: r["tests"][0].update(extra=1),
            lambda r: r["test_counts"].update(passed=3),
            lambda r: r["receipt"].update(status="unavailable"),
            lambda r: r["receipt"].update(published=None),
            lambda r: r.update(run_uuid=self.NONCANONICAL_UUID),
            lambda r: r.update(run_uuid=self.NON_V4_UUID),
            lambda r: r.update(tests=[]),
            lambda r: r.update(tests="abc"),
        )
        for mutate in mutations:
            changed = self.evaluate()
            mutate(changed)
            data = outcome._canonical_bytes(changed)
            with self.subTest(changed=changed):
                with self.assertRaises(outcome.Refusal):
                    outcome.decode(data)
                with self.assertRaises(outcome.Refusal):
                    outcome.encode(changed)

        canonical = outcome.encode(record)
        for data in (
            canonical.decode("ascii"),
            canonical[:-1],
            canonical.replace(b",", b", ", 1),
            canonical.replace(b'"exit_code":0', b'"exit_code":0.0'),
            canonical.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1'),
            b"[]\n",
            b"NaN\n",
            b"\xff\n",
        ):
            with self.subTest(data=data), self.assertRaises(outcome.Refusal):
                outcome.decode(data)
        with self.assertRaises(outcome.Refusal):
            outcome.encode(dict(record, tests=tuple(record["tests"])))

    def test_source_has_no_execution_io_or_cli_boundary(self):
        source = Path(outcome.__file__).read_text(encoding="utf-8")
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
        self.assertEqual(imported, {"json", "ios_launch_plan"})
        self.assertNotIn("__main__", source)
        self.assertFalse(any(isinstance(node, (ast.Global, ast.Nonlocal))
                             for node in ast.walk(tree)))
        called = {node.func.id for node in ast.walk(tree)
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        self.assertFalse({"open", "exec", "eval", "compile", "__import__",
                          "getattr", "input", "print"} & called)


if __name__ == "__main__":
    unittest.main()
