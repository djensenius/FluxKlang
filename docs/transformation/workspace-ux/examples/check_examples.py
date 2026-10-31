#!/usr/bin/env python3
"""Well-formedness and consistency check for the synthetic workspace UX examples.

Stdlib only. Reads every *.json beside this file; never touches hardware, network or app state.
Usage: python3 docs/transformation/workspace-ux/examples/check_examples.py
"""
import json
import re
import sys
from pathlib import Path

PREFIXES = ("prj gph nod prt edg rol lay spk src pat var ast pst par grp bnd lrn rig dev ctl cap rte "
            "trn clk con clog cmd trc dft txn ses per lse win dgn").split()
ID_RE = re.compile(r"^(%s)\.[a-z0-9][a-z0-9.-]*$" % "|".join(PREFIXES))
REV_KEY = re.compile(r"^(?:expected|result|base|initialactive|active)?"
                     r"(project|graph|parameter|device|transport)revision(?:after)?$", re.I)
REV_CONTRACT = {"project": "project", "graph": "graph", "parameter": "parameter",
                "device": "deviceCapability", "transport": "transport"}
EXPECTED = {"project", "graph", "parameter", "deviceCapability", "transport", "command",
            "transactionTrace", "sessionStatus", "separateHostSession"}
OPS = {**dict.fromkeys(("connect", "disconnect", "addNode", "removeNode", "editDraft"), ("structural", "draftUpdated")),
       "requestActivation": ("structural", "reviewRequired"), "proposeDraft": ("proposal", "draftCreated"),
       "panic": ("safety", "accepted"), "safeMute": ("safety", "accepted"),
       "set:live": ("live", "accepted heldForPickup"), "set:hazardous": ("hazardous", "needsAuthorization")}
BINDING = {"present": "confirmed", "missing": "deviceMissing", "stale": "stale"}  # device presence -> route binding
ROUTE_STATE = {"confirmed": "mapped", "deviceMissing": "lostMuted", "stale": "stale"}  # route binding -> node state
ASSISTANT_ALLOWED = {"draft.propose", "diagnostics.read"}
PROVENANCE_TOOLS = {"routingRequest": "none", "diagnostic": "readOnlySnapshotTools"}
STEP_ORDER = ["validate", "prepare", "reviewAuthorize", "commit", "acknowledge"]
OUTCOMES = {"stale": "F", "rejected": "F", "prepareFailed": "OF", "awaitingReview": "OO", "committed": "OOOOO"}
errors = []


def err(where, message):
    errors.append(f"{where}: {message}")


def walk(value):
    """(key, leaf) pairs; items of a list keep the list's key."""
    for obj in objects(value):
        for k, v in obj.items():
            yield from ((k, x) for x in (v if isinstance(v, list) else [v]) if not isinstance(x, (dict, list)))


def objects(value):
    if isinstance(value, dict):
        yield value
        for v in value.values():
            yield from objects(v)
    elif isinstance(value, list):
        for item in value:
            yield from objects(item)


def check_history(where, obj):
    hist = obj.get("history")
    revs = [h.get("revision") if isinstance(h, dict) else None for h in hist] if isinstance(hist, list) else []
    if not revs or any(type(r) is not int for r in revs) or revs != sorted(set(revs)):
        err(where, f"history revisions must be strictly increasing integers: {revs}")
    elif revs[-1] != obj.get("revision") or type(obj.get("revision")) is not int:
        err(where, f"revision {obj.get('revision')} != last history revision {revs[-1]}")


def load_file(path, docs):
    doc = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        return err(path.name, "top level must be a JSON object")
    if doc.get("synthetic") is not True:
        err(path.name, "must declare synthetic: true")
    for field in ("contract", "schemaVersion", "id", "revision", "history"):
        if field not in doc:
            err(path.name, f"missing {field}")
    for obj in objects(doc):
        if "history" in obj:
            check_history(f"{path.name} {obj.get('id', '')}".strip(), obj)
    name = doc.get("contract")
    if not isinstance(name, str) or name in docs:
        return err(path.name, f"contract must be a unique string, got {name!r}"
                   + (f" (also in {docs[name]['_file']})" if isinstance(name, str) else ""))
    doc["_file"] = path.name
    docs[name] = doc


def load():
    docs = {}
    for path in sorted(Path(__file__).parent.glob("*.json")):
        guarded(path.name, load_file, path, docs)
    if EXPECTED - set(docs):
        err("examples", f"missing contracts: {sorted(EXPECTED - set(docs))}")
    return docs


def check_ids_and_revisions(docs):
    defined = {}
    for name, doc in docs.items():
        for obj in objects(doc):
            for key in ("id", "proposedId"):
                value = obj.get(key)
                if isinstance(value, str):
                    if not ID_RE.match(value):
                        err(name, f"id {value!r} lacks a known synthetic prefix")
                    elif value in defined:
                        err(name, f"duplicate id {value} (also in {defined[value]})")
                    defined[value] = name
    history = {n: {h["revision"]: h for h in d.get("history", [])} for n, d in docs.items()}
    for name, doc in docs.items():
        for key, value in walk(doc):
            ref = value.split(":")[-1] if isinstance(value, str) and key not in ("id", "proposedId") else ""
            if ID_RE.match(ref) and ref not in defined:
                err(name, f"{key} references undefined id {value}")
        for obj in objects(doc):
            for key, value in obj.items():
                match = REV_KEY.match(key)
                contract = match and REV_CONTRACT[match.group(1).lower()]
                if match and (type(value) is not int or value not in history.get(contract, {})):
                    err(name, f"{key}={value!r} must be an integer revision in {contract} history")
    return defined, history


def compatible(ports, edge):
    """Why an edge or connect op is invalid, else "ok"; feedback must declare a causal one-block delay."""
    src, dst, fb, conversion = (ports.get(edge["from"]), ports.get(edge["to"]),
                                edge.get("feedback"), edge.get("conversion"))
    if "feedback" in edge and not (isinstance(fb, dict) and fb.get("delay") == "oneBlock"
                                   and type(fb.get("gainCeilingDb")) in (int, float) and fb["gainCeilingDb"] <= 0):
        return "feedbackNeedsOneBlockDelayAndGainCeilingDb<=0"
    if not src or not dst or src["dir"] != "out" or dst["dir"] != "in":
        return "direction" if src and dst else "portNotInGraph"
    if src["signal"] != dst["signal"]:
        return "signalMismatch"
    if conversion:  # a row per destination channel; an empty row is silent, but some row must carry signal
        rows, width = conversion.get("map"), src.get("channels") or 0
        if (not isinstance(rows, list) or len(rows) != dst.get("channels") or not any(rows)
                or any(not isinstance(row, list) or any(type(i) is not int or not 0 <= i < width for i in row)
                       for row in rows)):
            return "badConversion"
    elif src.get("channels") != dst.get("channels"):
        return "channelMismatch"
    return "ok"


def faults(ports, edges):
    """Edge verdicts, "duplicate" wires, and "cycle" when non-feedback links loop (peel links into exitless nodes)."""
    links = {(ports[e["from"]]["node"], ports[e["to"]]["node"]) for e in edges
             if "feedback" not in e and compatible(ports, e) == "ok"}
    while links and (sinks := {b for _, b in links} - {a for a, _ in links}):
        links = {(a, b) for a, b in links if b not in sinks}
    keys = [(e["from"], e["to"]) for e in edges] + [x for e in edges if (x := e.get("id") or e.get("edge"))]
    return ({compatible(ports, e) for e in edges} - {"ok"} | ({"cycle"} if links else set())
            | ({"duplicate"} if len(set(keys)) < len(keys) else set()))


def candidate(ports, graph, draft, replay=False):
    """Ports and edges after a draft's ops; removed nodes take their ports, so connects to them dangle."""
    cut = {op.get("edge") or op.get("node") for op in draft["ops"] if op["op"] in ("disconnect", "removeNode")}
    left = {k: p for k, p in ports.items() if p["node"] not in cut}
    keep = [e for e in graph["edges"] if e["id"] not in cut and e["from"] in left and e["to"] in left]
    kept = {e["id"]: shape(e) for e in keep if replay}  # only a history-cited commit may re-state its live edge
    return left, keep + [op for op in draft["ops"] if op["op"] == "connect" and kept.get(op.get("edge")) != shape(op)]


def check_graph(graph):
    nodes = {n["id"] for n in graph["nodes"]}
    for port in graph["ports"]:
        if port["node"] not in nodes:
            err("graph", f"{port['id']} belongs to {port['node']}, which is not a node of this graph")
    ports = {p["id"]: p for p in graph["ports"] if p["node"] in nodes}  # edge and cycle code see only these
    defined = {c["id"] for c in graph["capabilities"]}
    required, advisory = set(graph["requiredCapabilities"]), set(graph["advisoryCapabilities"])
    if not required | advisory <= defined or required & advisory:
        err("graph", "graph capabilities must be defined once and be either required or advisory")
    for node in graph["nodes"]:
        if node.get("routable") is False and any(p["node"] == node["id"] for p in graph["ports"]):
            err("graph", f"{node['id']} is non-routable but has ports")
        if not set(node.get("requiredCapabilities", [])) <= required or \
                not set(node.get("advisoryCapabilities", [])) <= advisory:
            err("graph", f"{node['id']} capability level differs from the graph level")
    for edge in graph["edges"]:
        if (verdict := compatible(ports, edge)) != "ok":
            err("graph", f"{edge['id']} is invalid: {verdict}")
    if found := faults(ports, graph["edges"]) & {"cycle", "duplicate"}:
        err("graph", f"{sorted(found)}: loops need explicit causal feedback and each from/to pair is wired once")
    return ports


def host_sessions(docs):
    """Each host session: one authority over its own live graph, rig, lease, epoch, logs and drafts."""
    phone, epochs, a = docs["separateHostSession"], docs["transport"]["epochs"], docs["sessionStatus"]
    return [{"name": a["id"], "session": a, "rig": docs["deviceCapability"], "logs": docs["command"]["logs"],
             "hostEpoch": {h["host"]: h["hostEpoch"] for h in epochs["hosts"]}.get(a["host"]),
             "connections": {c["id"]: c["connectionEpoch"] for c in epochs["connections"]},
             "trace": docs["transactionTrace"]},
            {"name": phone["id"], "session": phone, "rig": phone["rig"], "logs": [phone["commandLog"]],
             "hostEpoch": phone["transport"]["hostEpoch"], "connections": {}, "trace": phone["trace"]}]


def check_authority(hs):
    session, rig, where, host = hs["session"], hs["rig"], hs["name"], hs["session"]["host"]
    hosts = [p["id"] for p in session["participants"] if p["role"] == "host"]
    owners = {session["lease"]["holder"], rig["host"], hs["trace"]["authority"]} | {log["host"] for log in hs["logs"]}
    if hosts != [host] or owners != {host}:
        err(where, f"exactly one host authority expected, found hosts {hosts} and owners {sorted(owners)}")
    members = {p["id"] for p in session["participants"]}
    for draft in hs["trace"]["drafts"]:
        if draft["host"] != host or draft["author"] not in members:
            err(draft["id"], "drafts belong to the session that holds the live graph")
    presence = {d["id"]: d["presence"] for d in rig["devices"]}
    for item in rig["routes"] + rig.get("proposedRoutes", []):
        want = "proposed" if item in rig.get("proposedRoutes", []) else BINDING.get(presence.get(item["device"]))
        if item["device"] not in presence or item["binding"] != want:
            err(item["id"], "routes use only this host's own rig (rigs are not synced), bound per device presence")
    routed = [r["role"] for r in rig["routes"]]
    if len(set(routed)) < len(routed) or set(routed) & set(rig.get("unmappedRoles", [])):
        err(where, "each role has at most one route and is either routed or unmapped")
    for cap in rig["capabilities"]:
        live = any(p == host or presence.get(p) == "present" for p in cap["providedBy"])
        if not set(cap["providedBy"]) <= set(presence) | {host} or live != (cap["status"] == "available"):
            err(where, f"{cap['capability']} needs this rig's providers and is available only while one is present")


def shape(edge):  # what a committed connect must reproduce: endpoints, conversion map, feedback delay and ceiling
    fb = edge.get("feedback")
    return (edge.get("from"), edge.get("to"), (edge.get("conversion") or {}).get("map"),
            (fb.get("delay"), fb.get("gainCeilingDb")) if isinstance(fb, dict) else fb)


def check_ops_applied(graph, draft, where):
    edges, nodes = graph["edges"], {n["id"] for n in graph["nodes"]}
    for op in draft["ops"]:
        kind = op["op"]
        hit = [e["id"] for e in edges if shape(e) == shape(op)]
        if ((kind == "connect" and (not hit or op.get("edge", hit[0]) != hit[0]))
                or (kind == "disconnect" and any(e["id"] == op["edge"] for e in edges))
                or (kind == "addNode" and op["proposedId"] not in nodes)
                or (kind == "removeNode" and op["node"] in nodes)
                or kind not in ("connect", "disconnect", "addNode", "removeNode")):
            err(where, f"committed op is not reflected in the graph: {op}")


def check_provenance(hs, draft, roles):
    people = {p["id"]: p for p in hs["session"]["participants"]}
    if people.get(draft["author"], {}).get("role") != "assistant":
        return
    origin = (prov := draft.get("provenance", {})).get("origin")
    if prov.get("kind") != "assistantProposal" or PROVENANCE_TOOLS.get(origin, object()) != prov.get("toolUse"):
        err(draft["id"], "assistant drafts need provenance whose origin matches its tool use")
    if origin == "diagnostic":
        diag = next((d for d in hs["session"].get("diagnostics", []) if d["id"] == prov.get("diagnostic")), {})
        if diag.get("assistant") != "explainOrProposeDraft" or "diagnostics.read" not in roles["assistant"]:
            err(draft["id"], "diagnostic-originated drafts must cite a readable diagnostic of this session")


def check_transactions(hs, graph, history, ports, roles):
    trace, people = hs["trace"], {p["id"]: p for p in hs["session"]["participants"]}
    drafts = {d["id"]: d for d in trace["drafts"]}
    if trace.get("stepOrder", STEP_ORDER) != STEP_ORDER:
        err(hs["name"], f"step order must be {STEP_ORDER}")
    active, last_seq, used = trace["initialActiveGraphRevision"], 0, set()
    for draft in drafts.values():
        check_provenance(hs, draft, roles)
    for txn in trace["transactions"]:
        where, draft, outcome = txn["id"], drafts[txn["draft"]], txn["outcome"]
        used.add(draft["id"])
        base, steps = draft["baseGraphRevision"], txn["steps"]
        names = [s["step"] for s in steps]
        results = "".join({"ok": "O", "failed": "F"}.get(s["result"], "?") for s in steps)  # O = ok, F = failed
        if names != STEP_ORDER[:len(names)] or OUTCOMES.get(outcome) != results:
            err(where, f"steps {names} with results {results!r} do not lead to outcome {outcome}")
        if txn.get("pending") != ("reviewAuthorize" if outcome == "awaitingReview" else None):
            err(where, "only awaitingReview is pending, and it is pending reviewAuthorize")
        commit, ack = (next((s for s in steps if s["step"] == k), {}) for k in ("commit", "acknowledge"))
        made = commit.get("resultGraphRevision")
        cited = outcome == "committed" and history["graph"].get(made, {}).get("transaction") == where
        validate, stale = (steps or [{}])[0], base != active
        if not (stale == (outcome == "stale") == (validate.get("code") == "staleBase")):
            err(where, f"base {base} vs active {active}: stale handling inconsistent")
        found = set() if stale else faults(*candidate(ports, graph, draft, cited))
        if found and (validate.get("result") != "failed" or validate.get("code") not in found):
            err(where, f"validate must fail with one of {sorted(found)}")
        for step in steps:
            if type(step["seq"]) is not int or step["seq"] <= last_seq:
                err(where, f"seq {step['seq']} is not monotonic")
            last_seq = step["seq"]
            if step["step"] == "reviewAuthorize":
                who = people.get(step.get("authorizedBy"), {})
                if "activation.authorize" not in roles.get(who.get("role"), []):
                    err(where, f"{step.get('authorizedBy')} may not authorize activation")
                bound = step.get("boundTo", {})
                if (bound.get("draft") != txn["draft"] or bound.get("baseGraphRevision") != base
                        or bound.get("hostEpoch") != hs["hostEpoch"]
                        or not draft.get("diffDigest") or bound.get("diffDigest") != draft["diffDigest"]):
                    err(where, "authorization is not bound to this draft, base, host epoch and diff digest")
        if outcome == "committed":
            if made != base + 1 or not cited:
                err(where, f"commit must produce base + 1 and graph history {made} must cite this transaction")
            active = commit.get("resultGraphRevision", active)
            if history["project"].get(ack.get("resultProjectRevision"), {}).get("transaction") != where:
                err(where, "project history does not cite this acknowledgement")
            if active == graph["revision"]:
                check_ops_applied(graph, draft, where)
        elif txn.get("activeGraphRevisionAfter") != active:
            err(where, "uncommitted transactions must leave the active revision unchanged")
    for draft in drafts.values():
        if draft["id"] not in used and draft["baseGraphRevision"] == active and (
                found := faults(*candidate(ports, graph, draft))):
            err(draft["id"], f"reviewable draft fails validation: {sorted(found)}")
    if active != graph["revision"]:
        err(hs["name"], f"final active revision {active} != graph revision {graph['revision']}")


def within(param, value):
    """A settable value is a number from min up to the ceiling (max when no ceiling is set)."""
    return type(value) in (int, float) and param["min"] <= value <= param.get("ceiling", param["max"])


def check_commands(hs, roles, docs):
    people = {p["id"]: p for p in hs["session"]["participants"]}
    params = {p["id"]: p for p in docs["parameter"]["parameters"]}
    bindings = {b["id"]: b for b in docs["parameter"]["bindings"]}
    perms = {c["name"]: c["permission"] for c in docs["command"]["classes"]}
    controls = {c["id"]: c["device"] for c in hs["rig"].get("controls", [])}
    present = {d["id"] for d in hs["rig"]["devices"] if d["presence"] == "present"}
    drafts = {d["id"]: d for d in hs["trace"]["drafts"]}
    for log in hs["logs"]:
        last_seq = 0
        if log["hostEpoch"] != hs["hostEpoch"]:
            err(log["host"], "log hostEpoch differs from the session's host epoch")
        for cmd in log["commands"]:
            where, status, op = cmd["id"], cmd["result"]["status"], cmd["op"]
            if type(cmd["seq"]) is not int or cmd["seq"] <= last_seq:
                err(where, "seq is not monotonic")
            last_seq = cmd["seq"]
            origin, binding = people.get(cmd["origin"]), bindings.get(cmd["origin"], {})
            if origin is None:
                if (binding.get("state") != "active" or controls.get(binding.get("control")) not in present
                        or op.get("set") != binding.get("parameter")):
                    err(where, "origin must be a session member or an active binding on this rig setting its target")
                    continue
                origin = people[log["host"]]
            target = params.get(op.get("set"), {})
            kinds = {OPS.get(f"set:{target.get('class')}" if k == "set" else k) for k in op if k != "value"}
            if len(kinds) != 1 or None in kinds or (want := kinds.pop())[0] != cmd["class"]:
                err(where, f"class {cmd['class']} does not fit operation {sorted(op)} (class policy table)")
                continue
            draft = drafts.get(op.get("editDraft") or op.get("requestActivation") or op.get("proposeDraft"))
            if want[0] in ("structural", "proposal") and not status.startswith("rejected") and (
                    not draft or ("connect" in op and shape(op["connect"]) not in map(shape, draft["ops"]))
                    or ("proposeDraft" in op and draft["author"] != cmd["origin"])):
                err(where, "a draft command names this session's draft (a proposal, its own) and matches its ops")
            value = op.get("value")
            if "set" in op and not status.startswith("rejected") and not within(target, value):
                err(where, f"value {value!r} is outside {target['id']} min..ceiling, so it cannot be {status}")
            conn = origin.get("connection")
            stale = cmd.get("hostEpoch") != log["hostEpoch"] or (
                conn is not None and cmd.get("connectionEpoch") != hs["connections"].get(conn))
            if stale:
                if status != "rejectedStaleEpoch":
                    err(where, "stale epoch must be rejected, whatever the class")
                continue
            granted, need = roles.get(origin["role"], []), perms[cmd["class"]]
            ok = (need in granted or (need == "live.set" and f"live.set:{target.get('group')}" in granted)
                  or (need == "safety" and any(g.startswith("safety.") for g in granted)))
            expected, pick = set(want[1].split()) if ok else {"rejectedPermission"}, binding.get("pickup", {})
            if ok and cmd["class"] == "live":  # a waiting catch holds values still on the hardware's side of the target
                aim = pick.get("parameterValue")
                hold = pick.get("state") == "waiting" and (value - aim) * (pick["hardwareValue"] - aim) > 0
                expected = {"heldForPickup"} if hold else {"accepted"}
            if status not in expected:
                err(where, f"status {status} not in {sorted(expected)} for this class, permission and pickup")
            if origin["role"] == "assistant" and status not in ("draftCreated", "rejectedPermission"):
                err(where, "assistant commands may only create review drafts")
            res, exp = cmd["result"].get("resultParameterRevision"), cmd.get("expectedParameterRevision")
            if res is not None and exp is not None and res != exp + 1:
                err(where, "accepted live change must advance parameter revision by one")


def check_roles(docs):
    session, roles = docs["sessionStatus"], docs["sessionStatus"]["roles"]
    if not {"safety.panic", "safety.safeMute"} <= set(roles["host"]):
        err("host", "Panic and Safe Mute must stay reachable in every host UI")
    if not set(roles["assistant"]) <= ASSISTANT_ALLOWED:
        err("assistant", f"assistant may only hold {sorted(ASSISTANT_ALLOWED)}")
    for a in session["layoutAdaptations"]:
        if set(a) - {"formFactor", "layout"}:
            err("session", "layout adaptations may not carry permissions or roles")
    return roles, {a["formFactor"] for a in session["layoutAdaptations"]}


def check_session(hs, roles, forms, graph):
    session, rig, where = hs["session"], hs["rig"], hs["name"]
    for p in session["participants"]:
        if p["role"] not in roles or "permissions" in p:
            err(p["id"], "permissions must come only from a defined role")
        if p["formFactor"] != "none" and p["formFactor"] not in forms:
            err(p["id"], "form factor has no layout adaptation")
        if p["role"] == "remoteController" and (p.get("opensAudioEngine") is not False
                                                or p.get("opensConsoleWriteSession") is not False):
            err(p["id"], "remote controllers open no audio engine and no console write session")
    lease = session["lease"]
    host_windows = {w["id"] for w in session["windows"] if w["host"] == lease["holder"]}
    if set(lease["windows"]) != host_windows:
        err(where, "one lease must cover every window of the holder")
    own = {x["id"] for k in ("routes", "proposedRoutes", "devices", "controls") for x in rig.get(k, [])}
    for key, value in walk([session.get(k) for k in ("nodeStatus", "telemetry", "diagnostics")]):
        if str(value).split(".")[0] in ("rte", "dev", "ctl") and value not in own:
            err(where, f"{key} {value} is not in this host's own rig")
    local = {r["id"]: r["binding"] for r in rig["routes"] + rig.get("proposedRoutes", [])}
    for t in session["telemetry"]:
        if t["source"] != "measured" and t["display"] != "Unavailable":
            err(t["target"], "non-measured telemetry must display Unavailable")
        if t["source"] == "measured" and (t.get("lease") != lease["id"] or lease["state"] != "running"
                                          or local.get(t["target"], "confirmed") != "confirmed"):
            err(t["target"], "measured telemetry requires the running engine lease and a confirmed route")
    caps = {c["capability"]: c["status"] for c in rig["capabilities"]}
    if lease["state"] == "running" and any(caps.get(c) != "available" for c in graph["requiredCapabilities"]):
        err(where, "a running lease needs every required graph capability available")
    routes, unmapped = {r["role"]: r for r in rig["routes"]}, rig.get("unmappedRoles", [])
    status = {s["node"]: s for s in session["nodeStatus"]}
    if len(status) != len(session["nodeStatus"]) or set(status) != {n["id"] for n in graph["nodes"]}:
        err(where, "exactly one status per active graph node")
    for node in graph["nodes"]:  # Wiring's state table, derived from this host's rig and capabilities
        role, needs = node.get("role"), node.get("requiredCapabilities", []) + node.get("advisoryCapabilities", [])
        route = None if role in unmapped else routes.get(role)
        want = ("unmapped" if role in unmapped else ROUTE_STATE.get(route["binding"]) if route else None if role
                else "missing" if any(caps.get(c) == "missing" for c in needs)
                else "stale" if node.get("routable") is False else "ready")
        got = status.get(node["id"], {})
        if want is None or (got.get("state"), got.get("route")) != (want, route and route["id"]):
            err(f"{where} {node['id']}", f"status must be {want or 'routed or unmapped'} via {route and route['id']}")


def check_parameters(docs):
    params = {p["id"]: p for p in docs["parameter"]["parameters"]}
    presence = {d["id"]: d["presence"] for d in docs["deviceCapability"]["devices"]}
    control_device = {c["id"]: c["device"] for c in docs["deviceCapability"]["controls"]}
    nodes = {n["id"] for n in docs["graph"]["nodes"]}
    removals = {(d["id"], op.get("node")) for t in (docs["transactionTrace"], docs["separateHostSession"]["trace"])
                for d in t["drafts"] for op in d["ops"] if op["op"] == "removeNode"}
    for p in params.values():
        if not (p["min"] <= p.get("ceiling", p["max"]) <= p["max"] and within(p, p["value"])):
            err(p["id"], f"need min <= value <= ceiling <= max (value {p['value']!r}, ceiling {p.get('ceiling')})")
        if (p.get("control") == "noTarget") != (p["node"] not in nodes):
            err(p["id"], "a control has no target only once its node leaves the active graph, never for a draft")
        if "pendingRemoval" in p and ((p["pendingRemoval"], p["node"]) not in removals or p["node"] not in nodes):
            err(p["id"], "a pending-removal hint must cite a draft removing this live parameter's node")
    for b in docs["parameter"]["bindings"]:
        present = presence.get(control_device.get(b["control"])) == "present"
        if (b.get("state") == "active") != present or (not present and b["pickup"]["state"] != "unavailable"):
            err(b["id"], "binding state and pickup must reflect whether its device is present")
    for lrn in docs["parameter"]["learn"]:
        if params[lrn["proposedParameter"]].get("learnExcludedByDefault") and lrn["state"] != "blocked":
            err(lrn["id"], "excluded targets must be blocked from Learn by default")
        if lrn["state"] != "blocked" and presence.get(control_device.get(lrn["control"])) != "present":
            err(lrn["id"], "Learn can only hear a present device")


def guarded(name, fn, *args):
    try:
        return fn(*args)
    except (KeyError, TypeError, AttributeError, IndexError, ValueError) as exc:
        err(name, f"malformed input ({type(exc).__name__}: {exc})")
        return None


def main():
    docs = load()
    defined, sessions = {}, []
    if not errors:
        defined, history = guarded("ids", check_ids_and_revisions, docs) or ({}, {})
        ports = guarded("graph", check_graph, docs["graph"]) or {}
        roles, forms = guarded("roles", check_roles, docs) or ({}, set())
        sessions = guarded("sessions", host_sessions, docs) or []
        if not guarded("examples", lambda: any(p["id"] == s["session"]["host"] and p["formFactor"] == "phone"
                                               for s in sessions for p in s["session"]["participants"])):
            err("examples", "examples must include a phone running as a full host session")
        for hs in sessions:
            guarded(hs["name"], check_authority, hs)
            guarded(hs["name"], check_transactions, hs, docs["graph"], history, ports, roles)
            guarded(hs["name"], check_commands, hs, roles, docs)
            guarded(hs["name"], check_session, hs, roles, forms, docs["graph"])
        guarded("parameters", check_parameters, docs)
    if errors:
        print("\n".join(f"FAIL {e}" for e in errors))
        return 1
    print(f"OK: {len(docs)} contracts, {len(defined)} synthetic ids, {len(sessions)} host sessions, "
          "all references and revisions consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
