"""Synthetic, explicit-input tests for the separate 16 MiB parser profile."""

import unittest
from unittest import mock
import zlib

import git_pack as reader
import test_git_pack as fixtures


fixture = fixtures.fixture
header = fixtures.header
object_id = fixtures.object_id


MIB = 1024 * 1024


def ofs_distance(distance):
    encoded = [distance & 127]
    while distance >> 7:
        distance = (distance >> 7) - 1
        encoded.append(128 | (distance & 127))
    return bytes(reversed(encoded))


def padded_base(distance):
    # A zlib stream with many non-final empty stored DEFLATE blocks and one
    # final stored block. It can occupy MiBs while inflating to 0...4 bytes.
    for length in range(5):
        blocks, remainder = divmod(distance - 12 - length, 5)
        if blocks >= 0 and not remainder:
            data = b"b" * length
            stream = (b"\x78\x01" + b"\x00\x00\x00\xff\xff" * blocks
                      + bytes((1, length, 0, 255 - length, 255)) + data
                      + zlib.adler32(data).to_bytes(4, "big"))
            entry = header(3, length) + stream
            assert len(entry) == distance
            return data, entry
    raise AssertionError("unrepresentable distance")


def large_pair(distance):
    data, entry = padded_base(distance)
    target = b"x"
    program = bytes((len(data), 1, 1, ord("x")))
    delta = header(6, len(program)) + ofs_distance(distance) + zlib.compress(program)
    return fixture([(object_id("blob", data), entry), (object_id("blob", target), delta)])


def pair_of_size(size):
    # The delta's encoded distance is only a few bytes; solve its exact size
    # before allocating the large stored-block stream.
    for distance in range(size - 64, size - 32):
        length = (distance - 12) % 5
        program = bytes((length, 1, 1, ord("x")))
        delta_length = len(header(6, len(program)) + ofs_distance(distance)
                           + zlib.compress(program))
        if 32 + distance + delta_length == size:
            return large_pair(distance)
    raise AssertionError("unrepresentable pack size")


class GitPackV2Tests(unittest.TestCase):
    def test_v1_pack_boundary(self):
        oid = object_id("blob", b"x").hex()
        pack, index = pair_of_size(8 * MIB)
        self.assertEqual(len(pack), 8 * MIB)
        self.assertEqual(reader.read_object(pack, index, oid), ("blob", b"x"))
        pack, index = pair_of_size(8 * MIB + 1)
        self.assertEqual(len(pack), 8 * MIB + 1)
        self.assertEqual(reader.read_object_v2(pack, index, oid), ("blob", b"x"))
        with self.assertRaisesRegex(ValueError, "input size limit"):
            reader.read_object(pack, index, oid)

    def test_exact_16_mib_and_input_cap(self):
        pack, index = pair_of_size(16 * MIB)
        oid = object_id("blob", b"x").hex()
        self.assertEqual(len(pack), 16 * MIB)
        self.assertEqual(reader.read_object_v2(pack, index, oid), ("blob", b"x"))
        with self.assertRaisesRegex(ValueError, "input size limit"):
            reader.read_object(pack, index, oid)
        pack, index = pair_of_size(16 * MIB + 1)
        self.assertEqual(len(pack), 16 * MIB + 1)
        with self.assertRaisesRegex(ValueError, "input size limit"):
            reader.read_object_v2(pack, index, oid)

    def test_fixed_index_and_input_types(self):
        pack, index = fixture([(object_id("blob", b"x"), fixtures.plain(3, b"x"))])
        oid = object_id("blob", b"x").hex()
        with self.assertRaisesRegex(ValueError, "input size limit"):
            reader.read_object_v2(pack, b"\0" * (reader.INDEX_LIMIT + 1), oid)
        for bad_pack, bad_index in ((bytearray(pack), index), (pack, bytearray(index))):
            with self.subTest(pack_type=type(bad_pack), index_type=type(bad_index)):
                with self.assertRaisesRegex(ValueError, "must be bytes"):
                    reader.read_object_v2(bad_pack, bad_index, oid)

    def test_ofs_distance_across_8_mib(self):
        oid = object_id("blob", b"x").hex()
        for distance in (8 * MIB - 1, 8 * MIB, 8 * MIB + 1):
            with self.subTest(distance=distance):
                pack, index = large_pair(distance)
                self.assertEqual(reader.read_object_v2(pack, index, oid), ("blob", b"x"))
                with self.assertRaisesRegex(ValueError, "input size limit"):
                    reader.read_object(pack, index, oid)

    def test_invalid_ofs_distances(self):
        base = object_id("blob", b"")
        target = object_id("blob", b"x")
        first = header(3, 0) + zlib.compress(b"")
        program = b"\0\x01\x01x"
        for encoded, reason in ((b"\0", "invalid offset base"),
                                (ofs_distance(len(first) + 1), "invalid offset base"),
                                (ofs_distance(1), "offset base outside pack"),
                                (b"\xff" * 8 + b"\x7f", "invalid offset base")):
            with self.subTest(encoded=encoded):
                pair = fixture([(base, first),
                                (target, header(6, len(program)) + encoded
                                 + zlib.compress(program))])
                with self.assertRaisesRegex(ValueError, reason):
                    reader.read_object_v2(*pair, base.hex())

    def test_existing_safeguards_with_v2_profile(self):
        # Exercise the same adversarial fixtures, real budgets, and depth and
        # instruction boundaries against both public parser profiles.
        names = (
            "test_git_produced_loose_and_ref_and_ofs", "test_kinds_empty_and_missing",
            "test_types_checksums_headers_and_truncation", "test_index_structure_and_identity",
            "test_invalid_entries_and_no_external_bases", "test_nonminimal_pack_object_size_header_refuses",
            "test_two_object_reference_cycle", "test_depth_limit_even_with_cached_bases",
            "test_real_object_and_count_boundaries", "test_real_aggregate_inflate_and_result_boundaries",
            "test_real_chain_depth_and_invalid_delta", "test_delta_program_size_boundary",
            "test_delta_instruction_work_limit",
        )
        with mock.patch.object(reader, "read_object", reader.read_object_v2):
            for name in names:
                with self.subTest(safeguard=name):
                    getattr(fixtures.GitPackTests(name), name)()


if __name__ == "__main__":
    unittest.main()
