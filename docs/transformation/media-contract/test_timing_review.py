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


def out_of_range_records(kind):
    if kind == "firstAnchor":
        return [anchor(0, 2**63)]
    records = unrepresentable_records(kind)
    records[0]["musicalTicks"] = 2**63 - 1
    if kind == "clockRestart":
        records[-1]["previousFrame"] = 2
    else:
        records[-1]["musicalTicks"] = 2**63
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
        # A musical target is not a nextBoundary resolution: the origin itself lies past the only representable wrap.
        self.assertIn("a zero-period loop has no pass after its wrap frame", errors[0])
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

    def test_out_of_range_records_preserve_valid_timing_state(self):
        for kind in ("firstAnchor", "anchor", "midiCapture", "clockRestart"):
            with self.subTest(kind=kind):
                doc = document(out_of_range_records(kind), loop=None, grid=1)
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                self.assertTrue(any("Int64 tick range" in e for e in trace.errors), trace.errors)
                first = doc["timeline"][0]
                self.assertEqual(trace.anchor, {} if kind == "firstAnchor" else {"smp.main": first})
                self.assertEqual(trace.first_anchor, {} if kind == "firstAnchor" else {("smp.main", 1): first})
                self.assertEqual(trace.hist, [] if kind in ("firstAnchor", "clockRestart") else [first])
                self.assertEqual(trace.horizon, float("-inf") if kind in ("firstAnchor", "clockRestart") else 0)
                self.assertEqual(trace.discs, [])
                self.assertEqual(trace.restarts, {})
                self.assertEqual(trace.captures, [])
                self.assertEqual(trace.protocols, {})
                self.assertIsNone(trace.resume)
                self.assertEqual(trace.pending_restart, {"smp.main"} if kind == "clockRestart" else set())

    def test_out_of_range_records_continue_independent_outcomes(self):
        for kind in ("firstAnchor", "anchor", "midiCapture", "clockRestart"):
            for target in (dict(timeBase="asap"), dict(timeBase="sample", atFrame=4)):
                with self.subTest(kind=kind, target=target):
                    records = out_of_range_records(kind)
                    cue = trigger(2, 2, target)
                    if kind == "clockRestart":
                        records += [dict(records[-1], previousFrame=0),
                                    dict(kind="anchor", sampleClock="smp.main", generation=2, frame=0, hostTicks=1000)]
                        cue["requires"].update({"sampleClock/smp.main": 2, "transport/mus.main": 2})
                    else:
                        records.append(dict(kind="anchor", sampleClock="smp.main", generation=1,
                                            frame=2, hostTicks=1000))
                    errors = self.check(document(records + [cue, outcome(99, 99)], loop=None, grid=1,
                                                 late=dict(policy="fireLate", maxLatenessMs=100)))
                    self.assertTrue(any("Int64 tick range" in e for e in errors), errors)
                    self.assertFalse(any("replay aborted" in e for e in errors), errors)
                    assigned = 2 if target["timeBase"] == "asap" else 4
                    self.assertTrue(any(f"expected fired assignedFrame={assigned}" in e for e in errors), errors)

    def test_legal_maximum_anchor_capture_and_restart_ticks_remain_valid(self):
        for kind in ("anchor", "midiCapture", "clockRestart"):
            with self.subTest(kind=kind):
                records = out_of_range_records(kind)
                if kind == "clockRestart":
                    records[-1]["previousFrame"] = 0
                    records.append(dict(anchor(0, 2**63 - 1), generation=2, transport=2, hostTicks=1000))
                else:
                    records[-1]["musicalTicks"] = 2**63 - 1
                    if kind == "midiCapture":
                        records[-1].update(frame=0, hostTicks=0)
                self.assertEqual(self.check(document(records, loop=None, grid=1)), [])

    def test_retroactive_search_uses_latest_projection_without_walking_grid_ticks(self):
        for drift in (-1, 1):
            for count in (1, 40):
                for retro in (0, 1):
                    with self.subTest(drift=drift, count=count, retro=retro):
                        records = [anchor(0, 0)] + [anchor(index * 1000, index * (640 + drift))
                                                  for index in range(1, count + 1)]
                        assigned = 500 if retro else 502  # the forward choice never trails the origin
                        records += [trigger(501, count * 1000, dict(timeBase="musical", gridTicks=1)),
                                    outcome(assigned, count * 1000, "firedLate")]
                        doc = document(records, loop=None, grid=1,
                                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=retro))
                        self.assertEqual(self.check(doc), [])

    def test_retroactivity_uses_projected_time_not_historical_tick_equality(self):
        for ticks in (639, 640, 641):
            for retro in (0, 1):
                with self.subTest(ticks=ticks, retro=retro):
                    grid = 1 if ticks == 639 else 2
                    # An exact-frame boundary is eligible at zero tolerance; a forward one never trails the origin.
                    assigned = (498 if retro else 502) if ticks == 641 else 500
                    joined = dict(outcome(assigned, 1000, "joined"), startOffsetFrames=1000 - assigned)
                    records = [anchor(0, 0), anchor(1000, ticks),
                               trigger(500, 1000, dict(timeBase="musical", gridTicks=grid)), joined]
                    doc = document(records, loop=None, grid=grid,
                                   late=dict(policy="joinInProgress", maxLatenessMs=1000, retroactiveMs=retro))
                    is_retro = bool(retro and ticks == 641)
                    if is_retro:
                        doc["covers"].append("retroactiveCue")
                    self.assertEqual(self.check(doc), [])
                    trace = checker.Trace(doc, "11-review-timing.json")
                    trace.run()
                    self.assertEqual(trace.triggers["trg.review"]["expect"]["retro"], is_retro)

    def test_retroactive_search_compares_end_alias_and_interior_projections(self):
        for end, at_wrap, count, host, ticks, assigned in [(3, 5, 1, 2250, 3, 4), (100, 156, 99, 77500, 99, 155)]:
            with self.subTest(end=end):
                records = [anchor(0, 0)] + wrap(at_wrap, 0, 1)
                records += [anchor(at_wrap + tick, tick, 1) for tick in range(1, count + 1)]
                cue = trigger(0, at_wrap + count, dict(timeBase="musical", gridTicks=1))
                cue["originHostTicks"] = host
                records += [cue, outcome(assigned, at_wrap + count, "firedLate")]
                doc = document(records, loop=(0, end), grid=1,
                               late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=1))
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, ticks))

    def test_retroactive_search_compares_every_eligible_earlier_pass(self):
        cases = [(1, None, 65, 10, 1000, 1563, 1567), (2, 1280000, 26, 11, 780, 3120, 3132)]
        for passes, tempo, step, count, ticks, assigned, forward in cases:
            for retro in (0, 1):
                with self.subTest(passes=passes, retro=retro):
                    origin, revision = passes * 1564, 2 if tempo else 1
                    records = [anchor(0, 0)]
                    for iteration in range(1, passes + 1):
                        records += wrap(iteration * 1564, 0, iteration)
                    if tempo:
                        records.append(dict(kind="generation", counter="musicalMap/mus.main",
                                            **{"from": 1, "to": 2}, reason="tempoEdit",
                                            musicalMap=[dict(atTicks=0, microsPerQuarter=tempo)]))
                    records += [anchor(origin + 100 * index, step * index, passes) for index in range(1, count + 1)]
                    horizon = origin + count * 100
                    records += [trigger(origin, horizon, dict(timeBase="musical", gridTicks=4)),
                                outcome(assigned if retro else forward, horizon, "firedLate", revision=revision)]
                    doc = document(records, loop=(0, 1001), grid=4,
                                   late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=retro))
                    self.assertEqual(self.check(doc), [])
                    trace = checker.Trace(doc, "11-review-timing.json")
                    trace.run()
                    want = (0, ticks) if retro else (passes, 12)
                    self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], want)

    def test_retroactive_search_compares_overlapping_virtual_passes_without_walking_them(self):
        for start, end, grid, fraction, back, ticks in [(0, 7, 1, 75, 1, 6), (1, 8, 7, 25, 2, 7)]:
            for iteration in (2, 10**12):
                for retro in (0, 1):
                    with self.subTest(start=start, iteration=iteration, retro=retro):
                        cue = trigger(0, iteration + 2, dict(timeBase="musical", gridTicks=grid))
                        cue["originHostTicks"] = iteration * 500 + fraction
                        assigned = iteration - back + 1 if retro else iteration + back - 1
                        records = [anchor(0, start), cue, outcome(assigned, iteration + 2, "firedLate")]
                        doc = document(records, loop=(start, end), grid=grid, tempo=60000,
                                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=retro))
                        self.assertEqual(self.check(doc), [])
                        trace = checker.Trace(doc, "11-review-timing.json")
                        trace.run()
                        expected = (iteration - back, ticks) if retro else (iteration, grid)
                        self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], expected)

    def test_projected_predecessor_skips_unobserved_virtual_passes(self):
        records = [anchor(0, 0), anchor(750000, 480000),
                   dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                        musicalMap=[dict(atTicks=0, microsPerQuarter=60000)]),
                   trigger(720000, 750000, dict(timeBase="musical", gridTicks=1)),
                   outcome(720000, 750000, "firedLate", revision=2)]
        doc = document(records, loop=(0, 500000), grid=1,
                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=1))
        self.assertEqual(self.check(doc), [])
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 320000))

    def test_retroactive_search_includes_virtual_passes_in_historical_gaps(self):
        # Origin inside the gap, and origin in a later recorded pass whose closest boundary is the gap's end alias.
        for start, grid, wrap_frame, host, retro_occ, retro_frame, forward, forward_frame in [
                (0, 1, 15, 5750, (2, 1), 11, (2, 2), 12), (1, 5, 12, 6750, (2, 5), 12, (3, 5), 16)]:
            for retro in (0, 1):
                with self.subTest(start=start, retro=retro):
                    cue = trigger(0, 16, dict(timeBase="musical", gridTicks=grid))
                    cue["originHostTicks"] = host
                    assigned = retro_frame if retro else forward_frame
                    records = [anchor(0, start)] + wrap(wrap_frame, start, 3)
                    records += [cue, outcome(assigned, 16, "firedLate" if assigned < 16 else "fired")]
                    doc = document(records, loop=(start, 5), grid=grid, tempo=320000,
                                   late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=retro))
                    self.assertEqual(self.check(doc), [])
                    trace = checker.Trace(doc, "11-review-timing.json")
                    trace.run()
                    self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], retro_occ if retro else forward)

    def test_gap_end_alias_projects_through_the_following_recorded_pass(self):
        # After a tempo edit, pass 1's virtual start (frame 12) follows the origin, but its end aliases pass 2's anchor.
        for retro in (0, 1):
            with self.subTest(retro=retro):
                records = [anchor(0, 1)] + wrap(8, 1, 2) + wrap(20, 1, 5)
                records += [dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2},
                                 reason="tempoEdit", musicalMap=[dict(atTicks=0, microsPerQuarter=160000)]),
                            trigger(8, 20, dict(timeBase="musical", gridTicks=5)),
                            outcome(8, 20, "firedLate", revision=2)]
                doc = document(records, loop=(1, 5), grid=5, tempo=320000,
                               late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=retro))
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                expect = trace.triggers["trg.review"]["expect"]
                self.assertEqual((expect["occ"], expect["retro"]), ((1, 5), False))

    def test_retroactive_search_indexes_history_once(self):
        class CountingHistory(list):
            scans = 0

            def __iter__(self):
                CountingHistory.scans += 1
                return super().__iter__()

        records = [anchor(0, 0)]
        for iteration in range(1, 41):
            records += wrap(iteration * 5, 0, iteration)
        records += [trigger(201, 201, dict(timeBase="musical", gridTicks=5)), outcome(205, 205)]
        doc = document(records, loop=(0, 5), grid=5, tempo=320000,
                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        trace.hist = CountingHistory(trace.hist)
        self.assertEqual(trace.projected_previous(40, 5, Fraction(201)), (40, 0))
        self.assertLessEqual(CountingHistory.scans, 1)

    def test_zero_tolerance_keeps_exact_frame_boundaries(self):
        # An exact-frame predecessor is chosen; a strictly earlier one (tick 319 at frame 500) is not.
        for later, origin, ticks, assigned in [(641, 500, 321, 500), (639, 501, 320, 502)]:
            with self.subTest(later=later):
                records = [anchor(0, 0), anchor(1000, later),
                           trigger(origin, 1000, dict(timeBase="musical", gridTicks=1)),
                           outcome(assigned, 1000, "firedLate")]
                doc = document(records, loop=None, grid=1,
                               late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                expect = trace.triggers["trg.review"]["expect"]
                self.assertEqual((expect["occ"], expect["retro"]), ((0, ticks), False))

    def test_end_only_grid_keeps_previous_pass_with_a_nonzero_loop_start(self):
        for retro in (0, 1):
            with self.subTest(retro=retro):
                cue = trigger(0, 4, dict(timeBase="musical", gridTicks=2))
                cue["originHostTicks"] = 1900
                records = [anchor(0, 1)] + wrap(2, 1, 1) + wrap(4, 1, 2)
                records += [cue, outcome(2 if retro else 4, 4, "firedLate" if retro else "fired")]
                doc = document(records, loop=(1, 2), grid=2,
                               late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=retro))
                self.assertEqual(self.check(doc), [])

    def test_origin_before_the_first_anchor_uses_the_first_nonnegative_boundary(self):
        for loop in (None, (0, 3)):
            for origin in (0, 99, 100):
                with self.subTest(loop=loop, origin=origin):
                    cue = trigger(origin, 100, dict(timeBase="musical", gridTicks=2))
                    doc = document([anchor(100, 0), cue, outcome(100, 100)], loop=loop, grid=2)
                    self.assertEqual(self.check(doc), [])
        cue = trigger(0, 100, dict(timeBase="musical", gridTicks=2))
        errors = self.check(document([anchor(100, 4), cue, outcome(100, 100)], loop=(4, 12), grid=2))
        self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in errors), errors)
        self.assertFalse(any("Int64 tick range" in e for e in errors), errors)

    def test_forward_choice_is_the_first_boundary_projected_at_or_after_the_origin(self):
        # A re-anchor drifted either way moves the projected grid; outside the window the choice never trails the
        # origin and never skips a boundary projected between the origin and itself.
        for later, origin, grid, ticks, assigned in [(641, 500, 2, 322, 502), (641, 501, 1, 322, 502),
                                                     (639, 501, 2, 320, 502), (640, 499, 1, 320, 500)]:
            with self.subTest(later=later, origin=origin):
                records = [anchor(0, 0), anchor(1000, later),
                           trigger(origin, 1000, dict(timeBase="musical", gridTicks=grid)),
                           dict(outcome(assigned, 1000, "joined"), startOffsetFrames=1000 - assigned)]
                doc = document(records, loop=None, grid=grid,
                               late=dict(policy="joinInProgress", maxLatenessMs=1000, retroactiveMs=0))
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                expect = trace.triggers["trg.review"]["expect"]
                self.assertEqual((expect["occ"], expect["retro"]), ((0, ticks), False))
                self.assertGreaterEqual(trace.frame_of(expect["occ"]), origin)

    def test_forward_choice_keeps_the_earlier_alias_across_a_tempo_edited_gap(self):
        # A slower map projects the unrecorded gap before the origin; pass 2's end alias and unrecorded pass 3's
        # start share the closest frame, and the earlier occurrence wins rather than the later pass's start.
        records = [anchor(0, 0)] + wrap(21, 0, 7) + [
            dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                 musicalMap=[dict(atTicks=0, microsPerQuarter=480000)]),
            trigger(1, 21, dict(timeBase="musical", gridTicks=1)),
            outcome(1, 21, "firedLate", revision=2)]
        doc = document(records, loop=(0, 3), grid=1, tempo=320000,
                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
        self.assertEqual(self.check(doc), [])
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        expect = trace.triggers["trg.review"]["expect"]
        self.assertEqual((expect["occ"], expect["retro"]), ((2, 3), False))
        self.assertEqual(trace.frame_of((2, 3)), trace.frame_of((3, 0)))

    def test_forward_choice_keeps_a_pass_begun_inside_the_loop_at_or_after_its_start(self):
        # Through pass 0's drifted re-anchor or an edited map the origin projects before the loop start; a pass that
        # began inside the loop still resolves its loop start rather than a pre-loop tick.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=400000)])
        for later, origin, edited in [(644, 0, False), (645, 0, True), (645, 100, True), (645, 150, True)]:
            with self.subTest(later=later, origin=origin):
                records = [anchor(0, 5), anchor(1000, later)] + ([edit] if edited else [])
                doc = document(records + [trigger(origin, 1000, dict(timeBase="musical", gridTicks=1))], loop=(5, 2000),
                               grid=1, late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                expect = trace.triggers["trg.review"]["expect"]
                self.assertEqual((expect["occ"], expect["retro"]), ((0, 5), False))
                self.assertGreaterEqual(trace.frame_of(expect["occ"]), origin)
                self.assertFalse(any("inside the active loop" in e for e in trace.errors), trace.errors)

    def test_forward_choice_floors_pass_zero_only_while_it_is_inside_the_loop(self):
        # Pass 0 began before the loop but, through the anchor in effect, had entered it by the origin; later anchors
        # drifted back project that origin before the loop start, and its loop start still wins.
        cue = trigger(0, 2000, dict(timeBase="musical", gridTicks=1))
        cue["originHostTicks"] = 4300
        doc = document([anchor(0, 0), anchor(1000, 639), anchor(2000, 1278), cue], loop=(5, 4000), grid=1,
                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 5))
        self.assertFalse(any("inside the active loop" in e for e in trace.errors), trace.errors)
        # A pass 0 begun past the loop end never enters the loop: an edited map's earlier projection stays rejected.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=250000)])
        records = [anchor(0, 50), anchor(1000, 690), edit, trigger(0, 1000, dict(timeBase="musical", gridTicks=1))]
        errors = self.check(document(records, loop=(5, 10), grid=1,
                                     late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0)))
        self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in errors), errors)

    @staticmethod
    def gap_edit_records(origin, horizon=21):
        # Pass 0 is anchored, passes 1-6 are an unrecorded gap before pass 7's wrap. The faster edited map shrinks the
        # rounded period to one frame, so the gap projects from pass 7 at frames 15..20 while at() extrapolates pass 0.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=106667)])
        return [anchor(0, 0)] + wrap(21, 0, 7) + [edit, trigger(origin, horizon, dict(timeBase="musical", gridTicks=3))]

    def test_origin_pass_is_located_where_the_gap_projects_after_a_tempo_edit(self):
        for origin, occ, assigned in [(10, (0, 3), 15), (14, (0, 3), 15), (16, (2, 0), 16)]:
            with self.subTest(origin=origin):
                records = self.gap_edit_records(origin) + [outcome(assigned, 21, "firedLate", revision=2)]
                doc = document(records, loop=(0, 3), grid=3, tempo=320000,
                               late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                expect = trace.triggers["trg.review"]["expect"]
                self.assertEqual((expect["occ"], expect["retro"]), (occ, False))
                self.assertEqual(trace.frame_of(occ), assigned)

    def test_forward_choice_is_monotonic_in_the_origin_across_a_tempo_edited_gap(self):
        previous = None
        for origin in range(26):
            with self.subTest(origin=origin):
                doc = document(self.gap_edit_records(origin, horizon=max(origin, 21)), loop=(0, 3), grid=3,
                               tempo=320000, late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                occ = trace.triggers["trg.review"]["expect"]["occ"]
                frame = trace.frame_of(occ)
                self.assertGreaterEqual(frame, origin)
                if previous is not None:
                    self.assertGreaterEqual((frame, occ), previous)
                previous = frame, occ

    def test_half_frame_period_rounds_up_once_per_wrap_and_locates_the_origin_there(self):
        # A 4.5-frame loop rounds to 5 at every wrap, so pass k starts exactly at 5k and pass k - 1's end aliases it.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=480000)])
        doc = document([anchor(0, 0), edit], loop=(0, 3), grid=1, tempo=320000)
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.errors, [])
        for k in range(1, 7):
            with self.subTest(k=k):
                self.assertEqual(trace.frame_of((k, 0)), 5 * k)
                self.assertEqual(trace.frame_of((k - 1, 3)), 5 * k)
                self.assertEqual(trace.origin_pass(Fraction(5 * k)), k)
                self.assertEqual(trace.origin_pass(Fraction(5 * k) - Fraction(1, 4)), k - 1)
                # Just before the shared frame the earlier occurrence (the end alias) wins the equal forward frame.
                self.assertEqual(trace.projected_next(k - 1, 1, Fraction(5 * k) - Fraction(1, 4)), (k - 1, 3))
                self.assertEqual(trace.projected_previous(k, 1, Fraction(5 * k)), (k, 0))

    def test_retroactive_window_is_inclusive_across_a_tempo_edited_gap(self):
        # At half speed the gap's pass 1 projects from pass 3 at frame 1920. Exactly 1 ms (48 frames) later it is
        # still retroactive; one frame later the forward choice is the gap's next boundary, pass 1's end alias.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=160000)])
        for origin, occ, retro, assigned in [(1968, (1, 0), True, 1920), (1969, (1, 960), False, 2400)]:
            with self.subTest(origin=origin):
                cue = trigger(origin, 2880, dict(timeBase="musical", gridTicks=960))
                records = [anchor(0, 0)] + wrap(2880, 0, 3) + [edit, cue]
                records.append(outcome(assigned, 2880, "firedLate", revision=2))
                doc = document(records, loop=(0, 960), grid=960, tempo=320000,
                               late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=1))
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                expect = trace.triggers["trg.review"]["expect"]
                self.assertEqual((expect["occ"], expect["retro"]), (occ, retro))
                self.assertEqual(origin - trace.frame_of((1, 0)), 48 if retro else 49)

    @staticmethod
    def pre_loop_edit_document(host, outcomes=()):
        # Pass 0 starts before a (5, 8) loop at a slow tempo; a fast edit then has its anchor in effect reach the loop
        # end (tick 8 at frame 1.5) well before the rounded wrap (frame 2), and later passes overrun their 0.5625-frame
        # length by rounding up to 1 frame, so at() can extrapolate ticks past endTicks.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=60000)])
        cue = dict(trigger(0, 40, dict(timeBase="musical", gridTicks=1)), originHostTicks=host)
        return document([anchor(0, 0), anchor(38, 4), edit, cue, *outcomes], loop=(5, 8), grid=1, tempo=3000000,
                        late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))

    def test_pass_zero_is_inside_the_loop_once_its_anchor_in_effect_reaches_the_loop_start(self):
        for host in (500, 750, 875, 1000, 1375, 1875, 2375):
            with self.subTest(host=host):
                doc = self.pre_loop_edit_document(host, [outcome(38, 40, "firedLate", revision=2)])
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 5))
        # Before the anchor in effect reaches the loop start, pass 0's boundary is still pre-loop.
        errors = self.check(self.pre_loop_edit_document(375, [outcome(37, 40, "firedLate", revision=2)]))
        self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in errors), errors)

    def test_forward_choice_is_monotonic_in_the_origin_from_before_the_loop_start(self):
        previous = None
        for host in range(0, 4000, 125):
            with self.subTest(host=host):
                trace = checker.Trace(self.pre_loop_edit_document(host), "11-review-timing.json")
                trace.run()
                occ = trace.triggers["trg.review"]["expect"]["occ"]
                frame = trace.frame_of(occ)
                self.assertGreaterEqual(frame, Fraction(host, 500))
                if previous is not None:
                    self.assertGreaterEqual((frame, occ), previous)
                previous = frame, occ
                inside = [e for e in trace.errors if "inside the active loop" in e]
                self.assertEqual(bool(inside), host < 500, trace.errors)

    def test_pass_zero_floor_series_uses_the_exact_origin(self):
        # Exact origin frames 0.936 and 0.938 straddle tick 5 (frame 0.9375) through the anchor in effect: only the
        # later one is inside the loop. The exact end (1.5) and the rounded wrap (2) stay in pass 0, as do the
        # rounded-phase tails, since pass 1 projects from the latest anchor at frame 39.
        for host in (469, 750, 875, 1000, 1375, 1875, 2375):
            with self.subTest(host=host):
                doc = self.pre_loop_edit_document(host, [outcome(38, 40, "firedLate", revision=2)])
                self.assertEqual(self.check(doc), [])
                trace = checker.Trace(doc, "11-review-timing.json")
                trace.run()
                self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 5))
                self.assertEqual(trace.frame_of((0, 5)), Fraction(611, 16))
        for host in (375, 468):
            with self.subTest(host=host):
                errors = self.check(self.pre_loop_edit_document(host))
                self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in errors), errors)

    def test_zero_period_origin_past_a_superseded_wrap_stays_in_the_latest_anchors_pass(self):
        # A (6, 7) loop under the edited map: from the first anchor the pass enters the loop at frame 1.125 and ends at
        # 1.3125, rounding to a zero-period wrap at frame 1. The pass-0 re-anchor at frame 38 supersedes that wrap:
        # pass 1 projects from it to frame 39, so no unrecorded pass starts before these origins.
        def run(host, outcomes=()):
            doc = self.pre_loop_edit_document(host, outcomes)
            doc["clocks"]["musical"]["loop"] = dict(startTicks=6, endTicks=7)
            trace = checker.Trace(doc, "11-review-timing.json")
            trace.run()
            return trace
        with self.subTest(host=500):
            trace = run(500)
            self.assertEqual(trace.frame_of((1, 6)), 39)
            self.assertEqual(trace.origin_pass(Fraction(1)), 0)
            self.assertTrue(any("v1 resolves musical targets inside the active loop" in e for e in trace.errors),
                            trace.errors)  # tick 16/3 at the origin: pass 0 is still before the loop start
        for host in (625, 750):
            with self.subTest(host=host):
                trace = run(host, [outcome(38, 40, "firedLate", revision=2)])
                self.assertEqual(trace.errors, [])
                self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 6))
                self.assertEqual(trace.frame_of((0, 6)), Fraction(307, 8))

    def test_zero_period_gap_passes_share_the_latest_anchors_first_wrap(self):
        # Pass 0 starts in a (6, 7) loop, pass 2 is recorded at frame 18, and the edited map rounds the period to zero:
        # gap pass 1 projects from pass 2 at frame 18, so an earlier origin stays in pass 0 (at 18 pass 2 is in effect
        # and its first wrap, pass 3, holds the origin).
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=60000)])
        cue = dict(trigger(0, 19, dict(timeBase="musical", gridTicks=1)), originHostTicks=125)
        doc = document([anchor(0, 6), *wrap(18, 6, 2), edit, cue], loop=(6, 7), grid=1, tempo=3000000,
                       late=dict(policy="fireLate", maxLatenessMs=1000, retroactiveMs=0))
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.frame_of((1, 6)), 18)
        self.assertEqual([trace.origin_pass(Fraction(f, 4)) for f in (1, 71, 72)], [0, 0, 3])
        self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 7))  # pass 0's end alias, at frame 18

    def test_pass_zero_floor_holds_between_the_exact_end_and_the_rounded_wrap(self):
        # Origin 4.8 is past pass 0's exact loop end (4.6875) through the anchor in effect but before its rounded wrap
        # (5); pass 0 stays inside the loop, so its loop start projects through its latest anchor at frame 135/16.
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=500000)])
        records = [anchor(0, 0), *[anchor(frame, 2) for frame in range(5, 11)], *wrap(12, 1, 1), edit,
                   dict(trigger(0, 12, dict(timeBase="musical", gridTicks=1)), originHostTicks=2400),
                   outcome(8, 12, "firedLate", revision=2)]
        doc = document(records, loop=(1, 3), grid=1, tempo=640000,
                       late=dict(policy="fireLate", maxLatenessMs=100, retroactiveMs=0))
        self.assertEqual(self.check(doc), [])
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertEqual(trace.triggers["trg.review"]["expect"]["occ"], (0, 1))
        self.assertEqual(trace.frame_of((0, 1)), Fraction(135, 16))

    def test_clock_restart_previous_frame_cannot_precede_the_old_generations_latest_anchor(self):
        def records(previous):
            return [anchor(0, 0), anchor(2400, 1536),
                    dict(kind="generation", counter="sampleClock/smp.main", **{"from": 1, "to": 2},
                         reason="deviceRestart"),
                    dict(kind="generation", counter="transport/mus.main", **{"from": 1, "to": 2},
                         reason="clockRestart"),
                    dict(kind="discontinuity", type="clockRestart", sampleClock="smp.main", generation=2, frame=0,
                         hostTicks=1200000, previousFrame=previous)]
        self.assertEqual(self.check(document(records(2400), loop=None)), [])
        errors = self.check(document(records(2399), loop=None))
        self.assertTrue(any("previousFrame cannot precede the old generation's latest anchor" in e for e in errors),
                        errors)

    def test_back_to_back_restarts_compare_previous_frame_only_with_the_ending_generation(self):
        # Generation 2 has no anchor, so the second restart's previousFrame (in generation 2's frames) is unrelated
        # to generation 1's latest anchor at frame 1000.
        def bump(to, host, previous):
            return [dict(kind="generation", counter="sampleClock/smp.main", **{"from": to - 1, "to": to},
                         reason="deviceRestart"),
                    dict(kind="generation", counter="transport/mus.main", **{"from": to - 1, "to": to},
                         reason="clockRestart"),
                    dict(kind="discontinuity", type="clockRestart", sampleClock="smp.main", generation=to, frame=0,
                         hostTicks=host, previousFrame=previous)]
        records = [anchor(0, 0), anchor(1000, 640)] + bump(2, 600000, 1000) + bump(3, 700000, 50)
        self.assertEqual(self.check(document(records, loop=None, grid=1)), [])

    def test_stale_loop_wrap_before_the_current_musical_anchor_is_rejected(self):
        # Pass 1 is a gap: anchor(0, 0)'s virtual pass 1 starts at frame 5, so a loopWrap stamped there after the
        # pass-2 wrap at 10 used to match that virtual pass silently.
        records = [anchor(0, 0)] + wrap(10, 0, 2)
        self.assertEqual(self.check(document(records)), [])
        errors = self.check(document(records + wrap(5, 0, 1)[:1]))
        self.assertTrue(any("a stale loopWrap precedes the current musical anchor" in e for e in errors), errors)

    def test_rejected_triggers_still_raise_the_current_horizon(self):
        changes = [("target", dict(timeBase="musical", gridTicks=2**63)), ("actionId", "act.missing"),
                   ("requires", {"sampleClock/smp.main": 1})]
        for field, value in changes:
            with self.subTest(field=field):
                rejected = dict(trigger(0, 100, dict(timeBase="asap")), triggerId="trg.rejected")
                rejected[field] = value
                doc = document([anchor(0, 0), rejected, trigger(0, 0, dict(timeBase="asap")), outcome(100, 100)],
                               loop=None, grid=1, late=dict(policy="fireLate", maxLatenessMs=100))
                errors = self.check(doc)
                self.assertEqual(len(errors), 1, errors)
                self.assertFalse(any("expected" in e for e in errors), errors)
        duplicate = trigger(0, 100, dict(timeBase="asap"))
        doc = document([anchor(0, 0), trigger(0, 0, dict(timeBase="asap")), duplicate, outcome(100, 100)],
                       loop=None, grid=1, late=dict(policy="fireLate", maxLatenessMs=100))
        self.assertEqual([e.split(": ", 1)[1] for e in self.check(doc)],
                         ["trigger ids are unique and reference a declared action"])

    def test_declared_musical_tick_fields_obey_the_int64_domain(self):
        changes = [
            (["clocks", "musical", "loop"], dict(startTicks=2**63, endTicks=2**63 + 1)),
            (["clocks", "musical", "loop"], dict(startTicks=0, endTicks=2**63)),
            (["clocks", "musical", "musicalMap"],
             [dict(atTicks=0, microsPerQuarter=500000), dict(atTicks=2**63, microsPerQuarter=600000)]),
            (["actions", 0, "quantize"], dict(timeBase="musical", gridTicks=2**63)),
            (["actions", 0, "quantize"], dict(timeBase="musical", atTicks=2**63)),
            (["timeline", 1, "target"], dict(timeBase="musical", gridTicks=2**63)),
            (["timeline", 1, "target"], dict(timeBase="musical", atTicks=2**63))
        ]
        for path, value in changes:
            with self.subTest(path=path, value=value):
                doc = document([anchor(0, 0), trigger(0, 0, dict(timeBase="asap")), outcome(0, 0)],
                               loop=None, grid=1, late=dict(policy="fireLate", maxLatenessMs=100))
                target = doc
                for part in path[:-1]:
                    target = target[part]
                target[path[-1]] = value
                errors = self.check(doc)
                self.assertTrue(any("Int64 tick range" in e for e in errors), errors)
                self.assertFalse(any("replay aborted" in e for e in errors), errors)

    def test_invalid_map_tick_does_not_publish_a_revision_or_skip_independent_checks(self):
        edit = dict(kind="generation", counter="musicalMap/mus.main", **{"from": 1, "to": 2}, reason="tempoEdit",
                    musicalMap=[dict(atTicks=0, microsPerQuarter=500000),
                                dict(atTicks=2**63, microsPerQuarter=600000)])
        doc = document([anchor(0, 0), edit, trigger(0, 0, dict(timeBase="asap")), outcome(99, 99)],
                       loop=None, grid=1, late=dict(policy="fireLate", maxLatenessMs=100))
        trace = checker.Trace(doc, "11-review-timing.json")
        trace.run()
        self.assertTrue(any("Int64 tick range" in e for e in trace.errors), trace.errors)
        self.assertEqual(trace.gens["musicalMap/mus.main"], 1)
        self.assertEqual(trace.map, doc["clocks"]["musical"]["musicalMap"])
        self.assertTrue(any("expected fired assignedFrame=0" in e for e in trace.errors), trace.errors)

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
