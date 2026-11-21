"""In-memory delta fixtures; the decoder performs no I/O or native operations."""

import unittest
from unittest import mock
import os
import subprocess

import git_delta as delta


def size(value):
    encoded = bytearray()
    while value >= 128:
        encoded.append((value & 127) | 128)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def program(base_size, output_size, instructions=b""):
    return size(base_size) + size(output_size) + instructions


class GitDeltaTests(unittest.TestCase):
    def test_git_produced_pack_delta(self):
        # Extracted from /usr/bin/git 2.54.0 pack-objects --stdout, with a
        # regular blob base and a REF_DELTA target; no Git execution at test time.
        base = b"".join(("line %04d words and data\n" % i).encode() for i in range(100))
        target = base[:700] + b"Git delta fixture insertion\n" + base[700:1800] + b"end\n"
        fixture = bytes.fromhex(
            "c413a80eb0bc021b4769742064656c7461206669787475726520696e736572"
            "74696f6eb3bb024d0404656e640a"
        )
        with mock.patch("builtins.open", side_effect=AssertionError("file access")), \
                mock.patch.object(os, "getenv", side_effect=AssertionError("environment")), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")):
            self.assertEqual(delta.apply_delta(base, fixture), target)

    def test_empty_and_multiple_copy_insert_operations(self):
        self.assertEqual(delta.apply_delta(b"", b"\0\0"), b"")
        instructions = b"\x91\x02\x03\x02XY\x90\x01"
        self.assertEqual(delta.apply_delta(b"abcdef", program(6, 6, instructions)),
                         b"cdeXYa")

    def test_copy_optional_bytes_keep_their_positions(self):
        base = b"x" * 65536 + b"abc"
        # offset3 only, followed by size1; then all seven optional bytes,
        # including explicit zero bytes for high offset and size.
        instructions = b"\x94\x01\x03\xff\x00\x00\x01\x00\x03\x00\x00"
        self.assertEqual(delta.apply_delta(base, program(len(base), 6, instructions)),
                         b"abcabc")
        # offset2 and size2, with the low bytes omitted.
        base = b"x" * 256 + b"z" * 256
        self.assertEqual(delta.apply_delta(base, program(len(base), 256, b"\xa2\x01\x01")),
                         b"z" * 256)

    def test_largest_insert_and_multibyte_size(self):
        data = bytes(range(127))
        self.assertEqual(delta.apply_delta(b"", program(0, 128, b"\x7f" + data + b"\x01z")),
                         data + b"z")

    def test_default_copy_length_with_omitted_and_zero_size(self):
        base = b"a" * 65536
        for instruction in (b"\x80", b"\x90\x00", b"\xf0\x00\x00\x00"):
            with self.subTest(instruction=instruction):
                self.assertEqual(delta.apply_delta(base, program(len(base), len(base),
                                                                 instruction)), base)

    def test_exact_limits(self):
        base = b"x" * delta.BASE_LIMIT
        self.assertEqual(delta.apply_delta(base, program(len(base), 1, b"\x01z")), b"z")
        base = b"x" * 65536
        self.assertEqual(delta.apply_delta(
            base, program(len(base), delta.OUTPUT_LIMIT, b"\x80" * 4)),
            b"x" * delta.OUTPUT_LIMIT)
        instructions = b"\x01x" * delta.OPERATION_LIMIT
        self.assertEqual(delta.apply_delta(b"", program(0, delta.OPERATION_LIMIT,
                                                        instructions)),
                         b"x" * delta.OPERATION_LIMIT)

    def test_types_and_byte_limits(self):
        for base, instructions in (
            (bytearray(), b"\0\0"), (b"", bytearray(b"\0\0")),
            (b"x" * (delta.BASE_LIMIT + 1), b"\0\0"),
            (b"", b"\0" * (delta.PROGRAM_LIMIT + 1)),
            (b"", program(0, delta.OUTPUT_LIMIT + 1)),
        ):
            with self.subTest(base_type=type(base), program_length=len(instructions)):
                with self.assertRaises(ValueError):
                    delta.apply_delta(base, instructions)
        # An exactly-at-limit program reaches opcode validation, not input refusal.
        with self.assertRaisesRegex(ValueError, "reserved delta opcode"):
            delta.apply_delta(b"", b"\0" * delta.PROGRAM_LIMIT)

    def test_operation_limit_even_when_bytes_are_within_limits(self):
        count = delta.OPERATION_LIMIT + 1
        with self.assertRaisesRegex(ValueError, "operation limit"):
            delta.apply_delta(b"", program(0, count, b"\x01x" * count))

    def test_truncated_noncanonical_and_overflowing_varints(self):
        for instructions in (
            b"", b"\x80", b"\0", b"\0\x80",
            b"\x80\0\0", b"\0\x81\0",
            b"\x80" * 9 + b"\0\0",
            b"\0" + b"\xff" * 9 + b"\x01",
            b"\0" + size(delta.MAX_SIZE),
        ):
            with self.subTest(instructions=instructions):
                with self.assertRaises(ValueError):
                    delta.apply_delta(b"", instructions)

    def test_invalid_or_truncated_instructions(self):
        for instructions in (
            b"\x00", b"\x01", b"\x02x", b"\x81", b"\x82",
            b"\x84", b"\x88", b"\x90", b"\xa0", b"\xc0",
        ):
            with self.subTest(instructions=instructions):
                with self.assertRaises(ValueError):
                    delta.apply_delta(b"x", program(1, 1, instructions))
        for count in range(7):
            with self.subTest(optional_bytes=count):
                with self.assertRaisesRegex(ValueError, "truncated delta copy"):
                    delta.apply_delta(b"x", program(1, 1, b"\xff" + b"\0" * count))

    def test_copy_bounds_and_output_mismatch(self):
        cases = (
            (b"x", program(2, 1, b"\x01a")),  # base length mismatch
            (b"x", program(1, 1, b"\x91\x01\x01")),  # copy starts at end
            (b"xyz", program(3, 2, b"\x91\x02\x02")),  # copy crosses end
            (b"x", program(1, 1, b"\x88\x01")),  # high offset byte
            (b"x", program(1, 1, b"\xc0\x01")),  # high size byte
            (b"x", program(1, 0, b"\x01a")),  # output exceeds declaration
            (b"x", program(1, 2, b"\x01a")),  # output shorter than declaration
            (b"x", program(1, 1, b"\x01a\x00")),  # trailing reserved opcode
        )
        for base, instructions in cases:
            with self.subTest(instructions=instructions):
                with self.assertRaises(ValueError):
                    delta.apply_delta(base, instructions)


if __name__ == "__main__":
    unittest.main()
