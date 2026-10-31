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
