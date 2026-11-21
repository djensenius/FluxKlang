"""Controlled filesystem fixtures for detached checkout HEAD observation."""

import os
from pathlib import Path
import tempfile
import unittest

import checkout_head as observer


FIRST = "a" * 40
SECOND = "b" * 40


class CheckoutHeadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="checkout-head-observer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / ".git").mkdir()
        self.write_head(FIRST)

    def write_head(self, value):
        (self.root / ".git" / "HEAD").write_bytes(value.encode("ascii") + b"\n")

    def observe(self, expected=FIRST):
        return observer.observe_checkout_head(self.root, expected)

    def assert_refused(self, root=None, expected=FIRST):
        with self.assertRaises(observer.Refusal):
            observer.observe_checkout_head(self.root if root is None else root, expected)

    def test_reads_canonical_detached_head_and_observes_each_call(self):
        self.assertEqual(self.observe(), FIRST)
        self.write_head(SECOND)
        self.assertEqual(self.observe(SECOND), SECOND)
        self.assert_refused()

    def test_rejects_symbolic_and_malformed_head_content(self):
        for content in (
            b"ref: refs/heads/main\n",
            b"A" * 40 + b"\n",
            b"a" * 39 + b"\n",
            b"a" * 40,
            b"a" * 40 + b"\r\n",
            b"a" * 40 + b"\nextra",
        ):
            with self.subTest(content=content):
                (self.root / ".git" / "HEAD").write_bytes(content)
                self.assert_refused()

    def test_rejects_mismatch_and_oversized_content(self):
        self.assert_refused(expected=SECOND)
        (self.root / ".git" / "HEAD").write_bytes(b"a" * (observer.HEAD_BYTES + 1))
        self.assert_refused()

    def test_rejects_linked_worktree_git_file(self):
        (self.root / ".git" / "HEAD").unlink()
        (self.root / ".git").rmdir()
        (self.root / ".git").write_text("gitdir: /some/other/worktree\n", encoding="ascii")
        self.assert_refused()

    def test_rejects_symlink_git_directory_and_head(self):
        external = self.root / "external"
        external.mkdir()
        (external / "HEAD").write_bytes((FIRST + "\n").encode("ascii"))

        (self.root / ".git" / "HEAD").unlink()
        (self.root / ".git").rmdir()
        (self.root / ".git").symlink_to(external, target_is_directory=True)
        self.assert_refused()

        (self.root / ".git").unlink()
        (self.root / ".git").mkdir()
        (self.root / ".git" / "HEAD").symlink_to(external / "HEAD")
        self.assert_refused()

    def test_rejects_nonregular_head_without_blocking_on_fifo(self):
        head = self.root / ".git" / "HEAD"
        head.unlink()
        head.mkdir()
        self.assert_refused()
        head.rmdir()
        os.mkfifo(head)
        self.assert_refused()

    def test_rejects_invalid_roots_and_expected_ids(self):
        (self.root / ".git" / "HEAD").write_bytes((FIRST + "\n").encode("ascii"))
        for root in (str(self.root.relative_to(self.root)), "/"):
            with self.subTest(root=root):
                self.assert_refused(root=root)
        symlink_root = self.root.parent / (self.root.name + "-link")
        symlink_root.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(symlink_root.unlink)
        self.assert_refused(root=symlink_root)
        for expected in (FIRST.upper(), "a" * 39, "a" * 41, 1, None):
            with self.subTest(expected=expected):
                self.assert_refused(expected=expected)


if __name__ == "__main__":
    unittest.main()
