"""Pure tests for the products-to-launch binder; nothing is read or executed."""

import ast
import copy
import json
from pathlib import Path
import unicodedata
import unittest
from unittest import mock

import ios_launch_binding as binding
import ios_runtime
import observation_runner as products
import prepare
import provider_attribution
import source_snapshot_integration as integration
from ios_launch_plan import Refusal


RUN_ID = "123e4567-e89b-42d3-a456-426614174000"
HEAD = "a" * 40
INPUT_SHA = "1" * 64
OUTPUT_SHA = "2" * 64
SOURCE = "/runner/Build/Products/FluxKlang_iphonesimulator27.1.xctestrun"
STEM = "/runner/Build/Products/FluxKlang_iphonesimulator27.1.audit-run-" + RUN_ID
OUTPUT = STEM + ".xctestrun"
INTENT_PATH = STEM + ".intent.json"
BUNDLE = f"/runner/results/{RUN_ID}.xcresult"


def envelope(commit=HEAD):
    """A synthetic v5 envelope in exactly the shape _products_record reads."""
    data = {
        "schema": integration.SCHEMA_V5,
        "attribution": {
            "context": {"runner": {"environment": "github-hosted"},
                        "platform": {"os": "macOS", "arch": "ARM64"}},
            "checkout": {"kind": "event-commit", "commit": commit, "tree": "b" * 40},
            "workflow": {"status": "observed", "path": products._PRODUCTS_WORKFLOW,
                         "sha": commit, "blob": "c" * 40},
            "provider_runtime": {
                "xcode": dict(products._RECORD_XCODE),
                "runtime": {"identifier": ios_runtime.RUNTIME, **products._RECORD_RUNTIME},
                "checker": {"size": ios_runtime.LIBRARY_SIZE,
                            "sha256": ios_runtime.LIBRARY_SHA256},
            },
        },
        "sources": {path: {"blob": "d" * 40, "sha256": "e" * 64}
                    for path in integration._PATHS_V5},
    }
    return json.dumps(data).encode("ascii")


def record_line(commit=HEAD, output_sha=OUTPUT_SHA):
    """Real _products_record output for synthetic inputs (schema drift guard)."""
    with mock.patch.object(products, "integration", integration, create=True):
        return products._products_record(
            (envelope(commit), {"input": INPUT_SHA, "output": output_sha}), INPUT_SHA)


def intent(source=SOURCE):
    output, intent_path = prepare.output_paths(Path(source), RUN_ID)
    return prepare.intent_record(
        Path(source), INPUT_SHA, output, OUTPUT_SHA, intent_path, RUN_ID,
        prepare.IOS_PROVIDER_RUNTIME_PROFILE, {"xcode": {"version": "Xcode 27.1"}},
    )


def recode(record):
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n"


class Text(str):
    pass


class Number(int):
    pass


class BindingTests(unittest.TestCase):
    def bind(self, **changes):
        arguments = dict(reviewed_head=HEAD, products_record_line=record_line(),
                         intent=intent(), run_uuid=RUN_ID, xctestrun_path=OUTPUT,
                         result_bundle_path=BUNDLE)
        arguments.update(changes)
        return binding.bind_launch(**arguments)

    def refuses(self, message, **changes):
        with self.assertRaisesRegex(Refusal, message):
            self.bind(**changes)

    def test_binds_real_record_and_prepare_intent(self):
        self.assertEqual(self.bind(), (RUN_ID, OUTPUT, BUNDLE))
        self.assertEqual(prepare.output_paths(Path(SOURCE), RUN_ID),
                         (Path(OUTPUT), Path(INTENT_PATH)))

    def test_reviewed_head_shape_and_binding(self):
        for value in ("A" * 40, "a" * 39, None, Text(HEAD), HEAD.encode()):
            with self.subTest(value=value):
                self.refuses("reviewed head must be", reviewed_head=value)
        self.refuses("does not match the observed checkout", reviewed_head="f" * 40)
        self.refuses("does not match the observed checkout",
                     products_record_line=record_line(commit="f" * 40))

    def test_record_bytes_must_be_canonical_bounded_and_closed(self):
        line = record_line()
        record = json.loads(line)
        observation = record["observation"]
        path = integration._PATHS_V5[0]
        mutations = {
            "schema": ("schema",), "assurance": ("observation", "assurance"),
            "workflow": ("observation", "workflow", "path"),
            "xcode": ("observation", "xcode", "build"),
            "runtime": ("observation", "runtime", "identifier"),
            "runner": ("observation", "runner", "os"),
        }
        bad = [line[:-1], line + b"\n", b" " + line, bytearray(line), line.decode(),
               line.replace(b":", b": ", 1), json.dumps(record).encode() + b"\n",
               line[:-2] + b',"schema":"x"}\n', b"x" * (8 * 1024 + 1),
               recode({**record, "extra": 1}), recode({"schema": record["schema"]}),
               line.replace(b'"assurance"', b'"\\u0061ssurance"', 1)]
        for keys in mutations.values():
            changed = copy.deepcopy(record)
            target = changed
            for key in keys[:-1]:
                target = target[key]
            target[keys[-1]] = target[keys[-1]] + "x"
            bad.append(recode(changed))
        for name, value in (("size", True), ("size", ios_runtime.LIBRARY_SIZE + 0.5),
                            ("sha256", "A" * 64)):
            changed = copy.deepcopy(record)
            changed["observation"]["checker"][name] = value
            bad.append(recode(changed))
        for key in ("commit", "tree"):
            changed = copy.deepcopy(record)
            changed["observation"]["checkout"][key] = HEAD.upper()
            bad.append(recode(changed))
        changed = copy.deepcopy(record)
        del changed["observation"]["sources"][path]
        bad.append(recode(changed))
        changed = copy.deepcopy(record)
        changed["observation"]["sources"][path]["extra"] = "x"
        bad.append(recode(changed))
        changed = copy.deepcopy(record)
        changed["observation"]["prepared"]["output_sha256"] = 1
        bad.append(recode(changed))
        nan = line.replace(str(ios_runtime.LIBRARY_SIZE).encode(), b"NaN")
        bad.append(nan)
        self.assertEqual(recode(record), line)
        self.assertIn("checker", observation)
        for index, value in enumerate(bad):
            with self.subTest(index=index):
                self.refuses("invalid Products observation record",
                             products_record_line=value)

    def test_intent_must_be_exact_provider_profile(self):
        base = intent()
        changes = [("schema_version", 2), ("schema_version", True),
                   ("schema_version", Number(3)), ("schema_version", 3.0),
                   ("profile", prepare.IOS_RUNTIME_PROFILE),
                   ("profile", Text(prepare.IOS_PROVIDER_RUNTIME_PROFILE)),
                   ("qualification", "full"), ("targets", ("FluxKlangTests", "FluxKlangUITests")),
                   ("targets", [Text("FluxKlangTests"), "FluxKlangUITests"]),
                   ("targets", ["FluxKlangUITests", "FluxKlangTests"]),
                   ("targets", ["FluxKlangTests"]),
                   ("targets", ["FluxKlangTests", "FluxKlangUITests", "FluxKlangTests"]),
                   ("provider_observation", None), ("intent_path", Path(INTENT_PATH)),
                   ("input", {"path": SOURCE, "sha256": INPUT_SHA, "x": 1}),
                   ("output", {"path": OUTPUT, "sha256": "A" * 64}),
                   ("output", {"path": Text(OUTPUT), "sha256": OUTPUT_SHA})]
        values = [dict(base, **{key: value}) for key, value in changes]
        values += [dict(base, attachment_policy={}), {k: v for k, v in base.items()
                                                      if k != "provider_observation"},
                   list(base.items()), type("D", (dict,), {})(base)]
        for index, value in enumerate(values):
            with self.subTest(index=index):
                self.refuses("intent is not a provider-profile intent", intent=value)

    def test_intent_digests_must_match_record(self):
        self.refuses("intent digests do not match", products_record_line=record_line(
            output_sha="3" * 64))
        changed = intent()
        changed["input"]["sha256"] = "3" * 64
        self.refuses("intent digests do not match", intent=changed)

    def test_run_id_must_be_checked_and_bound(self):
        other = "223e4567-e89b-42d3-a456-426614174000"
        self.refuses("noncanonical UUID", run_uuid=RUN_ID.upper())
        self.refuses("UUID must be text", run_uuid=Text(RUN_ID))
        self.refuses("does not match the run UUID", run_uuid=other)
        for value in (RUN_ID.upper(), Text(RUN_ID), "123e4567-e89b-12d3-a456-426614174000",
                      None):
            with self.subTest(value=value):
                self.refuses("does not match the run UUID", intent=dict(intent(), run_id=value))

    def test_intent_paths_must_be_run_linked_siblings(self):
        other = "/runner/Other/FluxKlang.audit-run-" + RUN_ID
        for changes in ({"output": {"path": other + ".xctestrun", "sha256": OUTPUT_SHA}},
                        {"intent_path": other + ".intent.json"},
                        {"intent_path": OUTPUT}):
            with self.subTest(changes=changes):
                self.refuses("run-linked sibling paths", intent=dict(intent(), **changes))
        for path in ("relative.xctestrun", "/runner//x.xctestrun", "/runner/x.plist",
                     "/runner/../x.xctestrun"):
            with self.subTest(path=path):
                changed = intent()
                changed["input"]["path"] = path
                self.refuses("intent input path", intent=changed)

    def test_xctestrun_must_be_prepared_output_not_candidate(self):
        self.refuses("must not be the original candidate", xctestrun_path=SOURCE)
        self.refuses("must be the prepared output", xctestrun_path="/other/x.xctestrun")
        for value in (Text(OUTPUT), OUTPUT + "/", "/runner//x.xctestrun", None):
            with self.subTest(value=value):
                self.refuses("xctestrun path must", xctestrun_path=value)

    def test_result_bundle_rules(self):
        products_dir = SOURCE.rsplit("/", 1)[0]
        for value in (products_dir + "/r.xcresult", products_dir + "/deep/r.xcresult"):
            with self.subTest(value=value):
                self.refuses("outside the Products directory", result_bundle_path=value)
        for value in (Text(BUNDLE), "results/r.xcresult", "/r/../r.xcresult",
                      "/r/r.xcresult\n", "/r/" + "x" * 1100 + ".xcresult", "/r/r.zip"):
            with self.subTest(value=value):
                self.refuses("result bundle path (must|exceeds)", result_bundle_path=value)
        for value in (products_dir.upper() + "/r.xcresult",
                      "/runner/build/PRODUCTS/r.xcresult",
                      unicodedata.normalize("NFD", products_dir + "/\u00e9.xcresult")):
            with self.subTest(value=value):
                self.refuses("outside the Products directory", result_bundle_path=value)
        self.assertEqual(self.bind(result_bundle_path=products_dir + "-r.xcresult")[2],
                         products_dir + "-r.xcresult")

    def bind_source(self, source, bundle):
        changed = intent(source)
        return self.bind(intent=changed, xctestrun_path=changed["output"]["path"],
                         result_bundle_path=bundle)

    def test_bundle_equal_to_or_ancestor_of_products_root_is_refused(self):
        source = "/runner/Caf\u00e9.xcresult/Products.xcresult/FluxKlang.xctestrun"
        self.assertEqual(self.bind_source(source, BUNDLE)[2], BUNDLE)
        for bundle in ("/runner/Caf\u00e9.xcresult/Products.xcresult",
                       "/runner/Caf\u00e9.xcresult",
                       "/runner/CAFE\u0301.XCRESULT/products.xcresult",
                       "/runner/Cafe\u0301.xcresult/Products.xcresult/r.xcresult",
                       unicodedata.normalize("NFD", "/runner/Caf\u00e9.xcresult")):
            with self.subTest(bundle=bundle):
                with self.assertRaisesRegex(Refusal, "outside the Products directory"):
                    self.bind_source(source, bundle)

    def test_candidate_at_filesystem_root_refuses_every_bundle(self):
        for bundle in (BUNDLE, "/r.xcresult"):
            with self.subTest(bundle=bundle):
                with self.assertRaisesRegex(Refusal, "outside the Products directory"):
                    self.bind_source("/FluxKlang.xctestrun", bundle)

    def test_envelope_fixture_fits_the_real_limit(self):
        self.assertLessEqual(len(envelope()), provider_attribution.ENVELOPE_LIMIT)

    def test_source_has_no_direct_io_imports_cli_or_v5_membership(self):
        source = Path(binding.__file__).read_text(encoding="utf-8")
        imports = []
        for node in ast.walk(ast.parse(source)):
            if isinstance(node, ast.Import):
                imports.extend(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imports.append((node.module or "").split(".", 1)[0])
        forbidden = {"argparse", "io", "os", "pathlib", "shutil", "signal", "socket",
                     "subprocess", "sys", "tempfile"}
        self.assertFalse(forbidden.intersection(imports), imports)
        for text in ("__main__", "open(", "xcrun", "shell=", "/usr/bin/env"):
            self.assertNotIn(text, source)
        self.assertFalse([path for path in integration._PATHS_V5
                          if path.endswith("/ios_launch_binding.py")])


if __name__ == "__main__":
    unittest.main()
