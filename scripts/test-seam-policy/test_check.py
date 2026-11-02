"""Fast executable-selection regressions; real SwiftLint integration is separate."""

import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import check


class ExecutableSelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="test-seam-tool-selection-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        (self.repository / "mise.toml").write_text('[tools]\nswiftlint = "repo-pin"\n')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.selected = self.bin / "swiftlint"
        self.log = self.root / "mise-call.json"
        self.pinned = self.executable("repo-pin/swiftlint", "#!/bin/sh\nexit 0\n")
        self.global_tool = self.executable("global-pin/swiftlint", "#!/bin/sh\nexit 0\n")

    def executable(self, relative, source):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        path.chmod(0o755)
        return path

    def mise_shim(self, fail=False):
        # A real symlink and subprocess, not a mock of which/Path.resolve.
        # This small test double deliberately selects a different tool outside
        # repository context. Actual mise integration is also verified locally.
        mise = self.executable("tools/mise", f"""#!{sys.executable}
import json
from pathlib import Path
import sys
Path({str(self.log)!r}).write_text(json.dumps({{
    "argv": sys.argv[1:], "cwd": str(Path.cwd()),
}}))
if sys.argv[1:] != ["which", "swiftlint"]:
    sys.exit(90)
if {fail!r}:
    print("repository tool unavailable", file=sys.stderr)
    sys.exit(1)
print({str(self.pinned)!r} if Path.cwd() == Path({str(self.repository)!r})
      else {str(self.global_tool)!r})
""")
        self.selected.symlink_to(mise)

    def invoke(self):
        selected = []
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": str(self.bin)}), \
                mock.patch.object(check, "REPOSITORY", self.repository), \
                mock.patch.object(sys, "argv", ["check.py"]), \
                mock.patch.object(check.Check, "execute",
                                  lambda instance: selected.append(instance.swiftlint)), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = check.main()
        return status, selected, output.getvalue()

    def test_actual_path_binary_is_preserved_without_mise(self):
        self.executable("bin/swiftlint", "#!/bin/sh\nexit 0\n")
        status, selected, _ = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual(selected, [str(self.selected)])
        self.assertFalse(self.log.exists())

    def test_mise_symlink_resolves_repository_pin_before_fixture_cwd(self):
        self.mise_shim()
        status, selected, _ = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual(selected, [str(self.pinned)])
        self.assertEqual(json.loads(self.log.read_text()), {
            "argv": ["which", "swiftlint"], "cwd": str(self.repository),
        })

    def test_non_mise_symlink_preserves_invocation_name(self):
        self.selected.symlink_to(self.pinned)
        status, selected, _ = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual(selected, [str(self.selected)])
        self.assertFalse(self.log.exists())

    def test_failed_mise_resolution_does_not_fall_back_to_shim(self):
        self.mise_shim(fail=True)
        status, selected, output = self.invoke()
        self.assertEqual(status, 1)
        self.assertEqual(selected, [])
        self.assertIn("repository tool unavailable", output)


if __name__ == "__main__":
    unittest.main()
