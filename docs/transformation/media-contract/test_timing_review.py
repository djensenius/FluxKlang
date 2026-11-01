"""Focused review regressions using the actual schema, replay checker and conversion helpers."""
import copy
import json
import unittest
from fractions import Fraction
from pathlib import Path

import check_media_contract as checker

ROOT = Path(__file__).resolve().parent
SCHEMA = json.loads((ROOT / "media-contract-v1.schema.json").read_text())
BASE = json.loads((ROOT / "examples/03-seek-and-loop.json").read_text())


def anchor(frame, ticks, iteration=0):
    return dict(kind="anchor", sampleClock="smp.main", generation=1, frame=frame, hostTicks=frame * 500,
                transport=1, musicalTicks=ticks, loopIteration=iteration)


def wrap(frame, ticks, iteration):
    return [dict(kind="discontinuity", type="loopWrap", sampleClock="smp.main", generation=1, frame=frame),
            anchor(frame, ticks, iteration)]


def trigger(origin, horizon, target):
    return dict(kind="trigger", triggerId="trg.review", actionId="act.verse", originHostTicks=origin * 500,
                horizonFrame=horizon, target=target,
                requires={"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1})


def outcome(assigned, frame, result="fired", revision=1):
    r = dict(kind="outcome", triggerId="trg.review", result=result, assignedFrame=assigned)
    if result == "dropped":
        r["reason"] = "late"
    else:
        r.update(frame=frame, musicalMap=revision)
    return r


def document(records, loop=(0, 3), grid=2, late=None, tempo=500000):
    doc = copy.deepcopy(BASE)
    doc.update(exampleId="ex.11-review-timing", title="Focused scheduling review regression",
               covers=["fixedRateDefault"], notes=[])
    if loop is None:
        doc["clocks"]["musical"].pop("loop", None)
    else:
        doc["clocks"]["musical"]["loop"] = dict(startTicks=loop[0], endTicks=loop[1])
    doc["clocks"]["musical"]["musicalMap"] = [dict(atTicks=0, microsPerQuarter=tempo)]
    doc["actions"][0]["quantize"] = dict(timeBase="musical", gridTicks=grid)
    doc["actions"][0]["late"] = late or dict(policy="nextBoundary")
    doc["timeline"] = [dict(record, seq=index + 1) for index, record in enumerate(records)]
    return doc


def unrepresentable_records(kind):
    records = [anchor(0, 0)]
    if kind == "anchor":
        records.append(anchor(1, 0))
    elif kind == "loopWrap":
        records.append(dict(kind="discontinuity", type=kind, sampleClock="smp.main", generation=1, frame=1))
    elif kind == "midiCapture":
        capture = copy.deepcopy(next(r for r in BASE["timeline"] if r["kind"] == kind))
        capture.update(frame=1, hostTicks=500, musicalTicks=0)
        records.append(capture)
    else:
        assert kind == "clockRestart"
        records += [
            dict(kind="generation", counter="sampleClock/smp.main", **{"from": 1, "to": 2}, reason="deviceRestart"),
            dict(kind="generation", counter="transport/mus.main", **{"from": 1, "to": 2}, reason="clockRestart"),
            dict(kind="discontinuity", type=kind, sampleClock="smp.main", generation=2, frame=0,
                 hostTicks=1000, previousFrame=1)
        ]
    return records


class TimingReviewTests(unittest.TestCase):
    def check(self, doc):
        return checker.check_example(doc, "11-review-timing.json", SCHEMA)[0]

    def test_retroactive_previous_pass_boundary(self):
        for retro, assigned, result in [(2, 4313, "fired"), (3, 2844, "firedLate"), (5, 2844, "firedLate")]:
            with self.subTest(retro=retro):
                records = [anchor(0, 100)] + wrap(2969, 100, 1)
                records += [trigger(2969, 2969, dict(timeBase="musical", gridTicks=960)),
                            outcome(assigned, 2969 if result == "firedLate" else assigned, result)]
                doc = document(records, loop=(100, 2000), grid=960,
                               late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=retro))
                self.assertEqual(self.check(doc), [])

    def test_retroactive_first_pass_has_no_previous_pass(self):
        doc = document([anchor(0, 100), trigger(0, 0, dict(timeBase="musical", gridTicks=960)),
                        outcome(1344, 1344)], loop=(100, 2000), grid=960,
                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=5))
        self.assertEqual(self.check(doc), [])

    def test_retroactive_loop_end_remains_valid(self):
        records = [anchor(0, 100)] + wrap(2844, 100, 1)
        records += [trigger(2844, 2844, dict(timeBase="musical", gridTicks=960)), outcome(2844, 2844)]
        doc = document(records, loop=(100, 1920), grid=960,
                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=5))
        self.assertEqual(self.check(doc), [])

    def test_retroactive_uses_previous_pass_latest_anchor_and_current_map(self):
        records = [anchor(0, 100), anchor(1500, 1060),
                   {"kind": "generation", "counter": "musicalMap/mus.main", "from": 1, "to": 2,
                    "reason": "tempoEdit", "musicalMap": [{"atTicks": 0, "microsPerQuarter": 1000000}]}]
        records += wrap(4438, 100, 1)
        records += [trigger(4438, 4438, dict(timeBase="musical", gridTicks=960)),
                    outcome(4188, 4438, "firedLate", revision=2)]
        doc = document(records, loop=(100, 2000), grid=960,
                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=6))
        self.assertEqual(self.check(doc), [])

    def test_no_grid_boundary_does_not_invent_one(self):
        records = [anchor(0, 100), trigger(0, 0, dict(timeBase="musical", gridTicks=960)),
                   outcome(0, None, "dropped")]
        doc = document(records, loop=(100, 200), grid=960,
                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=5))
        errors = self.check(doc)
        self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in errors), errors)
        self.assertFalse(any("replay aborted" in e for e in errors), errors)

    def test_virtual_and_explicit_fractional_wraps_agree(self):
        for horizon in (5, 10, 15):
            for explicit in (False, True):
                with self.subTest(horizon=horizon, explicit=explicit):
                    records = [anchor(0, 0), trigger(0, horizon, dict(timeBase="sample", atFrame=0))]
                    if explicit:
                        for iteration in range(1, horizon // 5 + 1):
                            records += wrap(iteration * 5, 0, iteration)
                    records.append(outcome(horizon, horizon))
                    self.assertEqual(self.check(document(records)), [])

    def test_virtual_occurrences_round_each_wrap_without_a_pass_walk(self):
        doc = document([anchor(0, 0)])
        self.assertEqual(self.check(doc), [])
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        for iteration in (1, 2, 3, 2**32 - 1):
            with self.subTest(iteration=iteration):
                self.assertEqual(checker.rnd(trace.frame_of((iteration, 0))), iteration * 5)
                self.assertEqual(checker.rnd(trace.frame_of((iteration, 2))), iteration * 5 + 3)

    def test_zero_rounded_period_reports_no_representable_future(self):
        for loop, grid, horizon in [((0, 1), 1, 1), ((100, 101), 100, 20)]:
            with self.subTest(loop=loop):
                records = [anchor(0, 0), trigger(0, horizon, dict(timeBase="sample", atFrame=-1)),
                           outcome(-1, None, "dropped")]
                errors = self.check(document(records, loop=loop, grid=grid, tempo=60000))
                self.assertEqual(len(errors), 1, errors)
                self.assertIn("nextBoundary cannot resolve before the current horizon", errors[0])
                self.assertNotIn("replay aborted", errors[0])

    def test_zero_rounded_period_keeps_representable_boundaries(self):
        for loop, grid, horizon, assigned in [((0, 1), 1, 0, 0), ((100, 101), 100, 18, 19),
                                             ((100, 101), 100, 19, 19)]:
            with self.subTest(loop=loop, horizon=horizon):
                records = [anchor(0, 0), trigger(0, horizon, dict(timeBase="sample", atFrame=-1)),
                           outcome(assigned, assigned)]
                self.assertEqual(self.check(document(records, loop=loop, grid=grid, tempo=60000)), [])

    def test_zero_rounded_period_origin_search_is_controlled(self):
        records = [anchor(0, 0), trigger(1, 1, dict(timeBase="musical", gridTicks=1)),
                   outcome(0, None, "dropped")]
        errors = self.check(document(records, loop=(0, 1), grid=1, tempo=60000))
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("nextBoundary cannot resolve before the current horizon", errors[0])
        self.assertNotIn("replay aborted", errors[0])

    def test_valid_loop_bounds_are_not_narrowed(self):
        for loop, tempo in [((0, 1), 60000), ((0, 2**63 - 1), 500000)]:
            with self.subTest(loop=loop):
                for target, assigned in [(dict(timeBase="asap"), 1), (dict(timeBase="sample", atFrame=4), 4)]:
                    records = [anchor(0, 0), trigger(0, 1, target),
                               dict(kind="outcome", triggerId="trg.review", result="fired",
                                    assignedFrame=assigned, frame=assigned)]
                    self.assertEqual(self.check(document(records, loop=loop, grid=1, tempo=tempo)), [])

    def test_full_width_grid_boundaries_use_exact_integer_arithmetic(self):
        end = 2**63 - 1
        start = end - 4
        doc = document([anchor(0, 0)], loop=(start, end), grid=2)
        self.assertEqual(self.check(doc), [])
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.boundary((0, start + 1), 2, after=True), (0, start + 3))
        self.assertEqual(trace.boundary((0, end), 2, after=True), (1, start + 1))
        self.assertEqual(trace.previous_boundary((1, start), 2), (0, end - 1))

    def test_unrepresentable_grid_tick_does_not_abort_independent_records(self):
        for fallback in (False, True):
            for independent in (dict(timeBase="asap"), dict(timeBase="sample", atFrame=4)):
                with self.subTest(fallback=fallback, independent=independent):
                    target = dict(timeBase="sample", atFrame=-1) if fallback else dict(timeBase="musical", gridTicks=2)
                    later = dict(trigger(0, 0, independent), triggerId="trg.later")
                    wrong = dict(outcome(99, 99), triggerId="trg.later")
                    doc = document([anchor(0, 2**63 - 1), trigger(0, 0, target), outcome(2, 2), later, wrong],
                                   loop=None, grid=2)
                    errors = self.check(doc)
                    self.assertTrue(any("Int64 tick range" in e for e in errors), errors)
                    self.assertFalse(any("replay aborted" in e for e in errors), errors)
                    assigned = 0 if independent["timeBase"] == "asap" else 4
                    self.assertTrue(any(f"expected fired assignedFrame={assigned}" in e for e in errors), errors)

    def test_maximum_representable_grid_tick_remains_valid(self):
        for grid in (1, 2**63 - 1):
            with self.subTest(grid=grid):
                doc = document([anchor(0, 2**63 - 1), trigger(0, 0, dict(timeBase="musical", gridTicks=grid)),
                                outcome(0, 0)], loop=None, grid=grid)
                self.assertEqual(self.check(doc), [])
        doc = document([anchor(0, 2**63 - 1), trigger(0, 0, dict(timeBase="musical", gridTicks=2)),
                        outcome(-2, 0, "firedLate")], loop=None, grid=2,
                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=1))
        self.assertEqual(self.check(doc), [])
        for grid, assigned in ((1, 0), (2, -2)):
            with self.subTest(grid=grid, origin=2):
                doc = document([anchor(0, 2**63 - 1), trigger(2, 2, dict(timeBase="musical", gridTicks=grid)),
                                outcome(assigned, 2, "firedLate")], loop=None, grid=grid,
                               late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=1))
                self.assertEqual(self.check(doc), [])

    def test_past_end_anchor_can_select_the_last_admissible_retroactive_boundary(self):
        for retro in (0, 35, 36, 50):
            with self.subTest(retro=retro):
                records = [anchor(0, 3000), trigger(0, 0, dict(timeBase="musical", gridTicks=960)),
                           outcome(-1687, 0, "firedLate")]
                doc = document(records, loop=(100, 2000), grid=960,
                               late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=retro))
                errors = self.check(doc)
                if retro >= 36:
                    self.assertEqual(errors, [])
                else:
                    self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in errors),
                                    errors)
                    self.assertFalse(any("replay aborted" in e for e in errors), errors)

    def test_loop_end_does_not_alias_a_pass_anchored_beyond_the_loop(self):
        records = [anchor(0, 3000), trigger(0, 0, dict(timeBase="musical", atTicks=2000)),
                   outcome(checker.rnd(Fraction(-3125, 2)), 0, "firedLate")]
        doc = document(records, loop=(100, 2000), grid=960,
                       late=dict(policy="fireLate", maxLatenessMs=100))
        self.assertEqual(self.check(doc), [])
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.frame_of((0, 2000)), Fraction(-3125, 2))

    def test_fractional_origin_before_rounded_wrap_keeps_distinct_retroactive_choice(self):
        for origin, horizon in [(2400, 5), (4900, 10)]:
            for grid in (1, 2):
                for retro in (0, 1):
                    with self.subTest(origin=origin, grid=grid, retro=retro):
                        cue = trigger(0, horizon, dict(timeBase="musical", gridTicks=grid))
                        cue["originHostTicks"] = origin
                        assigned = horizon - 2 if retro else horizon
                        result = "firedLate" if assigned < horizon else "fired"
                        doc = document([anchor(0, 0), cue, outcome(assigned, horizon, result)], grid=grid,
                                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=retro))
                        self.assertEqual(self.check(doc), [])

    def test_unrepresentable_records_do_not_abort_later_sample_or_asap_checks(self):
        for kind in ("anchor", "loopWrap", "midiCapture", "clockRestart"):
            for target in (dict(timeBase="asap"), dict(timeBase="sample", atFrame=4)):
                with self.subTest(kind=kind, target=target):
                    records = unrepresentable_records(kind)
                    cue = trigger(0, 2, target)
                    if kind == "clockRestart":
                        records += [dict(records[-1], previousFrame=0),
                                    dict(kind="anchor", sampleClock="smp.main", generation=2, frame=0, hostTicks=1000)]
                        cue["originHostTicks"] = 1000
                        cue["requires"].update({"sampleClock/smp.main": 2, "transport/mus.main": 2})
                    records += [cue, outcome(99, 99)]
                    errors = self.check(document(records, loop=(0, 1), grid=1, tempo=60000,
                                                 late=dict(policy="fireLate", maxLatenessMs=100)))
                    self.assertTrue(any("nextBoundary cannot resolve" in e for e in errors), errors)
                    self.assertFalse(any("replay aborted" in e for e in errors), errors)
                    assigned = 2 if target["timeBase"] == "asap" else 4
                    self.assertTrue(any(f"expected fired assignedFrame={assigned}" in e for e in errors), errors)

    def test_unrepresentable_records_do_not_publish_partial_timing_state(self):
        for kind in ("anchor", "loopWrap", "midiCapture", "clockRestart"):
            with self.subTest(kind=kind):
                trace = checker.Trace(document(unrepresentable_records(kind), loop=(0, 1), grid=1, tempo=60000),
                                      "11-review-timing.json")
                trace.run()
                self.assertTrue(any("nextBoundary cannot resolve" in e for e in trace.errors), trace.errors)
                self.assertEqual(trace.anchor["smp.main"]["frame"], 0)
                self.assertEqual(trace.hist, [] if kind == "clockRestart" else [trace.anchor["smp.main"]])
                self.assertEqual(trace.discs, [])
                self.assertEqual(trace.captures, [])
                self.assertEqual(trace.protocols, {})
                self.assertEqual(trace.restarts, {})
                self.assertIsNone(trace.resume)
                self.assertEqual(trace.passes, (0, 0))
                self.assertEqual(trace.pending_restart, {"smp.main"} if kind == "clockRestart" else set())

    def test_export_position_failure_does_not_abort_later_diagnostics(self):
        capture = copy.deepcopy(next(r for r in BASE["timeline"] if r["kind"] == "midiCapture"))
        capture.update(frame=1, hostTicks=125, musicalTicks=0)
        export = copy.deepcopy(next(r for r in BASE["timeline"]
                                    if r["kind"] == "export" and r["format"] != "nativeUmp"))
        export.update(streams=[capture["stream"]], division=15360, lossless=True, losses={})
        records = [anchor(0, 0), capture,
                   dict(kind="generation", counter="sampleClock/smp.main", **{"from": 1, "to": 1},
                        reason="rateChange", nominalRate=44100),
                   export, dict(kind="discontinuity", type="sourceLost", sampleClock="smp.main",
                                generation=1, frame=2, stream="str.missing")]
        doc = document(records, loop=(0, 1), grid=1, tempo=60000)
        doc["clocks"]["sample"][0]["nominalRate"] = 192000
        errors = self.check(doc)
        self.assertTrue(any("advance the current value by exactly one" in e for e in errors), errors)
        self.assertTrue(any("nextBoundary cannot resolve" in e for e in errors), errors)
        self.assertTrue(any("sourceLost names a declared stream" in e for e in errors), errors)
        self.assertFalse(any("replay aborted" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main()
