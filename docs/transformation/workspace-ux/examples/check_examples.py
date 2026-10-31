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
ALLOWED = {"live": {"accepted", "heldForPickup"}, "structural": {"draftUpdated", "reviewRequired"},
           "hazardous": {"needsAuthorization"}, "safety": {"accepted"}, "proposal": {"draftCreated"}}
ASSISTANT_ALLOWED = {"draft.propose", "diagnostics.read"}
PROVENANCE_TOOLS = {"routingRequest": "none", "diagnostic": "readOnlySnapshotTools"}
STEP_ORDER = ["validate", "prepare", "reviewAuthorize", "commit", "acknowledge"]
errors = []


def err(where, message):
    errors.append(f"{where}: {message}")


def walk(value, key=None):
    if isinstance(value, dict):
        for k, v in value.items():
            yield from walk(v, k)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item, key)
    else:
        yield key, value


def objects(value):
    if isinstance(value, dict):
        yield value
        for v in value.values():
            yield from objects(v)
    elif isinstance(value, list):
        for item in value:
            yield from objects(item)


def check_history(where, obj):
    revs = [h.get("revision") if isinstance(h, dict) else None for h in obj.get("history") or []]
    if not revs or any(not isinstance(r, int) for r in revs) or revs != sorted(set(revs)):
        err(where, f"history revisions must be strictly increasing integers: {revs}")
    elif revs[-1] != obj.get("revision"):
        err(where, f"revision {obj.get('revision')} != last history revision {revs[-1]}")


def load():
    docs = {}
    for path in sorted(Path(__file__).parent.glob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            err(path.name, f"invalid JSON: {exc}")
            continue
        if not isinstance(doc, dict):
            err(path.name, "top level must be a JSON object")
            continue
        if doc.get("synthetic") is not True:
            err(path.name, "must declare synthetic: true")
        for field in ("contract", "schemaVersion", "id", "revision", "history"):
            if field not in doc:
                err(path.name, f"missing {field}")
        for obj in objects(doc):
            if "history" in obj:
                check_history(f"{path.name} {obj.get('id', '')}".strip(), obj)
        name = doc.get("contract")
        if name in docs:
            err(path.name, f"duplicate contract {name!r} (also in {docs[name]['_file']})")
            continue
        doc["_file"] = path.name
        docs[name] = doc
    missing = EXPECTED - set(docs)
    if missing:
        err("examples", f"missing contracts: {sorted(missing)}")
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
            if key in ("id", "proposedId"):
                continue
            if isinstance(value, str) and ID_RE.match(value) and value not in defined:
                err(name, f"{key} references undefined id {value}")
            if isinstance(value, str) and ":" in value and value.split(":")[-1] not in defined:
                if ID_RE.match(value.split(":")[-1]):
                    err(name, f"scoped reference {value} names an undefined id")
            match = REV_KEY.match(key or "")
            if match and isinstance(value, int):
                contract = REV_CONTRACT[match.group(1).lower()]
                if value not in history.get(contract, {}):
                    err(name, f"{key}={value} is not a revision in {contract} history")
    return defined, history


def compatible(ports, src_id, dst_id, conversion):
    src, dst = ports.get(src_id), ports.get(dst_id)
    if not src or not dst or src["dir"] != "out" or dst["dir"] != "in":
        return "direction"
    if src["signal"] != dst["signal"]:
        return "signalMismatch"
    if conversion:
        rows, width = conversion.get("map"), src.get("channels") or 0
        if (not isinstance(rows, list) or len(rows) != dst.get("channels")
                or any(not row or any(not isinstance(i, int) or not 0 <= i < width for i in row) for row in rows)):
            return "badConversion"
    elif src.get("channels") != dst.get("channels"):
        return "channelMismatch"
    return "ok"


def check_graph(graph):
    ports = {p["id"]: p for p in graph["ports"]}
    nodes = {n["id"]: n for n in graph["nodes"]}
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
    adjacency = {n: set() for n in nodes}
    for edge in graph["edges"]:
        verdict, fb = compatible(ports, edge["from"], edge["to"], edge.get("conversion")), edge.get("feedback")
        causal = (isinstance(fb, dict) and fb.get("delay") == "oneBlock"
                  and type(fb.get("gainCeilingDb")) in (int, float) and fb["gainCeilingDb"] <= 0)
        if "feedback" in edge and not causal:
            err("graph", f"{edge['id']} feedback needs a oneBlock delay and gainCeilingDb <= 0")
        if verdict != "ok":
            err("graph", f"{edge['id']} is invalid: {verdict}")
        elif not causal:
            adjacency[ports[edge["from"]]["node"]].add(ports[edge["to"]]["node"])
    state = {}

    def visit(n):
        state[n] = "open"
        for m in adjacency[n]:
            if state.get(m) == "open" or (m not in state and visit(m)):
                return True
        state[n] = "done"
        return False
    if any(n not in state and visit(n) for n in nodes):
        err("graph", "cycle without an explicit feedback edge")
    return ports


def host_sessions(docs):
    """Each host session: one authority over its own live graph, rig, lease, epoch, logs and drafts."""
    phone, transport = docs["separateHostSession"], docs["transport"]
    session_a = docs["sessionStatus"]
    epochs = {h["host"]: h["hostEpoch"] for h in transport["epochs"]["hosts"]}
    return [
        {"name": session_a["id"], "session": session_a, "rig": docs["deviceCapability"],
         "hostEpoch": epochs.get(session_a["host"]), "logs": docs["command"]["logs"],
         "connections": {c["id"]: c["connectionEpoch"] for c in transport["epochs"]["connections"]},
         "trace": docs["transactionTrace"]},
        {"name": phone["id"], "session": phone, "rig": phone["rig"], "hostEpoch": phone["transport"]["hostEpoch"],
         "logs": [phone["commandLog"]], "connections": {}, "trace": phone["trace"]},
    ]


def check_authority(hs):
    session, rig, where = hs["session"], hs["rig"], hs["name"]
    host = session["host"]
    hosts = [p["id"] for p in session["participants"] if p["role"] == "host"]
    owners = {session["lease"]["holder"], rig["host"], hs["trace"]["authority"]} | {log["host"] for log in hs["logs"]}
    if hosts != [host] or owners != {host}:
        err(where, f"exactly one host authority expected, found hosts {hosts} and owners {sorted(owners)}")
    members = {p["id"] for p in session["participants"]}
    for draft in hs["trace"]["drafts"]:
        if draft["host"] != host or draft["author"] not in members:
            err(draft["id"], "drafts belong to the session that holds the live graph")
    devices = {d["id"] for d in rig["devices"]}
    for item in rig["routes"] + rig.get("proposedRoutes", []):
        if item["device"] not in devices:
            err(item["id"], "routes may only use this host's own rig (rigs are not synced)")
    for cap in rig["capabilities"]:
        if not set(cap["providedBy"]) <= devices | {host}:
            err(where, f"{cap['capability']} is provided by another host's device")


def check_ops_applied(graph, draft, where):
    edges, nodes = graph["edges"], {n["id"] for n in graph["nodes"]}
    for op in draft["ops"]:
        kind = op["op"]
        if kind == "connect":
            hit = [e for e in edges if e["from"] == op["from"] and e["to"] == op["to"]
                   and e.get("conversion", {}).get("map") == op.get("conversion", {}).get("map")]
            if not hit or ("edge" in op and hit[0]["id"] != op["edge"]):
                err(where, f"committed connect {op['from']} -> {op['to']} is not in the graph")
        elif kind == "disconnect" and any(e["id"] == op["edge"] for e in edges):
            err(where, f"committed disconnect left {op['edge']} in the graph")
        elif kind == "addNode" and op["proposedId"] not in nodes:
            err(where, f"committed addNode {op['proposedId']} is not in the graph")
        elif kind not in ("connect", "disconnect", "addNode"):
            err(where, f"unknown draft op {kind!r}")


def check_provenance(hs, draft, roles):
    people = {p["id"]: p for p in hs["session"]["participants"]}
    if people.get(draft["author"], {}).get("role") != "assistant":
        return
    prov = draft.get("provenance", {})
    origin = prov.get("origin")
    if prov.get("kind") != "assistantProposal" or PROVENANCE_TOOLS.get(origin, object()) != prov.get("toolUse"):
        err(draft["id"], "assistant drafts need provenance whose origin matches its tool use")
    if origin == "diagnostic":
        diag = next((d for d in hs["session"].get("diagnostics", []) if d["id"] == prov.get("diagnostic")), {})
        if diag.get("assistant") != "explainOrProposeDraft" or "diagnostics.read" not in roles["assistant"]:
            err(draft["id"], "diagnostic-originated drafts must cite a readable diagnostic of this session")


def check_transactions(hs, graph, history, ports, roles):
    trace = hs["trace"]
    people = {p["id"]: p for p in hs["session"]["participants"]}
    drafts = {d["id"]: d for d in trace["drafts"]}
    if trace.get("stepOrder", STEP_ORDER) != STEP_ORDER:
        err(hs["name"], f"step order must be {STEP_ORDER}")
    order = STEP_ORDER
    active, last_seq, used = trace["initialActiveGraphRevision"], 0, set()
    for draft in drafts.values():
        check_provenance(hs, draft, roles)
    for txn in trace["transactions"]:
        where, draft = txn["id"], drafts[txn["draft"]]
        used.add(draft["id"])
        base, steps = draft["baseGraphRevision"], txn["steps"]
        if not steps:
            err(where, "transaction has no steps")
            continue
        names = [s["step"] for s in steps]
        if names != order[:len(names)]:
            err(where, f"steps {names} do not follow {order}")
        for i, step in enumerate(steps):
            if step["seq"] <= last_seq:
                err(where, f"seq {step['seq']} is not monotonic")
            last_seq = step["seq"]
            if step["result"] == "failed" and i != len(steps) - 1:
                err(where, "steps continue after a failure")
        validate = steps[0]
        stale = base != active
        if stale != (validate.get("code") == "staleBase") or (stale and validate["result"] != "failed"):
            err(where, f"base {base} vs active {active}: stale handling inconsistent")
        verdicts = {compatible(ports, op["from"], op["to"], op.get("conversion"))
                    for op in draft["ops"] if op["op"] == "connect"} - {"ok"}
        if not stale and verdicts and validate.get("code") not in verdicts:
            err(where, f"validate should fail with {sorted(verdicts)}")
        for step in steps:
            if step["step"] == "reviewAuthorize":
                who = people.get(step.get("authorizedBy"), {})
                if "activation.authorize" not in roles.get(who.get("role"), []):
                    err(where, f"{step.get('authorizedBy')} may not authorize activation")
                bound = step.get("boundTo", {})
                if (bound.get("draft") != txn["draft"] or bound.get("baseGraphRevision") != base
                        or bound.get("hostEpoch") != hs["hostEpoch"]
                        or not draft.get("diffDigest") or bound.get("diffDigest") != draft["diffDigest"]):
                    err(where, "authorization is not bound to this draft, base, host epoch and diff digest")
        if txn["outcome"] == "committed":
            commit = next((s for s in steps if s["step"] == "commit"), {})
            ack = next((s for s in steps if s["step"] == "acknowledge"), {})
            if names != order or any(s["result"] != "ok" for s in steps):
                err(where, "committed transactions need every step ok")
            if commit.get("resultGraphRevision") != base + 1:
                err(where, "commit must produce base + 1")
            active = commit.get("resultGraphRevision", active)
            if history["graph"].get(active, {}).get("transaction") != where:
                err(where, f"graph history {active} does not cite this transaction")
            if history["project"].get(ack.get("resultProjectRevision"), {}).get("transaction") != where:
                err(where, "project history does not cite this acknowledgement")
            if active == graph["revision"]:
                check_ops_applied(graph, draft, where)
        elif "commit" in names or txn.get("activeGraphRevisionAfter") != active:
            err(where, "uncommitted transactions must leave the active revision unchanged")
    for draft in drafts.values():
        if draft["id"] not in used and draft["baseGraphRevision"] == active:
            for op in draft["ops"]:
                if op["op"] == "connect" and compatible(ports, op["from"], op["to"], op.get("conversion")) != "ok":
                    err(draft["id"], "reviewable draft contains an invalid connection")
    if active != graph["revision"]:
        err(hs["name"], f"final active revision {active} != graph revision {graph['revision']}")


def check_commands(hs, roles, docs):
    people = {p["id"]: p for p in hs["session"]["participants"]}
    params = {p["id"]: p for p in docs["parameter"]["parameters"]}
    bindings = {b["id"]: b for b in docs["parameter"]["bindings"]}
    perms = {c["name"]: c["permission"] for c in docs["command"]["classes"]}
    controls = {c["id"]: c["device"] for c in hs["rig"].get("controls", [])}
    present = {d["id"] for d in hs["rig"]["devices"] if d["presence"] == "present"}
    for log in hs["logs"]:
        last_seq = 0
        if log["hostEpoch"] != hs["hostEpoch"]:
            err(log["host"], "log hostEpoch differs from the session's host epoch")
        for cmd in log["commands"]:
            where, status = cmd["id"], cmd["result"]["status"]
            if cmd["seq"] <= last_seq:
                err(where, "seq is not monotonic")
            last_seq = cmd["seq"]
            origin, binding = people.get(cmd["origin"]), bindings.get(cmd["origin"], {})
            if origin is None:
                if binding.get("state") != "active" or controls.get(binding.get("control")) not in present:
                    err(where, "origin must be a session member or an active binding on this host's own rig")
                    continue
                origin = people[log["host"]]
            target = params.get(cmd["op"].get("set"), {})
            if "set" in cmd["op"] and target.get("class") != cmd["class"]:
                err(where, f"class {cmd['class']} must match the target's class {target.get('class')}")
                continue
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
            expected = ALLOWED[cmd["class"]] if ok else {"rejectedPermission"}
            if status not in expected:
                err(where, f"status {status} not in {sorted(expected)}")
            if origin["role"] == "assistant" and status not in ("draftCreated", "rejectedPermission"):
                err(where, "assistant commands may only create review drafts")
            if status == "heldForPickup" and bindings.get(cmd["origin"], {}).get("pickup", {}).get("state") != "waiting":
                err(where, "heldForPickup requires a waiting pickup binding")
            res, exp = cmd["result"].get("resultParameterRevision"), cmd.get("expectedParameterRevision")
            if res is not None and exp is not None and res != exp + 1:
                err(where, "accepted live change must advance parameter revision by one")


def check_roles(docs):
    session = docs["sessionStatus"]
    roles = session["roles"]
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
    for t in session["telemetry"]:
        if t["source"] != "measured" and t["display"] != "Unavailable":
            err(t["target"], "non-measured telemetry must display Unavailable")
        if t["source"] == "measured" and (t.get("lease") != lease["id"] or lease["state"] != "running"):
            err(t["target"], "measured telemetry requires the running engine lease")
    caps = {c["capability"]: c["status"] for c in rig["capabilities"]}
    if lease["state"] == "running" and any(caps.get(c) != "available" for c in graph["requiredCapabilities"]):
        err(where, "a running lease needs every required graph capability available")
    routes = {r["role"]: r for r in rig["routes"]}
    status = {}
    for s in session["nodeStatus"]:
        if s["node"] in status:
            err(s["node"], "duplicate node status")
        status[s["node"]] = s["state"]
    for node in graph["nodes"]:
        state, role = status.get(node["id"]), node.get("role")
        needs = node.get("requiredCapabilities", []) + node.get("advisoryCapabilities", [])
        if state is None:
            err(f"{where} {node['id']}", "missing derived status")
        if role in rig.get("unmappedRoles", []) and state != "unmapped":
            err(f"{where} {node['id']}", "unmapped role must show Unmapped")
        if routes.get(role, {}).get("binding") == "deviceMissing" and state != "lostMuted":
            err(f"{where} {node['id']}", "missing device must show Lost/Muted")
        if any(caps.get(c) == "missing" for c in needs) and state != "missing":
            err(f"{where} {node['id']}", "missing capability must show Missing")


def check_parameters(docs):
    params = {p["id"]: p for p in docs["parameter"]["parameters"]}
    presence = {d["id"]: d["presence"] for d in docs["deviceCapability"]["devices"]}
    control_device = {c["id"]: c["device"] for c in docs["deviceCapability"]["controls"]}
    for p in params.values():
        if not p["min"] <= p["value"] <= p["max"] or p.get("ceiling", p["max"]) > p["max"]:
            err(p["id"], "value/ceiling outside range")
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
        if not any(p["id"] == s["session"]["host"] and p["formFactor"] == "phone"
                   for s in sessions for p in s["session"]["participants"]):
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
