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
            "transactionTrace", "sessionStatus"}
ALLOWED = {"live": {"accepted", "heldForPickup"}, "structural": {"draftUpdated", "reviewRequired"},
           "hazardous": {"needsAuthorization"}, "safety": {"accepted"}, "proposal": {"draftCreated"}}
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


def load():
    docs = {}
    for path in sorted(Path(__file__).parent.glob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            err(path.name, f"invalid JSON: {exc}")
            continue
        if doc.get("synthetic") is not True:
            err(path.name, "must declare synthetic: true")
        for field in ("contract", "schemaVersion", "id", "revision", "history"):
            if field not in doc:
                err(path.name, f"missing {field}")
        revs = [h.get("revision") for h in doc.get("history", [])]
        if not revs or any(not isinstance(r, int) for r in revs) or revs != sorted(set(revs)):
            err(path.name, f"history revisions must be strictly increasing integers: {revs}")
        elif revs[-1] != doc.get("revision"):
            err(path.name, f"revision {doc.get('revision')} != last history revision {revs[-1]}")
        docs[doc.get("contract")] = doc
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
    if src.get("channels") != dst.get("channels"):
        if not conversion or len(conversion.get("map", [])) != dst.get("channels"):
            return "channelMismatch"
    return "ok"


def check_graph(docs):
    graph = docs["graph"]
    ports = {p["id"]: p for p in graph["ports"]}
    nodes = {n["id"]: n for n in graph["nodes"]}
    declared = set(graph["requiredCapabilities"]) | set(graph["advisoryCapabilities"])
    for node in graph["nodes"]:
        has_ports = any(p["node"] == node["id"] for p in graph["ports"])
        if node.get("routable") is False and has_ports:
            err("graph", f"{node['id']} is non-routable but has ports")
        for cap in node.get("requiredCapabilities", []):
            if cap not in declared:
                err("graph", f"{node['id']} requires {cap} not declared at graph level")
    adjacency = {n: set() for n in nodes}
    for edge in graph["edges"]:
        verdict = compatible(ports, edge["from"], edge["to"], edge.get("conversion"))
        if verdict != "ok":
            err("graph", f"{edge['id']} is invalid: {verdict}")
        elif "feedback" not in edge:
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


def check_transactions(docs, history, ports):
    trace, graph = docs["transactionTrace"], docs["graph"]
    roles, people = docs["sessionStatus"]["roles"], {p["id"]: p for p in docs["sessionStatus"]["participants"]}
    drafts = {d["id"]: d for d in trace["drafts"]}
    order, active, last_seq = trace["stepOrder"], trace["initialActiveGraphRevision"], 0
    for txn in trace["transactions"]:
        where, draft = txn["id"], drafts[txn["draft"]]
        base, steps = draft["baseGraphRevision"], txn["steps"]
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
                    for op in draft["ops"] if op["op"] in ("connect", "addEdge")} - {"ok"}
        if not stale and verdicts and validate.get("code") not in verdicts:
            err(where, f"validate should fail with {sorted(verdicts)}")
        for step in steps:
            if step["step"] == "reviewAuthorize":
                who = people.get(step.get("authorizedBy"), {})
                if "activation.authorize" not in roles.get(who.get("role"), []):
                    err(where, f"{step.get('authorizedBy')} may not authorize activation")
                bound = step.get("boundTo", {})
                if bound.get("draft") != txn["draft"] or bound.get("baseGraphRevision") != base:
                    err(where, "authorization is not bound to this exact draft and base")
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
        elif "commit" in names or txn.get("activeGraphRevisionAfter") != active:
            err(where, "uncommitted transactions must leave the active revision unchanged")
    if active != graph["revision"]:
        err("transactionTrace", f"final active revision {active} != graph revision {graph['revision']}")


def check_commands(docs):
    session, transport = docs["sessionStatus"], docs["transport"]
    roles, people = session["roles"], {p["id"]: p for p in session["participants"]}
    host_epochs = {h["host"]: h["hostEpoch"] for h in transport["epochs"]["hosts"]}
    conn_epochs = {c["id"]: c["connectionEpoch"] for c in transport["epochs"]["connections"]}
    params = {p["id"]: p for p in docs["parameter"]["parameters"]}
    bindings = {b["id"]: b for b in docs["parameter"]["bindings"]}
    perms = {c["name"]: c["permission"] for c in docs["command"]["classes"]}
    last_seq = 0
    for log in docs["command"]["logs"]:
        if log["hostEpoch"] != host_epochs.get(log["host"]):
            err(log["host"], "log hostEpoch differs from transport epochs")
        for cmd in log["commands"]:
            where, status = cmd["id"], cmd["result"]["status"]
            if cmd["seq"] <= last_seq:
                err(where, "seq is not monotonic")
            last_seq = cmd["seq"]
            origin = people.get(cmd["origin"]) or people[log["host"]]
            conn = origin.get("connection")
            stale = cmd.get("hostEpoch") != log["hostEpoch"] or (
                conn is not None and cmd.get("connectionEpoch") != conn_epochs.get(conn))
            if stale:
                if status != "rejectedStaleEpoch":
                    err(where, "stale epoch must be rejected, whatever the class")
                continue
            granted, need = roles.get(origin["role"], []), perms[cmd["class"]]
            target = params.get(cmd["op"].get("set"), {})
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


def check_session(docs):
    session, devices, graph = docs["sessionStatus"], docs["deviceCapability"], docs["graph"]
    roles = session["roles"]
    forms = {a["formFactor"] for a in session["layoutAdaptations"]}
    for a in session["layoutAdaptations"]:
        if set(a) - {"formFactor", "layout"}:
            err("session", "layout adaptations may not carry permissions or roles")
    for p in session["participants"]:
        if p["role"] not in roles or "permissions" in p:
            err(p["id"], "permissions must come only from a defined role")
        if p["formFactor"] != "none" and p["formFactor"] not in forms:
            err(p["id"], "form factor has no layout adaptation")
        if p["role"] == "remoteController" and p.get("opensAudioEngine") is not False:
            err(p["id"], "remote controllers open no audio engine")
    if not any(p["formFactor"] == "phone" and p["role"] == "host" for p in session["participants"]):
        err("session", "examples must include a phone host with full host role")
    for name, granted in roles.items():
        human = name != "assistant"
        if human and not {"safety.panic", "safety.safeMute"} <= set(granted):
            err(name, "panic and safe mute must be reachable for every human role")
        if not human and any(g.split(".")[0] in ("live", "activation", "hazardous", "safety", "device") for g in granted):
            err(name, "assistant role must stay review-only")
    lease = session["lease"]
    host_windows = {w["id"] for w in session["windows"] if w["host"] == lease["holder"]}
    if set(lease["windows"]) != host_windows:
        err("lease", "one lease must cover every window of the holder")
    for t in session["telemetry"]:
        if t["source"] != "measured" and t["display"] != "Unavailable":
            err(t["target"], "non-measured telemetry must display Unavailable")
        if t["source"] == "measured" and (t.get("lease") != lease["id"] or lease["state"] != "running"):
            err(t["target"], "measured telemetry requires the running engine lease")
    caps = {c["id"]: c["status"] for c in devices["capabilities"]}
    routes = {r["role"]: r for r in devices["routes"]}
    status = {}
    for s in session["nodeStatus"]:
        if s["node"] in status:
            err(s["node"], "duplicate node status")
        status[s["node"]] = s["state"]
    for node in graph["nodes"]:
        state, role = status.get(node["id"]), node.get("role")
        if state is None:
            err(node["id"], "missing derived status")
        if role in devices.get("unmappedRoles", []) and state != "unmapped":
            err(node["id"], "unmapped role must show Unmapped")
        if routes.get(role, {}).get("binding") == "deviceMissing" and state != "lostMuted":
            err(node["id"], "missing device must show Lost/Muted")
        if any(caps.get(c) == "missing" for c in node.get("requiredCapabilities", [])) and state != "missing":
            err(node["id"], "missing capability must show Missing")


def check_parameters(docs):
    params = {p["id"]: p for p in docs["parameter"]["parameters"]}
    for p in params.values():
        if not p["min"] <= p["value"] <= p["max"] or p.get("ceiling", p["max"]) > p["max"]:
            err(p["id"], "value/ceiling outside range")
    for lrn in docs["parameter"]["learn"]:
        if params[lrn["proposedParameter"]].get("learnExcludedByDefault") and lrn["state"] != "blocked":
            err(lrn["id"], "excluded targets must be blocked from Learn by default")


def main():
    docs = load()
    if not errors:
        defined, history = check_ids_and_revisions(docs)
        ports = check_graph(docs)
        check_transactions(docs, history, ports)
        check_commands(docs)
        check_session(docs)
        check_parameters(docs)
    if errors:
        print("\n".join(f"FAIL {e}" for e in errors))
        return 1
    print(f"OK: {len(docs)} contracts, {len(defined)} synthetic ids, all references and revisions consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
