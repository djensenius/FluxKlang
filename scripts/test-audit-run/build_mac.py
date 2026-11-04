#!/usr/bin/env python3
"""Fixed Mac compile -> real preparation -> seal. Never runs tests or apps."""

import sys

sys.dont_write_bytecode = True

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess

import build_receipt as receipt
import prepare


class CommittedUncertain(RuntimeError):
    """Final receipt exists: reporting/durability uncertain, never retry."""


def write_all(stream, data):
    offset = 0
    while offset < len(data):
        count = stream.write(data[offset:])
        receipt.require(type(count) is int and 0 < count <= len(data) - offset,
                        "zero/invalid write progress")
        offset += count


def finalize(stream):
    stream.flush()
    os.fsync(stream.fileno())
    stream.close()


def exclusive(path, data):
    receipt.path_text(path)
    receipt.check_directory(path.parent)
    with path.open("xb") as stream:
        write_all(stream, data)
        finalize(stream)


def sync_directory(path):
    fd = receipt.open_fd(path, directory=True)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def compile_once(argv, environment, cwd, stdout, stderr):
    """Only our successfully spawned group is eligible for bounded termination."""
    child = None
    try:
        child = subprocess.Popen(argv, env=environment, cwd=cwd, stdout=stdout,
                                 stderr=stderr, start_new_session=True)
        return child.wait()
    except BaseException:
        if child is not None:
            # Even after the leader exits, group members may remain. Group
            # termination is best effort, not proof detached descendants died.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass  # Coordinator must reconcile an unreaped child.
        raise


def publish(value):
    w = receipt.schema(value)
    data = receipt.encode(value)
    receipt.require(len(data) <= receipt.RECEIPT_BYTES, "receipt byte limit")
    pending = w / "build-evidence/receipt.pending"
    final = pending.with_name("receipt.json")
    exclusive(pending, data)
    witness, reread = receipt.bounded(pending, receipt.RECEIPT_BYTES)
    receipt.equal(reread, data, "closed staging bytes")
    receipt.verify_evidence(receipt.json_bytes(reread))
    receipt.equal(receipt.bounded(pending, receipt.RECEIPT_BYTES)[0], witness, "staging recheck")
    # Single commit point. Same-filesystem link is atomic and never replaces.
    # Interrupted link/reporting must be reconciled, never regenerated.
    committed = False
    try:
        os.link(pending, final, follow_symlinks=False)
        committed = True
        sync_directory(final.parent)
        return {"status": "committed", "receipt": str(final),
                "sha256": witness["sha256"],
                "claim": "identification only; external review/pin and runtime permission required"}
    except BaseException as error:
        if committed:
            raise CommittedUncertain(
                f"committed; durability/reporting uncertain: {final}") from error
        if os.path.lexists(final) and not isinstance(error, FileExistsError):
            raise CommittedUncertain(
                f"final name exists; reconcile exact bytes, never retry: {final}") from error
        raise


def produce(workspace, expected_commit, expected_tree):
    w = Path(receipt.path_text(workspace))
    receipt.hex_value(expected_commit, 40)
    receipt.hex_value(expected_tree, 40)
    receipt.check_directory(w)
    receipt.absent(w / "DerivedData")
    receipt.absent(w / "build-evidence")
    source = receipt.source_observation(w / "source", w, expected_commit, expected_tree)
    for required in receipt.REVIEWED:
        receipt.require(required in {item["path"] for item in source["tracked"]},
                        "missing reviewed project input")
    packages = receipt.package_observation(w)
    toolchain = receipt.toolchain_observation()
    evidence = w / "build-evidence"
    # This exclusive mkdir consumes W, including on all subsequent failures.
    evidence.mkdir(mode=0o700)
    exclusive(evidence / "claim.json", receipt.encode(receipt.claim_record(
        w, expected_commit, expected_tree)))
    (evidence / "home").mkdir(mode=0o700)
    (evidence / "tmp").mkdir(mode=0o700)
    journal = evidence / "journal.log"
    exclusive(journal, receipt.encode(receipt.journal_record(w, expected_commit, expected_tree)))
    # All pre-spawn files and directory publications must succeed first.
    with (evidence / "stdout.log").open("xb") as stdout:
        with (evidence / "stderr.log").open("xb") as stderr:
            for stream in (stdout, stderr):
                stream.flush()
                os.fsync(stream.fileno())
            sync_directory(evidence)
            sync_directory(w)
            code = compile_once(receipt.recipe(w), receipt.environment(w), w / "source",
                                stdout, stderr)
            finalize(stdout)
            finalize(stderr)
    receipt.equal(code, 0, "compile exit")
    receipt.equal(receipt.source_observation(w / "source", w, expected_commit, expected_tree),
                  source, "postcompile source")
    receipt.equal(receipt.package_observation(w), packages, "postcompile packages")
    receipt.equal(receipt.toolchain_observation(), toolchain, "postcompile toolchain")
    inputs = receipt.input_observation(w, source, packages)
    original, sizes = receipt.original_metadata(w)
    # Bounded pinned recheck immediately around the accepted unbounded API.
    receipt.equal(receipt.bounded(original["path"])[0], original, "preprepare original")
    record = prepare.prepare(original["path"], original["sha256"], prepare.RETENTION_PROFILE)
    metadata = receipt.metadata_from_record(record, original, sizes)
    products = receipt.inventory(w / receipt.PRODUCTS)
    # Preserve the already durable pre-spawn intent separately. Final journal
    # is completed BEFORE hashing; no evidence is appended after hashing.
    os.link(journal, evidence / "compile-intent.json", follow_symlinks=False)
    # Do not write through the link to the original intent.
    completed = evidence / "journal-complete.pending"
    exclusive(completed, receipt.encode(receipt.journal_record(
        w, expected_commit, expected_tree, complete=True)))
    os.replace(completed, journal)
    sync_directory(evidence)
    value = {
        "schema_version": 1, "profile": receipt.PROFILE, "workspace": str(w),
        "expected_commit": expected_commit, "expected_tree": expected_tree,
        "source": source, "packages": packages, "toolchain": toolchain,
        "compile": {"argv": receipt.recipe(w), "environment": receipt.environment(w),
                    "cwd": str(w / "source"), "exit_code": code,
                    "evidence": {
                        key: receipt.file_data(evidence / (key + suffix))[0]
                        for key, suffix in (("journal", ".log"), ("stdout", ".log"),
                                            ("stderr", ".log"), ("claim", ".json"),
                                            ("compile-intent", ".json"))
                    }},
        "inputs": inputs, "metadata": metadata, "products": products,
    }
    return publish(value)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    producer = commands.add_parser("produce")
    producer.add_argument("--workspace", required=True)
    producer.add_argument("--expected-commit", required=True)
    producer.add_argument("--expected-tree", required=True)
    validator = commands.add_parser("validate")
    validator.add_argument("--receipt", required=True)
    validator.add_argument("--expected-sha256", required=True)
    args = parser.parse_args(argv)
    committed = False
    handlers = {}

    def interrupt(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")

    try:
        for signum in (signal.SIGTERM, signal.SIGHUP):
            handlers[signum] = signal.signal(signum, interrupt)
        if args.command == "produce":
            result = produce(args.workspace, args.expected_commit, args.expected_tree)
            committed = True
        else:
            result = {"status": "validated", "intent": receipt.validate(
                args.receipt, args.expected_sha256)}
        print(json.dumps(result, indent=2, sort_keys=True), flush=True)
        return 0
    except CommittedUncertain as error:
        print(str(error), file=sys.stderr)
        return 3
    except (OSError, ValueError, KeyboardInterrupt) as error:
        # Cover interruption between produce returning and assigning the local
        # committed flag. Presence means reconcile, not successful self-approval.
        final_present = (args.command == "produce" and os.path.lexists(
            Path(args.workspace) / "build-evidence/receipt.json"))
        uncertain = committed or final_present
        print(("final receipt present; reconcile reporting/durability; never retry: " if uncertain else
               "refused; any claimed workspace remains consumed: ") + str(error),
              file=sys.stderr)
        return 3 if uncertain else 1
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
