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


def canon(value, depth_limit, indent=0, prefix=0):
    """Deterministic layout: authored key order; a container is inline when it fits WIDTH or sits at depth_limit,
    otherwise its members are packed greedily into rows of at most WIDTH, and a multi-line member gets its own rows."""
    flat = json.dumps(value, ensure_ascii=False, separators=(", ", ": "), allow_nan=False)
    if not isinstance(value, (dict, list)) or not value or indent // 2 >= depth_limit \
            or indent + prefix + len(flat) + 1 <= WIDTH:
        return flat
    pad, rows, row = " " * (indent + 2), [], ""
    heads = [json.dumps(k, ensure_ascii=False) + ": " for k in value] if isinstance(value, dict) else [""] * len(value)
    for head, item in zip(heads, value.values() if isinstance(value, dict) else value):
        part = head + canon(item, depth_limit, indent + 2, len(head))
        if row and ("\n" in part + row or len(pad) + len(row) + len(part) + 3 > WIDTH):
            rows.append(row + ",")
            row = ""
        row += (", " if row else "") + part
    brackets = "{}" if isinstance(value, dict) else "[]"
    return brackets[0] + "\n" + "\n".join(pad + r for r in rows + [row]) + "\n" + " " * indent + brackets[1]


def load_canonical(path, depth_limit, write, errors):
    """Parse strictly (no duplicate keys, NaN or Infinity) and require the file to equal its canonical rendering."""
    try:
        text = path.read_text(encoding="utf-8")
        doc = json.loads(text, object_pairs_hook=no_duplicates, parse_constant=reject_constant)
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


def reject_constant(name):
    raise ValueError(f"{name} is not JSON")


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
        clocks = doc["clocks"]
        self.doc, self.name, self.errors, self.evidence = doc, name, [], set()
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
        self.anchor, self.first_anchor, self.musical = {}, {}, None
        self.triggers, self.captures, self.discs = {}, [], []
        self.pending_restart, self.last_dispatch, self.stream_seq, self.transport_due = set(), None, {}, False
        self.bumps, self.protocols, self.resume, self.restart_snap = Counter(), {}, None, (None, None)

    def err(self, rec, msg):
        self.errors.append(f"{self.name} seq {rec.get('seq', '-')}: {msg}")

    def rate(self, clock=None, gen=None):
        """Nominal rate of a sample clock generation (default: the current generation of the primary clock)."""
        clock = clock or self.primary
        return self.rates.get((clock, gen or self.gens.get(f"sampleClock/{clock}")))

    def host_at(self, anchor, frame):
        rate = self.rate(anchor["sampleClock"], anchor["generation"])
        return anchor["hostTicks"] + (frame - anchor["frame"]) * Fraction(10**9, rate) / self.ns_per_tick

    def current_anchor(self):
        a = self.anchor.get(self.primary)
        return a if a and a["generation"] == self.gens.get(f"sampleClock/{self.primary}") else None

    def frame_at_host(self, ticks):
        a = self.current_anchor()
        return None if a is None else a["frame"] + (ticks - a["hostTicks"]) * self.ns_per_tick * self.rate() / 10**9

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

    def frame_of_ticks(self, ticks):
        t0 = self.musical["musicalTicks"]
        return self.musical["frame"] + (self.span(t0, ticks) if ticks >= t0 else -self.span(ticks, t0))

    def ticks_at_frame(self, frame):
        """Exact inverse of frame_of_ticks, walking from tick 0 so earlier frames cross earlier tempo segments."""
        f = self.frame_of_ticks(0)
        for start, end, fpt in self.segments():
            if end is None or f + (end - start) * fpt > frame:
                return start + (frame - f) / fpt
            f += (end - start) * fpt

    def run(self):
        records = self.doc["timeline"]
        if [r["seq"] for r in records] != list(range(1, len(records) + 1)):
            self.err({}, "timeline seq must be 1..n in order")
        for a in self.actions.values():
            self.check_action(a)
        self.check_map({}, self.map)
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
        if prev and prev["generation"] == r["generation"]:
            span = (r["hostTicks"] - first["hostTicks"]) * self.ns_per_tick * rate / 10**9
            if r["frame"] <= prev["frame"] or r["hostTicks"] <= prev["hostTicks"] \
                    or abs(r["frame"] - first["frame"] - span) > (rate + span) / 1000:
                self.err(r, "anchors advance and stay within (rate + span)/1000 frames of their generation's first")
        self.anchor[clock] = r
        if ("musicalTicks" in r) != ("transport" in r):
            self.err(r, "musical anchors carry both transport and musicalTicks")
        if "musicalTicks" not in r or clock != self.primary:
            return
        if r["transport"] != self.gens.get(f"transport/{self.mus_id}"):
            self.err(r, "anchor transport generation is not current")
        m, it = self.musical, r.get("loopIteration", 0)
        if (not m or m["transport"] != r["transport"]) and it:
            self.err(r, "a new transport generation (start, locate or restart) begins at loopIteration 0")
        if self.resume is not None and r["musicalTicks"] != self.resume:
            self.err(r, f"after a clock restart the transport resumes at the last rendered tick {self.resume}")
        self.resume = None
        if m and m["transport"] == r["transport"]:
            if m["generation"] != r["generation"]:
                self.err(r, "a sample clock restart must re-anchor with a new transport generation")
            elif it == m.get("loopIteration", 0):
                if abs(self.ticks_at_frame(r["frame"]) - r["musicalTicks"]) > 1:
                    self.err(r, "musical position jumped without locate or loop wrap")
            elif it == m.get("loopIteration", 0) + 1:
                wrap = self.prev
                ok = wrap and wrap["kind"] == "discontinuity" and wrap["type"] == "loopWrap" and wrap["frame"] == r["frame"]
                if not ok or not self.loop or r["musicalTicks"] != self.loop["startTicks"] \
                        or abs(self.ticks_at_frame(r["frame"]) - self.loop["endTicks"]) > 1:
                    self.err(r, "loop iteration must follow a loopWrap at loop end and restart at loop start")
                else:
                    self.evidence.add("loop")
            else:
                self.err(r, "loopIteration advances by exactly one per wrap")
        self.musical = r

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
            self.rates[(clock, r["to"])] = r.get("nominalRate", self.rate(clock))
            self.pending_restart.add(clock)
            if clock == self.primary:  # frames restart with the generation; the resume tick uses the old anchor and map
                self.last_dispatch, self.restart_snap = None, (self.musical, self.map)
                self.transport_due = f"transport/{self.mus_id}" in self.gens
        self.gens[counter] = r["to"]
        self.bumps[r["reason"]] += 1
        if kind == "transport":
            if r["reason"] == "clockRestart" and not self.transport_due:
                self.err(r, "each primary sampleClock bump forces one transport bump with reason clockRestart")
            self.musical, self.transport_due = None, self.transport_due and r["reason"] != "clockRestart"
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
            elif "previousFrame" in r and clock == self.primary and self.restart_snap[0]:
                self.resume = rnd(self.under(self.restart_snap, self.ticks_at_frame, r["previousFrame"]))
            self.pending_restart.discard(clock)
            self.evidence.add("clockRestart")
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
        needed = [f"sampleClock/{self.primary}"] + ([f"transport/{self.mus_id}"] if target["timeBase"] == "musical" else [])
        if any(k not in req for k in needed) or not any(k.startswith("context/") for k in req):
            self.err(r, "trigger captures the sample clock, context and (for musical targets) transport generations")
            return
        if any(k.startswith("musicalMap/") for k in req):
            self.err(r, "musical map revisions re-resolve targets; they never make a trigger stale")
        stale = sorted({k.split("/")[0] for k, v in req.items() if self.gens.get(k) != v})
        info = {"rec": r, "action": action, "stale": stale, "ready": self.state[r["actionId"]] == "ready",
                "invalidated": False, "target": target, "expect": None}
        self.triggers[tid] = info
        if not stale:
            info["expect"] = self.resolve(r, action, target)

    def resolve(self, r, action, target):
        origin, horizon = self.frame_at_host(r["originHostTicks"]), r["horizonFrame"]
        if origin is None or origin > horizon:
            self.err(r, "origin needs a current anchor and must not be after the horizon")
            return None
        if target["timeBase"] == "asap":
            return {"frame": horizon, "ticks": None, "retro": False}
        if target["timeBase"] == "sample":
            return {"frame": target["atFrame"], "ticks": None, "retro": False}
        if not self.musical_ok():
            self.err(r, "musical target without a current musical anchor")
            return None
        if "atTicks" in target:
            choice = {"frame": None, "ticks": target["atTicks"], "retro": False}
        else:
            grid, t = target["gridTicks"], self.ticks_at_frame(origin)
            prev, nxt = math.floor(t / grid) * grid, math.ceil(t / grid) * grid
            retro = Fraction(action["late"].get("retroactiveMs", 0) * self.rate(), 1000)
            choice = {"frame": None, "ticks": nxt, "retro": False}
            if prev != nxt and retro > 0 and origin - self.frame_of_ticks(prev) <= retro:
                choice = {"frame": None, "ticks": prev, "retro": True}
        if self.loop and not self.loop["startTicks"] <= choice["ticks"] <= self.loop["endTicks"]:
            self.err(r, "v1 resolves musical targets inside the active loop; loop end is the wrap frame")
        return choice

    def expected(self, info):
        e, late, horizon = info["expect"], info["action"]["late"], info["rec"]["horizonFrame"]
        assigned = e["frame"] if e["ticks"] is None else rnd(self.frame_of_ticks(e["ticks"]))
        if assigned >= horizon:
            return "fired", assigned, assigned
        within = (horizon - assigned) * 1000 <= late.get("maxLatenessMs", 0) * self.rate()
        policy = late["policy"]
        if policy in ("fireLate", "joinInProgress") and within:
            return ("firedLate" if policy == "fireLate" else "joined"), assigned, horizon
        grid = info["target"].get("gridTicks") or info["action"]["quantize"].get("gridTicks")
        if policy == "nextBoundary" and grid:
            ticks = math.ceil(self.ticks_at_frame(horizon) / grid) * grid
            while rnd(self.frame_of_ticks(ticks)) < horizon:
                ticks += grid
            return "fired", rnd(self.frame_of_ticks(ticks)), rnd(self.frame_of_ticks(ticks))
        return "dropped", assigned, None

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
        want, assigned, frame = self.expected(info)
        if result != want or r.get("assignedFrame") != assigned or r.get("frame") != frame:
            self.err(r, f"expected {want} assignedFrame={assigned} frame={frame}")
        if result == "dropped" and reason != "late":
            self.err(r, "a timing drop names reason late")
        if result == "joined" and r.get("startOffsetFrames") != frame - assigned:
            self.err(r, "joined outcome starts the source at frame - assignedFrame")
        if info["expect"]["ticks"] is not None and result != "dropped":
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
        if has != self.musical_ok() or has and rnd(self.ticks_at_frame(r["frame"])) != r["musicalTicks"]:
            self.err(r, "capture musicalTicks map from frame through the current musical anchor, exactly when one is")
        self.captures.append((r, words, (self.musical, self.map)))
        if r["effective"] == ep == "midi1" and mt in (2, 4):
            self.evidence.add("midi1InUmp")
        if r["effective"] == "midi2" and mt == 4:
            self.evidence.add("midi2Native")

    def under(self, snap, fn, *args):
        """fn against a (musical anchor, map) snapshot: capture time for SMF export, pre-restart for the resume tick."""
        live, (self.musical, self.map) = (self.musical, self.map), snap
        try:
            return fn(*args)
        finally:
            self.musical, self.map = live

    def smf_frame(self, snap, frame, step):
        """Frame an SMF tick at `step` resolution reconstructs through the capture-time musical anchor and map."""
        return self.under(snap, lambda: rnd(self.frame_of_ticks(rnd(self.ticks_at_frame(frame) / step) * step)))

    def on_export(self, r):
        events = [(c, w, snap) for c, w, snap in self.captures if c["stream"] in r["streams"]]
        if not events or len(set(r["streams"])) != len(r["streams"]) \
                or not all(self.stream_is(s, "midi", "capture") for s in r["streams"]):
            self.err(r, "export names distinct, declared MIDI capture streams with captured events")
        losses, native, origin = Counter(), r["format"] == "nativeUmp", r.get("origin", {})
        if set(r) & ({"division", "smfFormat"} if native else {"origin", "offsetsNs"}):
            self.err(r, "division and smfFormat are SMF-only; origin and offsetsNs are native-UMP-only")
        if native:
            anchor = self.first_anchor.get((origin.get("sampleClock"), origin.get("generation")))
            start = self.host_at(anchor, origin["frame"]) if anchor else None
            offsets = start is not None and [rnd((c["hostTicks"] - start) * self.ns_per_tick) for c, _, _ in events]
            if r.get("offsetsNs") != offsets:  # False (no recorded anchor) never matches
                self.err(r, "native UMP export keeps words verbatim and persists offsetsNs from its origin's recorded "
                            "anchor, never absolute host ticks")
        else:
            division = r.get("division", 0)
            if not division or TPQ % division or r.get("smfFormat") is None:
                self.err(r, "SMF export declares smfFormat and a division that divides 15360")
                return
            groups = {(w[0] >> 24) & 0xF for _, w, _ in events if w[0] >> 28 in GROUPED}
            for c, words, snap in events:
                mt = words[0] >> 28
                if "musicalTicks" not in c:
                    losses["syntheticTempoMap"] += 1
                elif self.smf_frame(snap, c["frame"], TPQ // division) != c["frame"]:
                    losses["timingQuantized"] += 1
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
            if i + 1 < len(segs) and ((segs[i + 1]["sampleClock"], segs[i + 1]["generation"]) != (clock, gen + 1)
                                      or end != restart.get("previousFrame")
                                      or segs[i + 1]["startFrame"] != restart.get("frame")):
                self.err(r, "segments split at each clock restart: ending at its previousFrame, resuming at its frame")
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


# (example, where, changes, error): each breaks one rule in a valid example and must fail with that rule's error.
# `where` is a timeline seq or a dotted document path; change keys are dotted paths under it; None deletes.
MUTATIONS = [
    ("01", 4, {"to": 3}, "advance the current value by exactly one"),
    ("01", 8, {"musicalTicks": 46080}, "resumes at the last rendered tick 92160"),
    ("01", 9, {"streamSeq": 41}, "stream order is preserved within a stream"),
    ("01", 6, {"reason": "transportRestart"}, "forces one transport bump with reason clockRestart"),
    ("01", 13, {"result": "dropped", "reason": "capacity"}, '.reason: "capacity" not in enum'),
    ("01", "actions.0", {"timePolicy": "timeStretch"}, "need a declared time-stretch adapter"),
    ("02", 9, {"result": "fired", "reason": None, "frame": 336000}, "expected dropped assignedFrame=336000"),
    ("02", 11, {"assignedFrame": 360000, "frame": 360000}, "expected fired assignedFrame=384000"),
    ("03", 2, {"type": "sampleJump"}, "loop iteration must follow a loopWrap"),
    ("03", 8, {"reason": "clockRestart"}, "forces one transport bump with reason clockRestart"),
    ("03", 10, {"result": "fired", "reason": None, "assignedFrame": 288000, "frame": 288000, "musicalMap": 1},
     "changed while pending: must be cancelled"),
    ("04", 5, {"musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}], "meter": None},
     "changes the tempo segments or the meter"),
    ("04", 7, {"assignedFrame": 288000, "frame": 288000}, "expected fired assignedFrame=268800"),
    ("04", 12, {"musicalTicks": 103680}, "capture musicalTicks map from frame"),
    ("05", 9, {"result": "fired", "reason": None, "assignedFrame": 192000, "frame": 192000, "musicalMap": 1},
     "changed while pending: must be cancelled"),
    ("06", 9, {"result": "fired", "reason": None}, "must be rejectedStale"),
    ("07", 3, {"result": "fired", "reason": None, "assignedFrame": 96000, "frame": 96000, "musicalMap": 1},
     "must be dropped with reason notReady"),
    ("07", 8, {"reason": None}, "failed and invalidated readiness states carry a reason"),
    ("08", 2, {"frame": 959900}, "lies wholly inside its segment"),
    ("08", 3, {"nominalRate": None}, "required on rateChange"),
    ("08", 8, {"droppedFrames": 0}, "no silent capture loss"),
    ("08", 8, {"segments.0.frames": 912000, "segments.1.fileFrameStart": 912000}, "ending at its previousFrame"),
    ("08", 8, {"stopReason": "user"}, "captureStopped matches its stopReason"),
    ("08", 9, {"reason": "diskFull"}, "captureStopped matches its stopReason"),
    ("08", "clocks.musical", {"musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}] * 2}, "strictly increase"),
    ("09", 2, {"ump": ["0x20903C64\n"]}, "violates length/pattern"),
    ("09", 4, {"effective": "midi2"}, "never the container's resolution"),
    ("09", 2, {"ump": ["0x30020102", "0x00000000"], "effective": "midi2"}, "never the container's resolution"),
    ("09", 6, {"endpointProtocol": "midi2", "translatedBy": "none", "effective": "midi2"}, "needs a formatChange"),
    ("09", 6, {"frame": 144001, "hostTicks": 2472000500}, "recomputed {'timingQuantized': 1}"),
    ("09", 12, {"origin.generation": 2}, "offsetsNs from its origin's recorded anchor"),
    ("10", "timeline", {"8.musicalTicks": None, "11.losses.syntheticTempoMap": 1}, "exactly when one is"),
    ("10", 2, {"portProtocol": "midi1", "translatedBy": "os"}, "MT 0x4 on a midi2 port"),
    ("10", 8, {"ump": ["0x22903C64"]}, "'groupsFlattened': 1"),
    ("10", 11, {"streams": ["str.synth", "str.missing"]}, "declared MIDI capture streams"),
    ("10", 11, {"origin.frame": 0}, "offsetsNs from its origin's recorded anchor"),
    ("10", 12, {"lossless": True, "losses": {}}, "must equal recomputed"),
]


def mutate(doc, where, changes):
    base = ["timeline", where - 1] if isinstance(where, int) else where.split(".")
    for key, value in changes.items():
        *path, last = base + key.split(".")
        node = doc
        for part in path:
            node = node[int(part)] if isinstance(node, list) else node[part]
        if value is None:
            node.pop(last, None)
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
        label = f"mutation {prefix} {'seq ' * isinstance(where, int)}{where}"
        try:
            mutate(doc, where, changes)
        except (KeyError, IndexError, TypeError, ValueError):
            errors.append(f"{label}: record missing")
            continue
        caught = any(expect in e for e in check_example(doc, name, schema)[0])
        print(f"{'ok  ' if caught else 'FAIL'} {label} rejected: {expect}")
        if not caught:
            errors.append(f"{label} did not fail with '{expect}'")
    for line in errors:
        print("error:", line)
    print(f"{len(files)} examples, {len(MUTATIONS)} mutations, {len(errors)} errors")
    return 1 if errors or not files else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
