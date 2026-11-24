"""Synthetic tests for the separate Products-path V3 parser profile."""

import unittest
from unittest import mock
import zlib

import git_pack as reader
import test_git_pack as fixtures
import test_git_pack_v2 as large


fixture = fixtures.fixture
plain = fixtures.plain
object_id = fixtures.object_id
MIB = large.MIB


def read_v3(pack, index, oid):
    return reader._lookup(reader._parse_profile(pack, index, reader._Profile.V3), oid)


def delta(base_id, base_size, output_size, body):
    sizes = fixtures.delta_size(base_size) + fixtures.delta_size(output_size)
    return fixtures.ref(base_id, sizes + body)


class GitPackV3Tests(unittest.TestCase):
    def test_fixed_bounds_and_older_profiles_unchanged(self):
        self.assertEqual((reader.V3_PACK_LIMIT, reader.V3_OBJECT_COUNT_LIMIT,
                          reader.V3_OBJECT_LIMIT, reader.V3_INFLATE_LIMIT,
                          reader.V3_RESULT_LIMIT, reader.V3_DELTA_LIMITS),
                         (32 * MIB, 8192, 4 * MIB, 96 * MIB, 96 * MIB,
                          (4 * MIB, 4 * MIB, 4 * MIB, MIB)))
        self.assertEqual((reader.PACK_LIMIT, reader._pack_limit(reader._Profile.V2),
                          reader.INDEX_LIMIT, reader.OBJECT_COUNT_LIMIT, reader.OBJECT_LIMIT,
                          reader.INFLATE_LIMIT, reader.RESULT_LIMIT, reader.DEPTH_LIMIT),
                         (8 * MIB, 16 * MIB, MIB, 4096, 256 * 1024, 8 * MIB, 8 * MIB, 32))
        self.assertEqual((reader.git_delta.BASE_LIMIT, reader.git_delta.PROGRAM_LIMIT,
                          reader.git_delta.OUTPUT_LIMIT, reader.git_delta.OPERATION_LIMIT),
                         (MIB, MIB, 256 * 1024, 65536))

    def test_real_pack_boundary(self):
        oid = object_id("blob", b"x").hex()
        pack, index = large.pair_of_size(32 * MIB)
        self.assertEqual(read_v3(pack, index, oid), ("blob", b"x"))
        with self.assertRaisesRegex(ValueError, "input size limit"):
            reader.read_object_v2(pack, index, oid)
        pack, index = large.pair_of_size(32 * MIB + 1)
        with self.assertRaisesRegex(ValueError, "input size limit"):
            read_v3(pack, index, oid)

    def test_real_object_boundary_and_v1_v2_refusal(self):
        data = b"x" * reader.V3_OBJECT_LIMIT
        name = object_id("blob", data)
        pair = fixture([(name, plain(3, data))])
        self.assertEqual(read_v3(*pair, name.hex()), ("blob", data))
        for read in (reader.read_object, reader.read_object_v2):
            with self.subTest(read=read.__name__), \
                    self.assertRaisesRegex(ValueError, "object size limit"):
                read(*pair, name.hex())
        too_big = data + b"x"
        with self.assertRaisesRegex(ValueError, "object size limit"):
            read_v3(*fixture([(object_id("blob", too_big), plain(3, too_big))]), name.hex())

    def test_aggregate_over_8_mib_accepted_only_by_v3(self):
        # 33 complete 256 KiB objects exceed the V1/V2 inflate and result caps.
        entries = []
        for i in range(33):
            data = bytes([i]) * reader.OBJECT_LIMIT
            entries.append((object_id("blob", data), plain(3, data)))
        pair = fixture(entries)
        self.assertEqual(read_v3(*pair, entries[0][0].hex())[0], "blob")
        for read in (reader.read_object, reader.read_object_v2):
            with self.subTest(read=read.__name__), \
                    self.assertRaisesRegex(ValueError, "aggregate inflate limit"):
                read(*pair, entries[0][0].hex())

    def test_real_inflate_and_result_boundaries(self):
        # 24 complete 4 MiB objects reach the 96 MiB inflate cap; one more byte refuses.
        size = reader.V3_OBJECT_LIMIT
        entries = []
        for i in range(24):
            data = bytes([i]) * size
            entries.append((object_id("blob", data), plain(3, data)))
        self.assertEqual(read_v3(*fixture(entries), entries[0][0].hex())[0], "blob")
        entries.append((object_id("blob", b"y"), plain(3, b"y")))
        with self.assertRaisesRegex(ValueError, "aggregate inflate limit"):
            read_v3(*fixture(entries), entries[0][0].hex())
        # Small programs expand into distinct 4 MiB results: 24 fit, 25 refuse.
        base = b"\0" * size
        base_id = object_id("blob", base)
        entries = [(base_id, plain(3, base))]
        for i in range(1, 25):
            result = base[:-1] + bytes([i])
            entries.append((object_id("blob", result),
                            delta(base_id, size, size, b"\xf0\xff\xff\x3f\x01" + bytes([i]))))
        self.assertEqual(read_v3(*fixture(entries[:24]), base_id.hex()), ("blob", base))
        with self.assertRaisesRegex(ValueError, "aggregate result limit"):
            read_v3(*fixture(entries), base_id.hex())

    def test_real_object_count_boundary(self):
        entries = [(object_id("blob", str(i).encode()), plain(3, str(i).encode()))
                   for i in range(reader.V3_OBJECT_COUNT_LIMIT + 1)]
        self.assertEqual(read_v3(*fixture(entries[:-1]), entries[0][0].hex()), ("blob", b"0"))
        with self.assertRaisesRegex(ValueError, "count limit"):
            read_v3(*fixture(entries), entries[0][0].hex())

    def test_large_delta_base_output_and_operation_boundaries(self):
        size = reader.V3_OBJECT_LIMIT
        base = b"\0" * size
        base_id = object_id("blob", base)
        result = base[:-1] + b"x"
        entry = delta(base_id, size, size, b"\xf0\xff\xff\x3f\x01x")
        pair = fixture([(base_id, plain(3, base)), (object_id("blob", result), entry)])
        self.assertEqual(read_v3(*pair, object_id("blob", result).hex()), ("blob", result))
        with self.assertRaisesRegex(ValueError, "object size limit"):
            reader.read_object_v2(*pair, base_id.hex())
        over = delta(base_id, size, size + 1, b"\xf0\xff\xff\x3f\x01x")
        with self.assertRaisesRegex(ValueError, "delta output size limit"):
            read_v3(*fixture([(base_id, plain(3, base)), (object_id("blob", b"z"), over)]),
                    base_id.hex())
        empty_id = object_id("blob", b"")
        count = reader.V3_DELTA_LIMITS[3]
        for amount, accepted in ((count, True), (count + 1, False)):
            data = b"x" * amount
            target_id = object_id("blob", data)
            pair = fixture([(empty_id, plain(3, b"")),
                            (target_id, delta(empty_id, 0, amount, b"\x01x" * amount))])
            if accepted:
                self.assertEqual(read_v3(*pair, target_id.hex()), ("blob", data))
            else:
                with self.assertRaisesRegex(ValueError, "operation limit"):
                    read_v3(*pair, target_id.hex())
        program = b"\0" * (reader.V3_DELTA_LIMITS[1] + 1)
        oversized = fixtures.header(7, len(program)) + empty_id + zlib.compress(program)
        with self.assertRaisesRegex(ValueError, "object size limit"):
            read_v3(*fixture([(empty_id, plain(3, b"")), (object_id("blob", b"q"), oversized)]),
                    empty_id.hex())

    def test_existing_safeguards_with_v3_profile(self):
        # Structural, checksum, identity, CRC, offset and depth fixtures still refuse.
        names = (
            "test_git_produced_loose_and_ref_and_ofs", "test_kinds_empty_and_missing",
            "test_types_checksums_headers_and_truncation", "test_index_structure_and_identity",
            "test_invalid_entries_and_no_external_bases",
            "test_nonminimal_pack_object_size_header_refuses",
            "test_two_object_reference_cycle", "test_depth_limit_even_with_cached_bases",
            "test_real_chain_depth_and_invalid_delta",
        )
        with mock.patch.object(reader, "read_object", read_v3):
            for name in names:
                with self.subTest(safeguard=name):
                    getattr(fixtures.GitPackTests(name), name)()
        with mock.patch.object(reader, "read_object_v2", read_v3):
            large.GitPackV2Tests("test_invalid_ofs_distances").test_invalid_ofs_distances()


if __name__ == "__main__":
    unittest.main()
