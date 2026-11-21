"""Closed GitHub-reported context projection, not authenticated provenance.

Inputs are supplied explicitly; this module reads neither the environment nor
files and does not discover or verify the checkout.
"""

import json
import math
import re

import ios_runtime as runtime
import provider_attribution as attribution


EVENT_LIMIT = 1024 * 1024
ENV_VALUE_LIMIT = 512
ENV_KEYS = {
    "GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_SHA", "GITHUB_REF",
    "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB",
    "RUNNER_NAME", "RUNNER_ENVIRONMENT", "RUNNER_OS", "RUNNER_ARCH",
    "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA",
}


def _integer(text):
    runtime.require(len(text) <= 32, "event JSON number limit")
    return int(text)


def _float(text):
    runtime.require(len(text) <= 128, "event JSON number limit")
    value = float(text)
    runtime.require(math.isfinite(value), "invalid event JSON number")
    return value


def _constant(_text):
    raise runtime.Refusal("invalid event JSON number")


def _payload(data):
    runtime.require(type(data) is bytes and 0 < len(data) <= EVENT_LIMIT,
                    "event payload type/size limit")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=runtime._json_pairs,
                           parse_int=_integer, parse_float=_float, parse_constant=_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise runtime.Refusal("invalid event JSON") from error
    runtime.require(type(value) is dict, "invalid event payload shape")
    return value


def _field(parent, key):
    runtime.require(type(parent) is dict and key in parent, "missing event field")
    return parent[key]


def _id(value):
    runtime.require(type(value) is str and
                    re.fullmatch(r"[1-9][0-9]{0,18}", value, flags=re.ASCII),
                    "invalid reported numeric identity")
    number = int(value)
    attribution._number(number)
    return number


def read_context(environment, event_bytes, checkout_sha):
    """Project explicit inputs to the envelope context, with no I/O.

    checkout_sha is a caller-reported observation, not verified here. Supply a
    fresh projection and event payload on each envelope snapshot.
    """
    attribution._shape(environment, ENV_KEYS)
    for key, value in environment.items():
        if key in ("GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA") and value is None:
            continue
        runtime.require(type(value) is str and 0 < len(value) <= ENV_VALUE_LIMIT,
                        "reported environment value type/size limit")
    event = _payload(event_bytes)
    repository = environment["GITHUB_REPOSITORY"]
    runtime.require(_field(_field(event, "repository"), "full_name") == repository,
                    "event repository mismatch")
    event_name = environment["GITHUB_EVENT_NAME"]
    sha = environment["GITHUB_SHA"]
    ref = environment["GITHUB_REF"]
    pr = None
    if event_name == "push":
        runtime.require(event.get("pull_request") is None, "non-PR event contains PR identity")
        runtime.require(_field(event, "after") == sha and _field(event, "ref") == ref,
                        "push event mismatch")
    elif event_name == "workflow_dispatch":
        runtime.require(event.get("pull_request") is None, "non-PR event contains PR identity")
        runtime.require(_field(event, "ref") == ref, "dispatch event mismatch")
    elif event_name == "pull_request":
        details = _field(event, "pull_request")
        number = _field(event, "number")
        attribution._number(number)
        runtime.require(type(_field(details, "number")) is int
                        and details["number"] == number, "PR number mismatch")
        base = _field(details, "base")
        head = _field(details, "head")
        runtime.require(_field(_field(base, "repo"), "full_name") == repository,
                        "PR base repository mismatch")
        pr = {"number": number, "head_sha": _field(head, "sha"),
              "base_sha": _field(base, "sha")}
    else:
        raise runtime.Refusal("unsupported event")

    workflow_ref = environment["GITHUB_WORKFLOW_REF"]
    workflow_sha = environment["GITHUB_WORKFLOW_SHA"]
    runtime.require((workflow_ref is None) == (workflow_sha is None),
                    "incomplete workflow identity")
    workflow = None
    if workflow_ref is not None:
        prefix = repository + "/"
        runtime.require(workflow_ref.startswith(prefix) and "@" in workflow_ref,
                        "workflow repository/path mismatch")
        path, _, _ = workflow_ref[len(prefix):].partition("@")
        workflow = {"sha": workflow_sha, "ref": workflow_ref, "path": path}

    return attribution._context({
        "repository": repository, "event_name": event_name, "event_sha": sha,
        "event_ref": ref, "checkout_sha": checkout_sha, "pull_request": pr,
        "workflow": workflow, "run_id": _id(environment["GITHUB_RUN_ID"]),
        "run_attempt": _id(environment["GITHUB_RUN_ATTEMPT"]),
        "job": environment["GITHUB_JOB"],
        "runner": {"name": environment["RUNNER_NAME"],
                   "environment": environment["RUNNER_ENVIRONMENT"]},
        "platform": {"os": environment["RUNNER_OS"], "arch": environment["RUNNER_ARCH"]},
    })
