"""Focused trace regressions for the G-MEDIA reference checker."""

import copy
import json
import unittest
from pathlib import Path

import check_media_contract as checker


ROOT = Path(__file__).resolve().parent


class MediaContractRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads((ROOT / "media-contract-v1.schema.json").read_text(encoding="utf-8"))

    def example(self, prefix):
        path = next((ROOT / "examples").glob(prefix + "-*.json"))
        return json.loads(path.read_text(encoding="utf-8")), path.name

    def errors(self, doc, name):
        return checker.check_example(doc, name, self.schema)[0]

    def assert_rejected(self, doc, name, message):
        errors = self.errors(doc, name)
        self.assertTrue(any(message in error for error in errors), errors)

    def restart_trace(self):
        doc, name = self.example("01")
        doc["covers"] = ["fixedRateDefault"]
        initial, sample, transport, restart, first = [
            copy.deepcopy(doc["timeline"][i]) for i in (0, 3, 5, 6, 7)
        ]
        initial["hostTicks"] = 0
        sample["reason"] = "wake"
        del sample["nominalRate"]
        restart.update(hostTicks=1000000, previousFrame=0)
        first.update(frame=48, hostTicks=1000000, musicalTicks=0)
        doc["timeline"] = [initial, sample, transport, restart, first]
        for seq, record in enumerate(doc["timeline"], 1):
            record["seq"] = seq
        return doc, name

    def test_restart_drift_stays_bound_to_restart_stamp(self):
        for frame in (49, 50, 97):
            with self.subTest(frame=frame):
                doc, name = self.restart_trace()
                doc["timeline"].append({
                    "seq": 6, "kind": "anchor", "sampleClock": "smp.main",
                    "generation": 2, "frame": frame, "hostTicks": 1000500
                })
                if frame == 49:
                    self.assertEqual(self.errors(doc, name), [])
                else:
                    self.assert_rejected(doc, name, "their clockRestart stamp")

    def test_restart_anchors_still_advance_after_first_observation(self):
        for frame, host in ((24, 1001000), (23, 1001000), (25, 1000500), (25, 1000250)):
            with self.subTest(frame=frame, host=host):
                doc, name = self.restart_trace()
                doc["timeline"][-1].update(frame=24, hostTicks=1000500)
                doc["timeline"].append({
                    "seq": 6, "kind": "anchor", "sampleClock": "smp.main",
                    "generation": 2, "frame": frame, "hostTicks": host
                })
                self.assert_rejected(doc, name, "anchors advance")

    def test_foreign_transport_cannot_discharge_primary_restart(self):
        doc, name = self.example("01")
        doc["initialGenerations"]["transport/mus.other"] = 1
        doc["timeline"][5]["counter"] = "transport/mus.other"
        doc["timeline"][7]["transport"] = 1
        doc["timeline"][11]["requires"]["transport/mus.main"] = 1

        self.assert_rejected(doc, name, "must name the declared musical clock")

    def test_foreign_musical_map_is_rejected_even_without_a_bump(self):
        doc, name = self.example("04")
        doc["initialGenerations"]["musicalMap/mus.other"] = 1

        self.assert_rejected(doc, name, "must name the declared musical clock")

    def test_stale_secondary_dependency_cannot_hide_primary_progress(self):
        doc, name = self.example("04")
        doc["clocks"]["sample"].append({"clockId": "smp.secondary", "nominalRate": 48000})
        doc["initialGenerations"]["sampleClock/smp.secondary"] = 2
        doc["timeline"][1]["requires"]["sampleClock/smp.secondary"] = 1
        doc["timeline"][1]["horizonFrame"] = 280000
        doc["timeline"][2] = {
            "seq": 3, "kind": "outcome", "triggerId": "trg.1",
            "result": "rejectedStale", "reason": "sampleClock"
        }

        self.assert_rejected(doc, name, "expected fired assignedFrame=288000 frame=288000")
        doc["timeline"][6].update(assignedFrame=288000, frame=288000)
        self.assertEqual(self.errors(doc, name), [])

    def test_fallback_stays_in_loop_but_can_use_the_loop_end(self):
        doc, name = self.example("01")
        doc["covers"] = ["fixedRateDefault"]
        doc["clocks"]["musical"]["loop"] = {"startTicks": 1000, "endTicks": 2000}
        doc["actions"][0]["quantize"]["gridTicks"] = 15360
        anchor, trigger = copy.deepcopy(doc["timeline"][:2])
        anchor["musicalTicks"] = 1000
        trigger.update(
            originHostTicks=2400500000,
            horizonFrame=1256,
            target={"timeBase": "sample", "atFrame": 0}
        )
        doc["timeline"] = [
            anchor,
            trigger,
            {"seq": 3, "kind": "outcome", "triggerId": "trg.1", "result": "fired",
             "assignedFrame": 24001, "frame": 24001, "musicalMap": 1}
        ]

        self.assert_rejected(doc, name, "nextBoundary target must resolve inside the active loop")
        doc["actions"][0]["quantize"]["gridTicks"] = 2000
        doc["timeline"][2].update(assignedFrame=1563, frame=1563)
        self.assertEqual(self.errors(doc, name), [])


if __name__ == "__main__":
    unittest.main()
