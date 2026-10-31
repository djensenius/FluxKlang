#!/usr/bin/env python3
"""Check G-MEDIA contract v1 examples: schema, canonical round trip, trace invariants and paired mutations.

Standard library only; no app, hardware, network or plugins. Usage: python3 check_media_contract.py [--write]
"""
import copy
import json
import math
import re
import sys
from collections import Counter
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCHEMA_PATH = ROOT / "media-contract-v1.schema.json"
EXAMPLES = ROOT / "examples"
WIDTH = 120
TPQ = 15360
SUPPORTED = {"$ref", "type", "enum", "const", "properties", "required", "additionalProperties", "propertyNames",
             "items", "minItems", "maxItems", "minimum", "maximum", "minLength", "pattern", "oneOf", "minProperties",
             "maxProperties"}
ANNOTATIONS = {"$schema", "$id", "$defs", "$comment", "title", "description"}
REASONS = {"sampleClock": {"deviceRestart", "rateChange", "configurationChange", "wake"},
           "transport": {"locate", "clockRestart", "transportRestart"}, "musicalMap": {"tempoEdit", "externalTempo"},
           "source": {"sourceLost", "sourceReacquired"}, "context": {"contextChange"}, "cancelScope": {"userCancel"}}
READINESS = {"unprepared": {"preparing"}, "preparing": {"ready", "failed", "unprepared"},
             "ready": {"invalidated", "unprepared"}, "invalidated": {"preparing", "unprepared"},
             "failed": {"preparing", "unprepared"}}
LANES = {"release": 0, "transport": 1, "state": 2, "content": 3}
VALUE_BITS = {0xA: 7, 0xB: 7, 0xD: 7, 0x2: 14, 0x3: 14, 0xE: 14}
UMP_WORDS = {0x0: 1, 0x1: 1, 0x2: 1, 0x3: 2, 0x4: 2, 0x5: 4, 0x6: 1, 0x7: 1, 0x8: 2, 0x9: 2, 0xA: 2, 0xB: 3,
             0xC: 3, 0xD: 4, 0xE: 4, 0xF: 4}
GROUPED = {0x1, 0x2, 0x3, 0x4, 0x5, 0xD}  # M2-104-UM v1.1 §2.1.2: MT 0x0 and 0xF have no Group; reserved MTs undefined


def canon(value, depth_limit, indent=0, prefix=0, tail=0):
    """Deterministic layout: authored key order; a container is inline when it fits WIDTH (with the `tail` characters
    after it) or sits at depth_limit, otherwise its members are packed greedily into rows of at most WIDTH, a
    multi-line member gets its own rows, and the closing bracket ends the last row."""
    flat = json.dumps(value, ensure_ascii=False, separators=(", ", ": "), allow_nan=False)
    if not isinstance(value, (dict, list)) or not value or indent // 2 >= depth_limit \
            or indent + prefix + len(flat) + tail <= WIDTH:
        return flat
    pad, rows, row = " " * (indent + 2), [], ""
    items = list(value.items()) if isinstance(value, dict) else [(None, item) for item in value]
    for n, (key, item) in enumerate(items):
        head = "" if key is None else json.dumps(key, ensure_ascii=False) + ": "
        after = tail + 1 if n == len(items) - 1 else 1  # closing brackets after the last member, else a comma
        part = head + canon(item, depth_limit, indent + 2, len(head), after)
        if row and ("\n" in part + row or len(pad) + len(row) + len(part) + 2 + after > WIDTH):
            rows.append(row + ",")
            row = ""
        row += (", " if row else "") + part
    brackets = "{}" if isinstance(value, dict) else "[]"
    return brackets[0] + "\n" + "\n".join(pad + r for r in rows + [row + brackets[1]])


def load_canonical(path, depth_limit, write, errors):
    """Parse strictly (no duplicate keys, NaN or Infinity) and require the file to equal its canonical rendering."""
    try:
        text = path.read_text(encoding="utf-8")
        doc = json.loads(text, object_pairs_hook=no_duplicates, parse_constant=int)  # int() rejects NaN and Infinity
        rendered = canon(doc, depth_limit) + "\n"
    except ValueError as exc:  # includes UnicodeDecodeError and floats such as 1e999 that overflow to infinity
        errors.append(f"{path.name}: {exc}")
        return None
    if write and rendered != text:
        path.write_text(rendered, encoding="utf-8")
        text = rendered
    if rendered != text or json.loads(rendered) != doc:
        errors.append(f"{path.name}: not canonical; run with --write to normalise")
    return doc


def no_duplicates(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError(f"duplicate keys {sorted(k for k in set(keys) if keys.count(k) > 1)}")
    return dict(pairs)


def check_keywords(node, path="schema"):
    if isinstance(node, dict):
        for key in node:
            if key not in SUPPORTED | ANNOTATIONS:
                raise SystemExit(f"{path}: unsupported schema keyword {key}")
        subs = list(node.get("$defs", {}).items()) + list(node.get("properties", {}).items())
        subs += [(k, node[k]) for k in ("items", "additionalProperties", "propertyNames") if isinstance(node.get(k), dict)]
        subs += [(f"oneOf[{i}]", s) for i, s in enumerate(node.get("oneOf", []))]
        for name, sub in subs:
            check_keywords(sub, f"{path}/{name}")


def same(a, b):
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def type_ok(name, value):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}[name])


def validate(schema, value, defs, path, errors):
    if "$ref" in schema:
        validate(defs[schema["$ref"].split("/")[-1]], value, defs, path, errors)
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(type_ok(n, value) for n in names):
            errors.append(f"{path}: expected {'|'.join(names)}")
            return
    if "const" in schema and not same(value, schema["const"]):
        errors.append(f"{path}: must be {json.dumps(schema['const'])}")
    if "enum" in schema and not any(same(value, e) for e in schema["enum"]):
        errors.append(f"{path}: {json.dumps(value)} not in enum")
    if type_ok("integer", value):
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            errors.append(f"{path}: {value} out of range")
    if isinstance(value, str):
        pattern = re.sub(r"(?<!\\)\$", r"\\Z", schema.get("pattern", ""))  # ECMA-262 `$` never matches before "\n"
        if len(value) < schema.get("minLength", 0) or not re.search(pattern, value):
            errors.append(f"{path}: {json.dumps(value)} violates length/pattern")
    if isinstance(value, list):
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", len(value)):
            errors.append(f"{path}: item count {len(value)} out of range")
        for i, item in enumerate(value):
            if "items" in schema:
                validate(schema["items"], item, defs, f"{path}[{i}]", errors)
    if isinstance(value, dict):
        if not schema.get("minProperties", 0) <= len(value) <= schema.get("maxProperties", len(value)):
            errors.append(f"{path}: property count {len(value)} out of range")
        errors.extend(f"{path}: missing {k}" for k in schema.get("required", []) if k not in value)
        for key, item in value.items():
            if "propertyNames" in schema:
                validate(schema["propertyNames"], key, defs, f"{path}.<{key}>", errors)
            if key in schema.get("properties", {}):
                validate(schema["properties"][key], item, defs, f"{path}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unknown property {key}")
            elif isinstance(schema.get("additionalProperties"), dict):
                validate(schema["additionalProperties"], item, defs, f"{path}.{key}", errors)
    if "oneOf" in schema:
        results = []
        for branch in schema["oneOf"]:
            branch_errors = []
            validate(branch, value, defs, path, branch_errors)
            results.append((defs.get(branch.get("$ref", "").split("/")[-1], branch), branch_errors))
        passing = [e for _, e in results if not e]
        if len(passing) > 1:
            errors.append(f"{path}: matches {len(passing)} oneOf branches")
        elif not passing:
            kind = value.get("kind") if isinstance(value, dict) else None
            match = [e for b, e in results if kind and b.get("properties", {}).get("kind", {}).get("const") == kind]
            errors.extend(match[0] if match else [f"{path}: matches no oneOf branch"])


def rnd(x):
    return math.floor(x + Fraction(1, 2))


def scale_up(value, src_bits, dst_bits):
    """MIDI 2.0 min-center-max upscaling (MIDI Association bit-scaling recommended practice)."""
    if value == 0:
        return 0
    scale_bits = dst_bits - src_bits
    shifted = value << scale_bits
    if value <= 1 << (src_bits - 1):
        return shifted
    repeat_bits = src_bits - 1
    repeat = value & ((1 << repeat_bits) - 1)
    repeat = repeat << (scale_bits - repeat_bits) if scale_bits > repeat_bits else repeat >> (repeat_bits - scale_bits)
    while repeat:
        shifted |= repeat
        repeat >>= repeat_bits
    return shifted


def midi2_losses(words):
    """Loss categories for converting one genuine MIDI 2.0 channel voice message to MIDI 1.0 SMF bytes."""
    opcode, out = (words[0] >> 20) & 0xF, Counter()
    if opcode in (0x8, 0x9):
        velocity = words[1] >> 16
        if opcode == 0x9 and velocity >> 9 == 0:
            out["noteOnVelocityRemapped"] += 1
        if scale_up(velocity >> 9, 7, 16) != velocity:  # independent of the remap: 0x0100 is both
            out["velocityDownscaled"] += 1
        if words[0] & 0xFF:
            out["attributeDropped"] += 1
    elif opcode in VALUE_BITS:
        bits = VALUE_BITS[opcode]
        if scale_up(words[1] >> (32 - bits), bits, 32) != words[1]:
            out["valueDownscaled"] += 1
    elif opcode in (0x0, 0x1, 0x6, 0xF):
        out["perNoteDropped"] += 1
    elif opcode != 0xC:
        out["umpOnlyDropped"] += 1
    return out


class Trace:
    def __init__(self, doc, name):
        clocks, tl = doc["clocks"], doc["timeline"]
        self.doc, self.name, self.errors, self.evidence = doc, name, [], set()
        for key, items in (("streamId", doc.get("streams", [])), ("actionId", doc.get("actions", [])),
                           ("clockId", clocks["sample"]), ("takeId", tl), ("exportId", tl)):
            ids = [x[key] for x in items if key in x]
            if len(set(ids)) < len(ids):
                self.err({}, f"duplicate {key}: declared IDs are unique, never overwritten")
        self.ns_per_tick = Fraction(clocks["host"]["timebaseNumer"], clocks["host"]["timebaseDenom"])
        self.primary = clocks["sample"][0]["clockId"]
        self.gens = dict(doc["initialGenerations"])
        self.rates = {(c["clockId"], self.gens.get(f"sampleClock/{c['clockId']}")): c["nominalRate"]
                      for c in clocks["sample"]}
        self.mus_id = clocks["musical"]["clockId"]
        self.map, self.meter = clocks["musical"]["musicalMap"], clocks["musical"]["meter"]
        self.loop = clocks["musical"].get("loop")
        self.streams = {s["streamId"]: s for s in doc.get("streams", [])}
        self.actions = {a["actionId"]: a for a in doc.get("actions", [])}
        self.state = {k: a["readiness"] for k, a in self.actions.items()}
        self.anchor, self.first_anchor, self.hist = {}, {}, []  # hist: this transport generation's musical anchors
        self.triggers, self.captures, self.discs = {}, [], []
        self.pending_restart, self.last_dispatch, self.stream_seq, self.transport_due = set(), None, {}, False
        self.bumps, self.protocols, self.resume, self.restart_snap = Counter(), {}, None, ([], None)
        self.horizon, self.restarts = -math.inf, {}  # horizon: render progress in this primary sample generation
        self.passes = (0, 0)  # (passes begun by locate or transportRestart, loop passes before the last clock restart)

    @property
    def musical(self):
        return self.hist[-1] if self.hist else None

    def err(self, rec, msg):
        self.errors.append(f"{self.name} seq {rec.get('seq', '-')}: {msg}")

    def rate(self, clock=None, gen=None):  # nominal rate of a clock generation (default: the primary's current one)
        clock = clock or self.primary
        return self.rates.get((clock, gen or self.gens.get(f"sampleClock/{clock}")))

    def host_at(self, anchor, frame):
        rate = self.rate(anchor["sampleClock"], anchor["generation"])
        return anchor["hostTicks"] + (frame - anchor["frame"]) * Fraction(10**9, rate) / self.ns_per_tick

    def frame_at_host(self, ticks):  # through the current primary anchor, else None
        a = self.anchor.get(self.primary)
        if a and a["generation"] == self.gens.get(f"sampleClock/{self.primary}"):
            return a["frame"] + (ticks - a["hostTicks"]) * self.ns_per_tick * self.rate() / 10**9

    def frames_per_tick(self, upq):  # at the musical anchor's generation rate, which a restart has not yet replaced
        return Fraction(upq, TPQ) * self.rate(self.primary, self.musical and self.musical["generation"]) / 10**6

    def segments(self):
        for i, seg in enumerate(self.map):
            end = self.map[i + 1]["atTicks"] if i + 1 < len(self.map) else None
            yield seg["atTicks"], end, self.frames_per_tick(seg["microsPerQuarter"])

    def span(self, t1, t2):
        return sum((max((t2 if end is None else min(end, t2)) - max(start, t1), 0) * fpt
                    for start, end, fpt in self.segments()), Fraction(0))

    def musical_ok(self):
        m = self.musical
        return m is not None and m["generation"] == self.gens.get(f"sampleClock/{self.primary}") \
            and m["transport"] == self.gens.get(f"transport/{self.mus_id}")

    def frame_of_ticks(self, ticks, a=None):
        a = a or self.musical
        t0 = a["musicalTicks"]
        return a["frame"] + (self.span(t0, ticks) if ticks >= t0 else -self.span(ticks, t0))

    def ticks_at_frame(self, frame, a=None):
        """Exact inverse of frame_of_ticks, walking from tick 0 so earlier frames cross earlier tempo segments."""
        f = self.frame_of_ticks(0, a)
        for start, end, fpt in self.segments():
            if end is None or f + (end - start) * fpt > frame:
                return start + (frame - f) / fpt
            f += (end - start) * fpt

    def ahead(self, a, frame=None, k=0):
        """a, or a virtual anchor for an unanchored later loop pass (the k-th after a's, or the one holding `frame`)."""
        lp = self.loop
        if not lp or a["musicalTicks"] > lp["endTicks"]:  # only a pass anchored inside the loop wraps
            return a
        end, length = rnd(self.frame_of_ticks(lp["endTicks"], a)), self.span(lp["startTicks"], lp["endTicks"])
        if frame is not None and frame < end:
            return a
        k = k if frame is None else (frame - end) // length
        it = a.get("loopIteration", 0) + 1 + k
        return {"frame": end + k * length, "musicalTicks": lp["startTicks"], "loopIteration": it}

    def at(self, frame):  # anchor in effect at a frame: latest at or before it (else the first), or a virtual pass
        return self.ahead(([x for x in self.hist if x["frame"] <= frame] or self.hist[:1])[-1], frame)

    def position(self, frame):  # (loopIteration, ticks) at a frame, through the anchor in effect there
        a = self.at(frame)
        return a.get("loopIteration", 0), self.ticks_at_frame(frame, a)

    def frame_of(self, occ):  # (pass, ticks) via that pass's latest anchor or a virtual one; loop end starts the next
        (i, t), lp = occ, self.loop
        if lp and t == lp["endTicks"]:
            i, t = i + 1, lp["startTicks"]
        mine, last = [x for x in self.hist if x.get("loopIteration", 0) == i], self.musical
        return self.frame_of_ticks(t, mine[-1] if mine else self.ahead(last, k=i - last.get("loopIteration", 0) - 1))

    def boundary(self, occ, grid, after=False):  # first grid occurrence at (or after) occ; past loop end, next pass's
        i, b = occ[0], (math.floor(occ[1] / grid) + 1 if after else math.ceil(occ[1] / grid)) * grid
        if self.loop and occ[1] <= self.loop["endTicks"] < b:
            i, b = i + 1, math.ceil(self.loop["startTicks"] / grid) * grid
        return i, b

    def run(self):
        for counter in self.gens:
            kind, identity = counter.split("/", 1)
            if kind in ("transport", "musicalMap") and identity != self.mus_id:
                self.err({}, f"{counter} must name the declared musical clock {self.mus_id}")
                return
        records = self.doc["timeline"]
        if [r["seq"] for r in records] != list(range(1, len(records) + 1)):
            self.err({}, "timeline seq must be 1..n in order")
        for a in self.actions.values():
            self.check_action(a)
        self.check_map({}, self.map)
        if self.loop and self.loop["endTicks"] <= self.loop["startTicks"]:
            self.loop = self.err({}, "a loop needs startTicks < endTicks")
        for i, rec in enumerate(records):
            self.prev = records[i - 1] if i else None
            getattr(self, "on_" + rec["kind"])(rec)
        for tid, info in self.triggers.items():
            if not info.get("done"):
                self.err(info["rec"], f"trigger {tid} has no terminal outcome")
        if self.transport_due:
            self.err({}, "each primary sampleClock bump forces one transport bump with reason clockRestart")
        for key in sorted(self.pending_restart):
            self.err({}, f"{key} changed generation without a clockRestart discontinuity")
        for kind, reason in (("locate", "locate"), ("sourceLost", "sourceLost"), ("sourceRestored", "sourceReacquired")):
            if sum(d["type"] == kind for d in self.discs) != self.bumps[reason]:
                self.err({}, f"{kind} discontinuities must match {reason} generation changes one-to-one")
        for claim in self.doc["covers"]:
            if claim not in self.evidence:
                self.err({}, f"covers {claim} but the timeline has no evidence for it")

    def check_action(self, a):
        media, policy, late = a["media"], a.get("timePolicy"), a["late"]
        allowed = {"audio": {"fixedRate", "timeStretch"}, "midi": {"fixedRate", "tempoFollowing"}}.get(media, {None})
        if policy not in allowed:
            self.err(a, f"{a['actionId']}: {media} actions allow timePolicy {sorted(map(str, allowed))}")
        if media == "audio" and "prefetch" not in a:
            self.err(a, f"{a['actionId']}: audio actions declare a bounded prefetch")
        pf = a.get("prefetch")
        if pf and pf["blockFrames"] * pf["blockCount"] < pf["headFrames"]:
            self.err(a, f"{a['actionId']}: prefetch pool smaller than the declared head")
        retro = late.get("retroactiveMs", 0)
        if retro and (late["policy"] not in ("joinInProgress", "fireLate") or retro > late.get("maxLatenessMs", 0)):
            self.err(a, f"{a['actionId']}: retroactiveMs needs joinInProgress or fireLate and <= maxLatenessMs")
        if late["policy"] == "nextBoundary" and "gridTicks" not in a["quantize"]:
            self.err(a, f"{a['actionId']}: nextBoundary needs a musical grid")
        if a["readiness"] == "ready" and not self.stretch_ok(a):
            self.err(a, f"{a['actionId']}: time-stretch actions need a declared time-stretch adapter")
        if media == "audio" and policy == "fixedRate":
            self.evidence.add("fixedRateDefault")

    def check_map(self, rec, segments):
        ticks = [s["atTicks"] for s in segments]
        if ticks[0] != 0 or ticks != sorted(set(ticks)):
            self.err(rec, "musical map segments start at 0 and strictly increase (initial map and every revision)")

    def stretch_ok(self, action):
        return action.get("timePolicy") != "timeStretch" or self.doc.get("adapterCapabilities", {}).get("timeStretch")

    def stream_is(self, stream_id, media, direction):
        stream = self.streams.get(stream_id)
        return stream is not None and (stream["media"], stream["direction"]) == (media, direction)

    def on_anchor(self, r):
        clock, key = r["sampleClock"], f"sampleClock/{r['sampleClock']}"
        rate = self.rate(clock, r["generation"])
        if rate is None:
            self.err(r, "anchor names an undeclared sample clock generation")
            return
        if r["generation"] != self.gens.get(key):
            self.err(r, "anchor generation is not current")
        if clock in self.pending_restart:
            self.err(r, "new sample generation needs a clockRestart discontinuity before its first anchor")
        prev, first = self.anchor.get(clock), self.first_anchor.setdefault((clock, r["generation"]), r)
        restart = self.restarts.get(clock, {})  # a restarted generation's first anchor is bounded against the restart
        ref = restart if first is r and restart.get("generation") == r["generation"] else first
        if ref is not r:
            span = (r["hostTicks"] - ref["hostTicks"]) * self.ns_per_tick * rate / 10**9
            if min(span, r["frame"] - ref["frame"]) < 0 or abs(r["frame"] - ref["frame"] - span) * 1000 > rate + span \
                    or ref is first and (r["frame"] <= prev["frame"] or r["hostTicks"] <= prev["hostTicks"]):
                self.err(r, "anchors advance and stay within (rate + span)/1000 frames of "
                         + ("their clockRestart stamp" if ref is restart else "their generation's first"))
        self.anchor[clock] = r
        if clock == self.primary and r["generation"] == self.gens.get(key):
            self.horizon = max(self.horizon, r["frame"])
        if ("musicalTicks" in r) != ("transport" in r):
            self.err(r, "musical anchors carry both transport and musicalTicks")
        if "musicalTicks" not in r or clock != self.primary:
            return
        if r["transport"] != self.gens.get(f"transport/{self.mus_id}"):
            self.err(r, "anchor transport generation is not current")
        m, it, wrap = self.musical, r.get("loopIteration", 0), self.prev or {}
        if (not m or m["transport"] != r["transport"]) and it:
            self.err(r, "a new transport generation (start, locate or restart) begins at loopIteration 0")
        if self.resume is not None and r["musicalTicks"] != self.resume:
            self.err(r, f"after a clock restart the transport resumes at the last rendered tick {self.resume}")
        self.resume = None
        if m and m["transport"] == r["transport"]:
            if m["generation"] != r["generation"]:
                self.err(r, "a sample clock restart must re-anchor with a new transport generation")
            elif self.position(r["frame"])[0] != it or abs(self.position(r["frame"])[1] - r["musicalTicks"]) > 1:
                self.err(r, "musical position jumped without locate or loop wrap (one loopIteration per wrap)")
            elif it != m.get("loopIteration", 0):
                if (wrap.get("type"), wrap.get("frame")) != ("loopWrap", r["frame"]) \
                        or r["musicalTicks"] != self.loop["startTicks"]:
                    self.err(r, "loop iteration must follow a loopWrap at its frame and restart at loop start")
                else:
                    self.evidence.add("loop")
        self.hist = (self.hist if m and m["transport"] == r["transport"] else []) + [r]

    def on_generation(self, r):
        counter, kind = r["counter"], r["counter"].split("/")[0]
        if counter not in self.gens:
            self.err(r, f"{counter} is not declared in initialGenerations")
            return
        if r["from"] != self.gens[counter] or r["to"] != r["from"] + 1:
            self.err(r, "generation must advance the current value by exactly one")
        if r["reason"] not in REASONS[kind]:
            self.err(r, f"reason {r['reason']} does not apply to {kind}")
        if ("musicalMap" in r) != (kind == "musicalMap") or ("meter" in r and kind != "musicalMap"):
            self.err(r, "only musicalMap generations carry a musicalMap payload (required) and a meter (optional)")
            return
        if ("nominalRate" in r and kind != "sampleClock") or (r["reason"] == "rateChange" and "nominalRate" not in r):
            self.err(r, "nominalRate belongs to sampleClock generations and is required on rateChange")
        if kind == "sampleClock":
            clock = counter.split("/", 1)[1]
            if clock in self.pending_restart or clock == self.primary and self.transport_due:
                self.err(r, "each sampleClock change completes its clockRestart (and transport bump) before the next")
                return
            self.rates[(clock, r["to"])] = r.get("nominalRate", self.rate(clock))
            self.pending_restart.add(clock)
            if clock == self.primary:  # frames restart with the generation; the resume tick uses the old anchor and map
                self.last_dispatch, self.restart_snap, self.horizon = None, (self.hist, self.map), -math.inf
                self.transport_due = f"transport/{self.mus_id}" in self.gens
        self.gens[counter] = r["to"]
        self.bumps[r["reason"]] += 1
        if kind == "transport":
            if r["reason"] == "clockRestart" and not self.transport_due:
                self.err(r, "each primary sampleClock bump forces one transport bump with reason clockRestart")
            self.hist, self.transport_due = [], self.transport_due and r["reason"] != "clockRestart"
            if r["reason"] != "clockRestart":  # a locate or transport restart supersedes a pending restart resume
                self.passes, self.resume, self.restart_snap = (self.passes[0] + 1, 0), None, ([], None)
        elif kind == "musicalMap":
            self.check_map(r, r["musicalMap"])
            meter = r.get("meter", self.meter)
            if same(r["musicalMap"], self.map) and same(meter, self.meter):
                self.err(r, "a musicalMap revision changes the tempo segments or the meter (absent: inherited)")
            self.map, self.meter = r["musicalMap"], meter

    def on_discontinuity(self, r):
        kind, clock = r["type"], r["sampleClock"]
        self.discs.append(r)
        if r["generation"] != self.gens.get(f"sampleClock/{clock}"):
            self.err(r, "discontinuity generation is not current")
        if kind == "clockRestart":
            if clock not in self.pending_restart:
                self.err(r, "clockRestart without a sample clock generation change")
            if "hostTicks" not in r:
                self.err(r, "clockRestart records the host ticks at which the new generation starts")
            else:
                self.restarts[clock] = r
                if "previousFrame" in r and clock == self.primary and self.restart_snap[0]:
                    i, t = self.under(self.restart_snap, self.position, r["previousFrame"])
                    self.resume, self.passes = rnd(t), (self.passes[0], self.passes[1] + i)  # it continues pass i
            self.pending_restart.discard(clock)
            self.evidence.add("clockRestart")
        wrap = kind == "loopWrap" and self.loop and self.musical_ok() and self.at(r["frame"])
        if kind == "loopWrap" and not (wrap and wrap["frame"] == r["frame"] and wrap not in self.hist):
            self.err(r, "a loopWrap falls exactly at the loop end of the anchored pass")  # a virtual next-pass anchor
        direction = {"underrun": "playback", "overflow": "capture"}.get(kind)
        stream = self.streams.get(r.get("stream"))
        if kind in ("underrun", "overflow", "sourceLost", "sourceRestored", "captureStopped", "formatChange") \
                and stream is None:
            self.err(r, f"{kind} names a declared stream")
        if direction and (stream is None or stream["direction"] != direction or "frames" not in r):
            self.err(r, f"{kind} needs a {direction} stream and a frame count")
        for field, owner in (("previousFrame", "clockRestart"), ("reason", "captureStopped")):
            if (field in r) != (kind == owner):
                self.err(r, f"{field} is required on {owner} discontinuities and only there")
        if kind == "formatChange":
            self.protocols.pop(r.get("stream"), None)
        self.evidence.update({"locate": {"seek"}, "sourceLost": {"sourceLoss"}, "underrun": {"prefetch"}}.get(kind, set()))

    def on_trigger(self, r):
        tid, action = r["triggerId"], self.actions.get(r["actionId"])
        if tid in self.triggers or action is None:
            self.err(r, "trigger ids are unique and reference a declared action")
            return
        req = r["requires"]
        target = r.get("target", action["quantize"])
        musical = target["timeBase"] == "musical" or action["late"]["policy"] == "nextBoundary"
        needed = [f"sampleClock/{self.primary}"] + ([f"transport/{self.mus_id}"] if musical else [])
        if any(k not in req for k in needed) or not any(k.startswith("context/") for k in req):
            self.err(r, "trigger captures sample clock, context and (for musical targets or nextBoundary) transport")
            return
        if any(k.startswith("musicalMap/") for k in req):
            self.err(r, "musical map revisions re-resolve targets; they never make a trigger stale")
        stale = sorted({k.split("/")[0] for k, v in req.items() if self.gens.get(k) != v})
        if req[f"sampleClock/{self.primary}"] == self.gens.get(f"sampleClock/{self.primary}"):
            self.horizon = max(self.horizon, r["horizonFrame"])
        info = {"rec": r, "action": action, "stale": stale, "ready": self.state[r["actionId"]] == "ready",
                "invalidated": False, "target": target, "expect": None}
        self.triggers[tid] = info
        if not stale and info["ready"]:  # notReady takes precedence: an unready action's target is never resolved
            info["expect"] = self.resolve(r, action, target)

    def resolve(self, r, action, target):
        origin, horizon = self.frame_at_host(r["originHostTicks"]), r["horizonFrame"]
        if origin is None or origin > horizon:
            self.err(r, "origin needs a current anchor and must not be after the horizon")
            return None
        if target["timeBase"] == "asap":
            return {"frame": horizon, "occ": None, "retro": False}
        if target["timeBase"] == "sample":
            return {"frame": target["atFrame"], "occ": None, "retro": False}
        if not self.musical_ok():
            self.err(r, "musical target without a current musical anchor")
            return None
        i, t = self.position(origin)  # the target is an occurrence in the pass holding the origin
        if "atTicks" in target:
            choice = {"occ": (i, target["atTicks"]), "retro": False}
        else:
            grid = target["gridTicks"]
            prev, nxt = (i, math.floor(t / grid) * grid), self.boundary((i, t), grid)
            retro = Fraction(action["late"].get("retroactiveMs", 0) * self.rate(), 1000)
            choice = {"occ": nxt, "retro": False}
            if prev != nxt and retro > 0 and origin - self.frame_of(prev) <= retro:
                choice = {"occ": prev, "retro": True}
        if self.loop and not self.loop["startTicks"] <= choice["occ"][1] <= self.loop["endTicks"]:
            self.err(r, "v1 resolves musical targets inside the active loop; loop end is the wrap frame")
        return choice

    def expected(self, info):
        e, late, horizon = info["expect"], info["action"]["late"], max(info["rec"]["horizonFrame"], self.horizon)
        musical = e["occ"] is not None  # lateness is judged at the commit-time horizon; asap commits at it
        assigned = horizon if info["target"]["timeBase"] == "asap" else rnd(self.frame_of(e["occ"])) if musical \
            else e["frame"]
        if assigned >= horizon:
            return "fired", assigned, assigned, musical
        within = (horizon - assigned) * 1000 <= late.get("maxLatenessMs", 0) * self.rate()
        policy = late["policy"]
        if policy in ("fireLate", "joinInProgress") and within:
            return ("firedLate" if policy == "fireLate" else "joined"), assigned, horizon, musical
        grid = info["target"].get("gridTicks") or info["action"]["quantize"].get("gridTicks")
        if policy == "nextBoundary" and grid:
            if not self.musical_ok():
                self.err(info["rec"], "nextBoundary needs a current musical anchor")
                return "dropped", assigned, None, False
            occ = self.boundary(self.position(horizon), grid)
            last_pass = self.position(horizon)[0] + 1
            while True:
                if self.loop and not self.loop["startTicks"] <= occ[1] <= self.loop["endTicks"]:
                    self.err(info["rec"], "nextBoundary target must resolve inside the active loop")
                    return "dropped", assigned, None, True
                frame = rnd(self.frame_of(occ))
                if frame >= horizon:
                    return "fired", frame, frame, True
                if occ[0] > last_pass:
                    self.err(info["rec"], "nextBoundary cannot resolve before the current horizon")
                    return "dropped", assigned, None, True
                occ = self.boundary(occ, grid, after=True)
        return "dropped", assigned, None, musical

    def on_outcome(self, r):
        info = self.triggers.get(r["triggerId"])
        if info is None or info.get("done"):
            self.err(r, "outcome needs exactly one earlier trigger; a second terminal outcome is a replay")
            return
        info["done"] = True
        result, reason, trig = r["result"], r.get("reason"), info["rec"]
        stale_now = {k.split("/")[0] for k, v in trig["requires"].items() if self.gens.get(k) != v}
        if info["stale"]:
            if result != "rejectedStale" or reason not in info["stale"]:
                self.err(r, f"arrived with stale {info['stale']}: must be rejectedStale naming one of them")
            self.evidence.add("noStaleReplay")
            return
        if stale_now:
            if result != "cancelled" or reason not in stale_now:
                self.err(r, f"generations {sorted(stale_now)} changed while pending: must be cancelled, never fired")
            self.evidence.add("cancellation")
            return
        if result in ("cancelled", "rejectedStale"):
            self.err(r, "cancellation and staleness require a generation change")
            return
        if not info["ready"] or info["invalidated"] or self.state[trig["actionId"]] != "ready":
            if (result, reason) != ("dropped", "notReady"):
                self.err(r, "action was not continuously ready: must be dropped with reason notReady")
            self.evidence.add("readiness")
            return
        if info["expect"] is None:
            return
        want, assigned, frame, musical = self.expected(info)
        if result != want or r.get("assignedFrame") != assigned or r.get("frame") != frame:
            self.err(r, f"expected {want} assignedFrame={assigned} frame={frame}")
        if result == "dropped" and reason != "late":
            self.err(r, "a timing drop names reason late")
        if result == "joined" and r.get("startOffsetFrames") != frame - assigned:
            self.err(r, "joined outcome starts the source at frame - assignedFrame")
        if musical and result != "dropped":
            if r.get("musicalMap") != self.gens.get(f"musicalMap/{self.mus_id}"):
                self.err(r, "musical outcome resolves with the current musicalMap revision")
            elif r["musicalMap"] > 1:
                self.evidence.add("tempoMutation")
        if result in ("firedLate", "joined") or (result == "dropped" and reason == "late"):
            self.evidence.add("lateCue")
        if result == "joined" and info["expect"]["retro"]:
            self.evidence.add("retroactiveCue")

    def on_readiness(self, r):
        aid, cur = r["actionId"], self.state.get(r["actionId"])
        if cur is None or r["from"] != cur or r["to"] not in READINESS[cur]:
            self.err(r, f"illegal readiness transition {r['from']} -> {r['to']} (current {cur})")
            return
        action = self.actions[aid]
        if r["to"] in ("failed", "invalidated") and "reason" not in r:
            self.err(r, "failed and invalidated readiness states carry a reason")
        if r["to"] == "ready" and not self.stretch_ok(action):
            self.err(r, "time-stretch actions need a declared time-stretch adapter")
        if r["to"] == "failed" and action.get("timePolicy") == "timeStretch":
            self.evidence.add("timeStretchPolicy")
        if r["to"] == "ready" and "prefetch" in action:
            self.evidence.add("prefetch")
        if cur == "ready":
            for info in self.triggers.values():
                if info["rec"]["actionId"] == aid and not info.get("done"):
                    info["invalidated"] = True
        self.state[aid] = r["to"]

    def on_dispatch(self, r):
        stream = self.streams.get(r["stream"])
        if stream is None:
            self.err(r, "dispatch names a declared stream")
            return
        key = (r["frame"], LANES[r["lane"]], stream["ordinal"], r["streamSeq"])
        if self.last_dispatch and key < self.last_dispatch:
            self.err(r, "dispatch order must follow (frame, lane, streamOrdinal, streamSeq)")
        if self.last_dispatch and key[0] == self.last_dispatch[0]:
            self.evidence.add("ordering")
        if r["streamSeq"] <= self.stream_seq.get(r["stream"], 0):
            self.err(r, "stream order is preserved within a stream")
        self.last_dispatch, self.stream_seq[r["stream"]] = key, r["streamSeq"]

    def on_midiCapture(self, r):
        if not self.stream_is(r["stream"], "midi", "capture"):
            self.err(r, "midiCapture names a declared MIDI capture stream")
        if r["hostTicks"] < self.restarts.get(self.primary, {}).get("hostTicks", 0):
            self.err(r, "capture timestamp predates clockRestart: v1 rejects it, never remapping it (§9.2)")
            return
        words = [int(w, 16) for w in r["ump"]]
        mt, ep, port = words[0] >> 28, r["endpointProtocol"], r["portProtocol"]
        if len(words) != UMP_WORDS[mt]:
            self.err(r, f"UMP message type {mt:X} has {UMP_WORDS[mt]} words")
            return
        if r["translatedBy"] != ("os" if {"unknown": "midi1"}.get(ep, ep) != port else "none"):
            self.err(r, "translatedBy must reflect endpoint versus port protocol (an unknown endpoint counts as midi1)")
        if r.get("verified", True) != (ep != "unknown"):
            self.err(r, "verified is false exactly when the endpoint protocol is unknown")
        if self.protocols.setdefault(r["stream"], (ep, port)) != (ep, port):
            self.err(r, "a protocol change on a stream needs a formatChange discontinuity before the next capture")
        self.protocols[r["stream"]] = (ep, port)
        if r["effective"] != "midi1" and ep != "midi2" \
                or mt in (2, 4) and r["effective"] != ("midi2" if mt == 4 and ep == "midi2" else "midi1"):
            self.err(r, "effective fidelity is what the endpoint sent, never the container's resolution")
        if mt in (2, 4) and (mt == 4) != (port == "midi2"):
            self.err(r, "channel voice arrives in the port's protocol: MT 0x4 on a midi2 port, MT 0x2 on a midi1 port")
        frame = self.frame_at_host(r["hostTicks"])
        if frame is None or rnd(frame) != r["frame"]:
            self.err(r, "capture frame must map from hostTicks through the current anchor")
        has = "musicalTicks" in r
        if has != self.musical_ok() or has and rnd(self.position(r["frame"])[1]) != r["musicalTicks"]:
            self.err(r, "capture musicalTicks map from frame through the current musical anchor, exactly when one is")
        self.captures.append((r, words, (self.hist, self.map), self.passes))
        if r["effective"] == ep == "midi1" and mt in (2, 4):
            self.evidence.add("midi1InUmp")
        if r["effective"] == "midi2" and mt == 4:
            self.evidence.add("midi2Native")

    def under(self, snap, fn, *args):
        """fn against a (musical anchor, map) snapshot: capture time for SMF export, pre-restart for the resume tick."""
        live, (self.hist, self.map) = (self.hist, self.map), snap
        try:
            return fn(*args)
        finally:
            self.hist, self.map = live

    def smf_frame(self, snap, frame, step, base):
        """(Pass key, frame) an SMF tick at `step` resolution reconstructs through the capture-time anchor and map."""
        def rebuild(a):
            tick = rnd(self.ticks_at_frame(frame, a) / step) * step
            return (base[0], base[1] + a.get("loopIteration", 0)), rnd(self.frame_of_ticks(tick, a))
        return self.under(snap, lambda: rebuild(self.at(frame)))

    def on_export(self, r):
        events = [e for e in self.captures if e[0]["stream"] in r["streams"]]
        if not events or len(set(r["streams"])) != len(r["streams"]) \
                or not all(self.stream_is(s, "midi", "capture") for s in r["streams"]):
            self.err(r, "export names distinct, declared MIDI capture streams with captured events")
        losses, native, origin = Counter(), r["format"] == "nativeUmp", r.get("origin", {})
        if set(r) & ({"division", "smfFormat"} if native else {"origin", "offsetsNs"}):
            self.err(r, "division and smfFormat are SMF-only; origin and offsetsNs are native-UMP-only")
        if native:
            anchor = self.first_anchor.get((origin.get("sampleClock"), origin.get("generation")))
            start = self.host_at(anchor, origin["frame"]) if anchor else None
            offsets = start is not None and [rnd((e[0]["hostTicks"] - start) * self.ns_per_tick) for e in events]
            if r.get("offsetsNs") != offsets:  # False (no recorded anchor) never matches
                self.err(r, "native UMP export keeps words verbatim and persists offsetsNs from its origin's recorded "
                            "anchor, never absolute host ticks")
        else:
            division = r.get("division", 0)
            if not division or TPQ % division or r.get("smfFormat") is None:
                self.err(r, "SMF export declares smfFormat and a division that divides 15360")
                return
            groups = {(e[1][0] >> 24) & 0xF for e in events if e[1][0] >> 28 in GROUPED}
            timing = [self.smf_frame(snap, c["frame"], TPQ // division, base) if "musicalTicks" in c else (None, None)
                      for c, _, snap, base in events]
            first = min((p for p, _ in timing if p), default=None)
            for (c, words, _, _), (key, frame) in zip(events, timing):
                mt = words[0] >> 28
                if "musicalTicks" not in c:
                    losses["syntheticTempoMap"] += 1
                elif frame != c["frame"]:
                    losses["timingQuantized"] += 1
                if key and key > first:
                    losses["passesOverlaid"] += 1
                if mt == 4 and c["effective"] == "midi2":
                    losses.update(midi2_losses(words))
                elif mt == 4 and c["endpointProtocol"] == "unknown":
                    losses["fidelityUnverified"] += 1
                elif mt not in (2, 3, 4):
                    losses["umpOnlyDropped"] += 1
                if mt in GROUPED and len(groups) > 1 and (words[0] >> 24) & 0xF != min(groups):
                    losses["groupsFlattened"] += 1
            self.evidence.add("smfExportLossless" if r["lossless"] else "smfExportLossy")
        if dict(losses) != r["losses"]:
            self.err(r, f"declared losses {r['losses']} must equal recomputed {dict(losses)}")
        if r["lossless"] != (not r["losses"]):
            self.err(r, "lossless is true exactly when no loss category is reported")

    def on_take(self, r):
        segs = r["segments"]
        if not self.stream_is(r["stream"], "audio", "capture"):
            self.err(r, "take names a declared audio capture stream")
        if r["inputLatency"]["measuredFrames"] is not None and "evidence" not in r["inputLatency"]:
            self.err(r, "measured latency cites its evidence; reported latency is not measured latency")
        mine = [d for d in self.discs if d.get("stream") == r["stream"]]  # scoped below to this take's intervals
        restarts = {(d["sampleClock"], d["generation"]): d for d in self.discs if d["type"] == "clockRestart"}
        file_frame, base, stops = 0, None, []
        for i, seg in enumerate(segs):
            clock, gen, start = seg["sampleClock"], seg["generation"], seg["startFrame"]
            end, restart = start + seg["frames"], restarts.get((clock, gen + 1), {})
            if end > restart.get("previousFrame", end) or i + 1 < len(segs) and (
                    (segs[i + 1]["sampleClock"], segs[i + 1]["generation"]) != (clock, gen + 1)
                    or end != restart.get("previousFrame") or segs[i + 1]["startFrame"] != restart.get("frame")):
                self.err(r, "segments split at each clock restart: ending at its previousFrame (no segment, the last "
                            "included, ends after it), resuming at its frame")
            if seg["fileFrameStart"] != file_frame:
                self.err(r, "segments are contiguous in the file; no padding across clock restarts")
            anchor = self.first_anchor.get((clock, gen))
            host = None if anchor is None else self.host_at(anchor, start)  # at that generation's own rate
            base = host if i == 0 else base
            if host is None or base is None or rnd((host - base) * self.ns_per_tick) != seg["startOffsetNs"]:
                self.err(r, "segment startOffsetNs is the ns offset of its anchored start from the first segment's")
            here = [(d, d["frame"], d["frame"] + d.get("frames", 0)) for d in mine
                    if (d["sampleClock"], d["generation"]) == (clock, gen)]
            inside = [(lo, hi) for d, lo, hi in here if d["type"] == "overflow" and lo < end and hi > start]
            if any(lo < start or hi > end for lo, hi in inside):
                self.err(r, "every overflow interval lies wholly inside its segment")
            if seg["paddedFrames"] != sum(hi - lo for lo, hi in inside):
                self.err(r, "paddedFrames equal the overflow frames inside the segment")
            stops += [d for d, lo, _ in here if d["type"] == "captureStopped" and start < lo <= end]
            file_frame += seg["frames"]
        if r["droppedFrames"] != sum(s["paddedFrames"] for s in segs):
            self.err(r, "droppedFrames equals the take's padded overflow frames; no silent capture loss")
        last = (segs[-1]["sampleClock"], segs[-1]["generation"], segs[-1]["startFrame"] + segs[-1]["frames"])
        if any(d.get("reason") != r["stopReason"] for d in stops) or (r["stopReason"] != "user") != (
                len(stops) == 1 and (stops[0]["sampleClock"], stops[0]["generation"], stops[0]["frame"]) == last):
            self.err(r, "a take's captureStopped matches its stopReason: none if user, else one at its last frame")
        self.evidence.add("capture")


def check_example(doc, name, schema):
    errors = []
    validate(schema, doc, schema["$defs"], "$", errors)
    if errors:
        return [f"{name}: {e}" for e in errors], set()
    if doc["exampleId"] != "ex." + Path(name).stem:
        return [f"{name}: exampleId must be ex.<file stem>"], set()
    trace = Trace(doc, name)
    try:
        trace.run()
    except Exception as exc:  # a malformed trace must report FAIL, never crash the checker
        trace.err({}, f"replay aborted: {type(exc).__name__}: {exc}")
    return trace.errors, set(doc["covers"])


# (example, where, changes, error): each breaks one rule in a valid example and must fail with that rule's error;
# error None marks a positive control that must still pass. `where` is a timeline seq or a dotted document path ("" is
# the root); change keys are dotted paths under it; None deletes.
MUTATIONS = [
    ("01", 4, {"to": 3}, "advance the current value by exactly one"),
    ("01", 8, {"musicalTicks": 46080}, "resumes at the last rendered tick 92160"),
    ("01", 7, {"hostTicks": 2490000001}, "their clockRestart stamp"),
    ("01", 9, {"streamSeq": 41}, "stream order is preserved within a stream"),
    ("01", 10, {"horizonFrame": 9000000}, None),  # a stale sample generation cannot advance the live horizon
    ("01", 6, {"reason": "transportRestart"}, "forces one transport bump with reason clockRestart"),
    ("01", 13, {"result": "dropped", "reason": "capacity"}, '.reason: "capacity" not in enum'),
    ("01", "actions.0", {"timePolicy": "timeStretch"}, "need a declared time-stretch adapter"),
    ("01", "clocks.musical", {"loop": {"startTicks": 0, "endTicks": 92160}}, "resumes at the last rendered tick 0"),
    ("01", "", {"clocks.musical.loop": {"startTicks": 0, "endTicks": 92160}, "timeline.7.musicalTicks": 0,
                "timeline.12.assignedFrame": 192000, "timeline.12.frame": 192000}, None),
    ("02", 9, {"result": "fired", "reason": None, "frame": 336000}, "expected dropped assignedFrame=336000"),
    ("02", 11, {"assignedFrame": 360000, "frame": 360000}, "expected fired assignedFrame=384000"),
    ("02", "", {"clocks.musical.loop": {"startTicks": 0, "endTicks": 230400}, "timeline.9.horizonFrame": 335999,
                "timeline.8": {"seq": 9, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 340000,
                               "hostTicks": 2570000000, "transport": 1, "musicalTicks": 217601}},
     "expected fired assignedFrame=359998"),  # a later anchor moves the boundary behind the horizon: step past loop end
    ("03", 3, {"type": "sampleJump"}, "loop iteration must follow a loopWrap"),
    ("03", 3, {"frame": 191999}, "a loopWrap falls exactly at the loop end"),
    ("03", 8, {"assignedFrame": 384000, "frame": 384000}, "expected fired assignedFrame=288000"),
    ("03", 9, {"musicalTicks": 121600}, "capture musicalTicks map from frame"),
    ("03", 12, {"reason": "clockRestart"}, "forces one transport bump with reason clockRestart"),
    ("03", 14, {"result": "fired", "reason": None, "assignedFrame": 288000, "frame": 288000, "musicalMap": 1},
     "changed while pending: must be cancelled"),
    ("03", 23, {"lossless": True, "losses": {}}, "'passesOverlaid': 2"),
    ("04", 5, {"musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}], "meter": None},
     "changes the tempo segments or the meter"),
    ("04", 7, {"assignedFrame": 288000, "frame": 288000}, "expected fired assignedFrame=268800"),
    ("04", 12, {"musicalTicks": 103680}, "capture musicalTicks map from frame"),
    ("04", "timeline", {"5.musicalTicks": 122881, "6.assignedFrame": 268799, "6.frame": 268799}, None),  # SMF inverts
    ("05", 9, {"result": "fired", "reason": None, "assignedFrame": 192000, "frame": 192000, "musicalMap": 1},
     "changed while pending: must be cancelled"),
    ("06", 9, {"result": "fired", "reason": None}, "must be rejectedStale"),
    ("07", 3, {"result": "fired", "reason": None, "assignedFrame": 96000, "frame": 96000, "musicalMap": 1},
     "must be dropped with reason notReady"),
    ("07", 8, {"reason": None}, "failed and invalidated readiness states carry a reason"),
    ("08", 2, {"frame": 959900}, "lies wholly inside its segment"),
    ("08", 3, {"nominalRate": None}, "required on rateChange"),
    ("08", 4, {"hostTicks": 2800000000}, "their clockRestart stamp"),
    ("08", 4, {"hostTicks": 2900047750}, None),  # 191 frames of jitter; bound = 191.809 frames
    ("08", 4, {"hostTicks": 2900048000}, "their clockRestart stamp"),
    ("08", 8, {"droppedFrames": 0}, "no silent capture loss"),
    ("08", 8, {"segments.0.frames": 912000, "segments.1.fileFrameStart": 912000}, "ending at its previousFrame"),
    ("08", 8, {"stopReason": "user"}, "captureStopped matches its stopReason"),
    ("08", 8, {"segments.1": None, "segments.0.frames": 960001, "droppedFrames": 1024, "stopReason": "user"},
     "no segment, the last included, ends after it"),
    ("08", 8, {"segments.1": None, "segments.0.frames": 960000, "droppedFrames": 1024, "stopReason": "user"}, None),
    ("08", 9, {"reason": "diskFull"}, "captureStopped matches its stopReason"),
    ("08", "clocks.musical", {"musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}] * 2}, "strictly increase"),
    ("09", 2, {"ump": ["0x20903C64\n"]}, "violates length/pattern"),
    ("09", 4, {"effective": "midi2"}, "never the container's resolution"),
    ("09", 2, {"ump": ["0x30020102", "0x00000000"], "effective": "midi2"}, "never the container's resolution"),
    ("09", 6, {"endpointProtocol": "midi2", "translatedBy": "none", "effective": "midi2"}, "needs a formatChange"),
    ("09", 6, {"frame": 144001, "hostTicks": 2472000500}, "recomputed {'timingQuantized': 1}"),
    ("09", 12, {"origin.generation": 2}, "offsetsNs from its origin's recorded anchor"),
    ("09", "", {"clocks.musical.loop": {"startTicks": 0, "endTicks": 15360}, "timeline.5.musicalTicks": 0,
                "timeline.9.musicalTicks": 640, "timeline.10": {  # the restart continues loop pass 1
        "seq": 11, "kind": "midiCapture", "stream": "str.keys-a", "ump": ["0x20903E64"], "hostTicks": 2493000000,
        "frame": 6000, "musicalTicks": 1280, "endpointProtocol": "midi1", "portProtocol": "midi1",
        "translatedBy": "none", "effective": "midi1"}, "timeline.11": {"seq": 12, "kind": "export", "exportId": "exp.s",
        "streams": ["str.keys-a"], "format": "smf", "smfFormat": 1, "division": 960, "lossless": True, "losses": {}}},
     "'passesOverlaid': 1"),
    ("10", "timeline", {"8.musicalTicks": None, "11.losses.syntheticTempoMap": 1}, "exactly when one is"),
    ("10", 2, {"portProtocol": "midi1", "translatedBy": "os"}, "MT 0x4 on a midi2 port"),
    ("10", 8, {"ump": ["0x22903C64"]}, "'groupsFlattened': 1"),
    ("10", 11, {"streams": ["str.synth", "str.missing"]}, "declared MIDI capture streams"),
    ("10", 11, {"origin.frame": 0}, "offsetsNs from its origin's recorded anchor"),
    ("10", 12, {"lossless": True, "losses": {}}, "must equal recomputed"),
    ("03", "clocks.musical.loop", {"startTicks": 122880}, "a loop needs startTicks < endTicks"),
    ("07", "timeline", {"0.transport": None, "0.musicalTicks": None, "5.target": {"timeBase": "sample",
                        "atFrame": 96000}, "6.musicalMap": None}, None),  # unready trg.1 drops, never resolved
    ("09", "streams.1", {"streamId": "str.keys-a"}, "duplicate streamId"),
    ("04", "actions.1", {"actionId": "act.drums"}, "duplicate actionId"),
    ("01", 6, {"counter": "sampleClock/smp.main", "from": 2, "to": 3, "reason": "wake"}, "before the next"),
    ("04", 4, {"target": {"timeBase": "sample", "atFrame": 100000}, "requires": {
        "sampleClock/smp.main": 1, "context/ctx.main": 1}}, "for musical targets or nextBoundary"),
    ("04", "timeline", {"3.target": {"timeBase": "sample", "atFrame": 100000}, "6.assignedFrame": 192000,
                        "6.frame": 192000}, None),  # a sample target falls back to the musical grid when late
    ("04", "timeline", {"3.target": {"timeBase": "sample", "atFrame": 100000}, "6.assignedFrame": 192000,
                        "6.frame": 192000, "6.musicalMap": 1}, "current musicalMap revision"),
    ("04", 6, {"frame": 280000, "hostTicks": 2540000000, "musicalTicks": 193280}, "fired assignedFrame=288000"),
    ("09", "timeline", {"10": {"seq": 11, "kind": "midiCapture", "stream": "str.keys-a", "ump": ["0x20903C64"],
     "hostTicks": 2489999999, "frame": 0, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none",
     "effective": "midi1"}}, "capture timestamp predates clockRestart"),
    ("08", 10, {"takeId": "tk.1"}, "duplicate takeId"),
    ("01", 8, {"frame": -1}, "their clockRestart stamp"),  # not before the restart even within jitter
]


def mutate(doc, where, changes):
    base = ["timeline", where - 1] if isinstance(where, int) else [p for p in where.split(".") if p]
    for key, value in changes.items():
        *path, last = base + key.split(".")
        node = doc
        for part in path:
            node = node[int(part)] if isinstance(node, list) else node[part]
        last = int(last) if isinstance(node, list) else last
        if value is None:
            node.pop(last) if isinstance(node, list) else node.pop(last, None)
        else:
            node[last] = value


def main(argv):
    errors, covered, docs = [], set(), {}
    schema = load_canonical(SCHEMA_PATH, 99, "--write" in argv, errors)
    if schema is None:
        print("error:", errors[0])
        return 1
    check_keywords(schema)
    files = sorted(EXAMPLES.glob("*.json"))
    for path in files:
        doc = load_canonical(path, 2, "--write" in argv, errors)
        if doc is None:
            print(f"FAIL {path.name}")
            continue
        found, claims = check_example(doc, path.name, schema)
        errors += found
        if not found:  # only valid examples are mutation fixtures; a missing one reports "record missing"
            covered |= claims
            docs[path.stem[:2]] = (doc, path.name)
        print(f"{'ok  ' if not found else 'FAIL'} {path.name}")
    if set(schema["$defs"]["coverage"]["enum"]) - covered:
        errors.append(f"coverage missing: {sorted(set(schema['$defs']['coverage']['enum']) - covered)}")
    for prefix, where, changes, expect in MUTATIONS:
        doc, name = copy.deepcopy(docs.get(prefix, ({}, prefix)))
        label = f"mutation {prefix} {'seq ' * isinstance(where, int)}{where or 'root'}"
        try:
            mutate(doc, where, changes)
        except (KeyError, IndexError, TypeError, ValueError):
            errors.append(f"{label}: record missing")
            continue
        found = check_example(doc, name, schema)[0]
        caught = not found if expect is None else any(expect in e for e in found)
        print(f"{'ok  ' if caught else 'FAIL'} {label} {'accepted' if expect is None else 'rejected: ' + expect}")
        if not caught:
            errors.append(f"{label} did not {'pass: ' + str(found[:1]) if expect is None else 'fail with ' + expect}")
    for line in errors:
        print("error:", line)
    print(f"{len(files)} examples, {len(MUTATIONS)} mutations, {len(errors)} errors")
    return 1 if errors or not files else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
