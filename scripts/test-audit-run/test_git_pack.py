"""Static Git fixtures and adversarial in-memory pack/index specimens."""

import base64
import hashlib
import os
import struct
import subprocess
import unittest
from unittest import mock
import zlib

import git_pack as reader


BASE_ID = "04a11cb2d0623f99f5c0ef4203e58a7a70822fd8"
TARGET_ID = "fd3dadda7fe2efdf080cfc13f35901e0e3f82369"
# Git 2.54.0 hash-object -w, pack-objects --stdout (with/without
# --delta-base-offset), and index-pack. Indexes are zlib-wrapped for brevity.
LOOSE = (
    "eAF1zztOBDEQQEFiTuEjjNtuf44zqyFAWu1KgMT1ISFC9dIX1e3+vJXI43i5vz/eyvFb"
    "+X5+XJ/lfFzlOr/O179RNUKjaXSN1BgaU2NpbIwqeZW8Sl4lr5JXyavkVfIqeZU8JA/J"
    "Q/KQPCQPyUPykDwkD8mb5E3yJnmTvEneJG+SN8mb5E3yLnmXvEveJe+Sd8m75F3yLnmX"
    "PCVPyVPylDwlT8lT8pQ8JU/Jh+RD8iH5kHxIPiQfkg/Jh+RD8in5lHxKPiWfkk/Jp+RT"
    "8in5lHxJviRfki/Jl+RL8iX5knxJviTfkm/Jt+Rb8i35lnxLviXfku9/8h/lsx8w"
)
REF_PACK = (
    "UEFDSwAAAAIAAAACtJwBeJx1zzFOAzEQQNGeU+wR8Ngej4+z0lJEioJEInF9KOjQ++2v"
    "3v32+Djefzu+P7+u53E+ruM6X+fb/W80jdDoGkNjaqTG0iiNjdEkb5I3yZvkTfImeZO8"
    "Sd4kb5KH5CF5SB6Sh+QheUgekofkIXmXvEveJe+Sd8m75F3yLnmXvEs+JB+SD8mH5EPy"
    "IfmQfEg+JB+ST8mn5FPyKfmUfEo+JZ+ST8mn5Cl5Sp6Sp+QpeUqekqfkKXlKviRfki/J"
    "l+RL8iX5knxJviRfkpfkJXlJXpKX5CV5SV6Sl+Ql+ZZ8S74l35JvybfkW/It+ZZ8/5P/"
    "AC5lHKr9AgShHLLQYj+Z9cDvQgPlinpwgi/YeJw7IryCb8MeJmn3zBKFlNSckkSFtMyK"
    "ktKiVIXMvOLUopLM/LzNu5l8WVhS81K4AIqfEI1I3cOl1ZqL3yjD/MYMjnB04LLfvg=="
)
OFS_PACK = (
    "UEFDSwAAAAIAAAACtJwBeJx1zzFOAzEQQNGeU+wR8Ngej4+z0lJEioJEInF9KOjQ++2v"
    "3v32+Djefzu+P7+u53E+ruM6X+fb/W80jdDoGkNjaqTG0iiNjdEkb5I3yZvkTfImeZO8"
    "Sd4kb5KH5CF5SB6Sh+QheUgekofkIXmXvEveJe+Sd8m75F3yLnmXvEs+JB+SD8mH5EPy"
    "IfmQfEg+JB+ST8mn5FPyKfmUfEo+JZ+ST8mn5Cl5Sp6Sp+QpeUqekqfkKXlKviRfki/J"
    "l+RL8iX5knxJviRfkpfkJXlJXpKX5CV5SV6Sl+Ql+ZZ8S74l35JvybfkW/It+ZZ8/5P/"
    "AC5lHKrtAoB4eJw7IryCb8MeJmn3zBKFlNSckkSFtMyKktKiVIXMvOLUopLM/LzNu5l8"
    "WVhS81K4AIqfEI2g6re6gp+s4bNwSA8KTBOL0soFuQ=="
)
REF_INDEX = (
    "eJz7X+KfzMDAwMSACRhH8SgexcMaM8Ewy0KZTReS7Gd+PfDeiflpV1VBk/6Nv7Zrb9U/"
    "en+fg+eP8OdIxgePfyhnRu4WPxzGU3IHqIcHaASLx93DS6/O6r6vcfjPMZ6+gpIHm+7v"
    "0/wcnBntd7g1YnLkv10++1dmynw+DAD9tDQ7"
)
OFS_INDEX = (
    "eJz7X+KfzMDAwMSACRhH8SgexcMaM8Ewy0KZTReS7Gd+PfDeiflpV1VBk/6Nv7Zrb9U/"
    "en+fg+eP8OdIxgePfyhnRu4WP3xnZd17oB4eoBEsC15t39U0f83DzQUe/Fw+wt2XTrHu"
    "zDeyCDcw/6Nxl/ntzSeMisaLfWc/BgDyWzGA"
)


def decode(value):
    return base64.b64decode(value)


def object_id(kind, data):
    return hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).digest()


def header(kind, size):
    first = (kind << 4) | (size & 15)
    size >>= 4
    result = bytearray([first | (128 if size else 0)])
    while size:
        byte = size & 127
        size >>= 7
        result.append(byte | (128 if size else 0))
    return bytes(result)


def fixture(entries):
    """Make structurally valid index/pack around explicit (name, entry) pairs."""
    data = b"PACK" + struct.pack(">II", 2, len(entries))
    indexed = []
    for name, entry in entries:
        indexed.append((name, zlib.crc32(entry), len(data)))
        data += entry
    pack = data + hashlib.sha1(data).digest()
    indexed.sort()
    fanout = b"".join(struct.pack(">I", sum(name[0] <= i for name, _, _ in indexed))
                      for i in range(256))
    idx = (b"\xfftOc\0\0\0\2" + fanout
           + b"".join(name for name, _, _ in indexed)
           + b"".join(struct.pack(">I", crc) for _, crc, _ in indexed)
           + b"".join(struct.pack(">I", offset) for _, _, offset in indexed)
           + pack[-20:])
    return pack, idx + hashlib.sha1(idx).digest()


def plain(kind, data):
    return header(kind, len(data)) + zlib.compress(data)


def ref(base, program):
    return header(7, len(program)) + base + zlib.compress(program)


def rehash(data):
    return data[:-20] + hashlib.sha1(data[:-20]).digest()


def delta_size(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


class GitPackTests(unittest.TestCase):
    def test_git_produced_loose_and_ref_and_ofs(self):
        base = b"".join(("line %04d words and data\n" % i).encode() for i in range(100))
        target = base[:700] + b"Git delta fixture insertion\n" + base[700:1800] + b"end\n"
        self.assertEqual(zlib.decompress(decode(LOOSE)), b"blob 2500\0" + base)
        with mock.patch("builtins.open", side_effect=AssertionError("file access")), \
                mock.patch.object(os, "getenv", side_effect=AssertionError("environment")), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")):
            for pack, index in ((REF_PACK, REF_INDEX), (OFS_PACK, OFS_INDEX)):
                pack, index = decode(pack), zlib.decompress(decode(index))
                self.assertEqual(reader.read_object(pack, index, BASE_ID), ("blob", base))
                self.assertEqual(reader.read_object(pack, index, TARGET_ID), ("blob", target))

    def test_kinds_empty_and_missing(self):
        entries = [(object_id(kind, data), plain(number, data))
                   for number, kind, data in ((1, "commit", b"commit"),
                                              (2, "tree", b""),
                                              (3, "blob", b"blob"),
                                              (4, "tag", b"tag"))]
        pack, index = fixture(entries)
        for number, kind, data in ((1, "commit", b"commit"), (2, "tree", b""),
                                   (3, "blob", b"blob"), (4, "tag", b"tag")):
            self.assertEqual(reader.read_object(pack, index, object_id(kind, data).hex()),
                             (kind, data))
        with self.assertRaisesRegex(ValueError, "unavailable"):
            reader.read_object(pack, index, "0" * 40)
        with self.assertRaises(ValueError):
            reader.read_object(*fixture([]), "0" * 40)

    def test_types_checksums_headers_and_truncation(self):
        pack = decode(REF_PACK)
        index = zlib.decompress(decode(REF_INDEX))
        for p, idx, oid in (
            (bytearray(pack), index, BASE_ID), (pack, bytearray(index), BASE_ID),
            (pack, index, BASE_ID.upper()), (pack, index, "0" * 39), (pack, index, 1),
            (pack[:-1], index, BASE_ID), (pack, index[:-1], BASE_ID),
            (pack[:-21] + b"x" + pack[-20:], index, BASE_ID),
            (pack, index[:-21] + b"x" + index[-20:], BASE_ID),
            (rehash(pack[:7] + b"\x03" + pack[8:]), index, BASE_ID),
            (pack, rehash(index[:7] + b"\x01" + index[8:]), BASE_ID),
            (pack, zlib.decompress(decode(OFS_INDEX)), BASE_ID),
        ):
            with self.subTest(oid=oid, pack_length=len(p), index_length=len(idx)):
                with self.assertRaises(ValueError):
                    reader.read_object(p, idx, oid)

    def test_index_structure_and_identity(self):
        pack, index = fixture([(object_id("blob", b"a"), plain(3, b"a")),
                               (object_id("blob", b"b"), plain(3, b"b"))])
        names = 1032
        crc = names + 40
        offsets = crc + 8
        mutations = (
            (8, b"\xff\xff\xff\xff"),  # fanout
            (names + 20, index[names:names + 20]),  # duplicate names
            (names, b"\0" * 20),  # name and content disagree
            (crc, b"\0" * 4),
            (offsets + 4, index[offsets:offsets + 4]),  # duplicate offset
            (offsets, b"\0\0\0\x0d"),  # invalid first boundary
            (offsets, b"\x80\0\0\0"),  # no large offset table
        )
        for position, change in mutations:
            bad = rehash(index[:position] + change + index[position + len(change):])
            with self.subTest(position=position, change=change):
                with self.assertRaises(ValueError):
                    reader.read_object(pack, bad, object_id("blob", b"a").hex())
        # Preserve sorting and fanout, so this reaches the object hash check.
        original = object_id("blob", b"a")
        one_pack, one_index = fixture([(original, plain(3, b"a"))])
        altered = original[:-1] + bytes([original[-1] ^ 1])
        bad = rehash(one_index[:names] + altered + one_index[names + 20:])
        with self.assertRaisesRegex(ValueError, "object identity mismatch"):
            reader.read_object(one_pack, bad, altered.hex())
        # Large-offset slots cannot point into a bounded pack; reject unused,
        # invalid and noncanonical slots as well as a genuinely large offset.
        offset_pos = names + 20 + 4
        for offset, large in ((0, 0x80000000), (0x80000000, 12),
                              (0x80000000, 0x80000000), (0x80000001, 0x80000000)):
            body = (one_index[:offset_pos] + struct.pack(">I", offset)
                    + struct.pack(">Q", large) + one_index[-40:-20])
            bad = body + hashlib.sha1(body).digest()
            with self.subTest(offset=offset, large=large):
                with self.assertRaises(ValueError):
                    reader.read_object(one_pack, bad, original.hex())

    def test_invalid_entries_and_no_external_bases(self):
        name = object_id("blob", b"a")
        for entry in (
            header(5, 1) + zlib.compress(b"a"),
            b"\xb1\0" + zlib.compress(b"a"),  # nonminimal size
            header(3, 1) + zlib.compress(b"aa"),  # inflate bomb
            header(3, 2) + zlib.compress(b"a"),  # short output
            header(3, 1) + zlib.compress(b"a") + b"junk",
            header(3, 1) + zlib.compress(b"a")[:-1],
            header(3, 1) + b"not zlib",
            header(6, 2) + b"\0" + zlib.compress(b"\0\0"),
            header(6, 2) + b"\x01" + zlib.compress(b"\0\0"),
            ref(b"x" * 20, b"\0\0"),
            ref(name, b"\0\0"),  # self-cycle
            ref(name, b"bad"),
        ):
            with self.subTest(entry=entry):
                with self.assertRaises(ValueError):
                    reader.read_object(*fixture([(name, entry)]), name.hex())
        # A bad unrequested entry is still validated.
        bad = object_id("blob", b"bad")
        with self.assertRaises(ValueError):
            reader.read_object(*fixture([(name, plain(3, b"a")),
                                         (bad, plain(3, b"wrong"))]), name.hex())
        with self.assertRaisesRegex(ValueError, "offset base outside pack"):
            reader.read_object(*fixture([(name, plain(3, b"a")),
                                         (bad, header(6, 2) + b"\x01"
                                          + zlib.compress(b"\0\0"))]), name.hex())

    def test_nonminimal_pack_object_size_header_refuses(self):
        name = object_id("blob", b"a")
        self.assertEqual(reader.read_object(*fixture([(name, plain(3, b"a"))]), name.hex()),
                         ("blob", b"a"))
        with self.assertRaisesRegex(ValueError, "noncanonical object size header"):
            reader.read_object(*fixture([(name, b"\xb1\0" + zlib.compress(b"a"))]), name.hex())

    def test_two_object_reference_cycle(self):
        a, b = object_id("blob", b"a"), object_id("blob", b"b")
        with self.assertRaisesRegex(ValueError, "cyclic"):
            reader.read_object(*fixture([(a, ref(b, b"\0\0")),
                                        (b, ref(a, b"\0\0"))]), a.hex())

    def test_inclusive_input_count_inflate_and_result_limits(self):
        a, b = object_id("blob", b"a"), object_id("blob", b"bb")
        pack, index = fixture([(a, plain(3, b"a")), (b, plain(3, b"bb"))])
        for limit, exact in (("PACK_LIMIT", len(pack)), ("INDEX_LIMIT", len(index)),
                             ("OBJECT_COUNT_LIMIT", 2), ("INFLATE_LIMIT", 3),
                             ("RESULT_LIMIT", 3), ("OBJECT_LIMIT", 2)):
            with self.subTest(limit=limit):
                with mock.patch.object(reader, limit, exact):
                    self.assertEqual(reader.read_object(pack, index, a.hex()), ("blob", b"a"))
                with mock.patch.object(reader, limit, exact - 1):
                    with self.assertRaises(ValueError):
                        reader.read_object(pack, index, a.hex())

    def test_depth_limit_even_with_cached_bases(self):
        # Each delta replaces its single-byte base with a distinct byte.
        entries = [(object_id("blob", b"a"), plain(3, b"a"))]
        for current, previous in ((b"b", b"a"), (b"c", b"b"), (b"d", b"c")):
            entries.append((object_id("blob", current),
                            ref(object_id("blob", previous), b"\x01\x01\x01" + current)))
        pack, index = fixture(entries)
        with mock.patch.object(reader, "DEPTH_LIMIT", 4):
            self.assertEqual(reader.read_object(pack, index, entries[-1][0].hex()),
                             ("blob", b"d"))
        with mock.patch.object(reader, "DEPTH_LIMIT", 3):
            with self.assertRaisesRegex(ValueError, "depth|deep"):
                reader.read_object(pack, index, entries[-1][0].hex())

    def test_real_object_and_count_boundaries(self):
        data = b"x" * reader.OBJECT_LIMIT
        name = object_id("blob", data)
        self.assertEqual(reader.read_object(*fixture([(name, plain(3, data))]), name.hex()),
                         ("blob", data))
        too_big = data + b"x"
        with self.assertRaisesRegex(ValueError, "object size limit"):
            reader.read_object(*fixture([(object_id("blob", too_big), plain(3, too_big))]),
                               name.hex())
        entries = [(object_id("blob", str(i).encode()), plain(3, str(i).encode()))
                   for i in range(reader.OBJECT_COUNT_LIMIT + 1)]
        pack, index = fixture(entries[:-1])
        self.assertEqual(reader.read_object(pack, index, entries[0][0].hex()), ("blob", b"0"))
        with self.assertRaisesRegex(ValueError, "count limit"):
            reader.read_object(*fixture(entries), entries[0][0].hex())

    def test_real_aggregate_inflate_and_result_boundaries(self):
        # 32 complete 256 KiB objects fit; 33 exceed the inflate budget.
        entries = []
        for i in range(33):
            data = bytes([i]) * reader.OBJECT_LIMIT
            entries.append((object_id("blob", data), plain(3, data)))
        pack, index = fixture(entries[:32])
        self.assertEqual(reader.read_object(pack, index, entries[0][0].hex())[0], "blob")
        with self.assertRaisesRegex(ValueError, "aggregate inflate limit"):
            reader.read_object(*fixture(entries), entries[0][0].hex())

        # Small programs expand into distinct 256 KiB results, independently
        # exercising the reconstructed-byte budget rather than the inflate cap.
        base = b"\0" * reader.OBJECT_LIMIT
        base_id = object_id("blob", base)
        entries = [(base_id, plain(3, base))]
        sizes = delta_size(len(base)) + delta_size(len(base))
        for i in range(1, 33):
            result = base[:-1] + bytes([i])
            program = sizes + b"\xf0\xff\xff\x03\x01" + bytes([i])
            entries.append((object_id("blob", result), ref(base_id, program)))
        self.assertEqual(reader.read_object(*fixture(entries[:32]), base_id.hex()),
                         ("blob", base))
        with self.assertRaisesRegex(ValueError, "aggregate result limit"):
            reader.read_object(*fixture(entries), base_id.hex())

    def test_real_chain_depth_and_invalid_delta(self):
        entries = [(object_id("blob", b"\0"), plain(3, b"\0"))]
        for i in range(1, 33):
            entries.append((object_id("blob", bytes([i])),
                            ref(entries[-1][0], b"\x01\x01\x01" + bytes([i]))))
        self.assertEqual(reader.read_object(*fixture(entries[:32]), entries[31][0].hex()),
                         ("blob", b"\x1f"))
        with self.assertRaisesRegex(ValueError, "depth|deep"):
            reader.read_object(*fixture(entries), entries[0][0].hex())
        malformed = [(entries[0][0], entries[0][1]),
                     (entries[1][0], ref(entries[0][0], b"\x01\x01\0"))]
        with self.assertRaisesRegex(ValueError, "reserved delta opcode"):
            reader.read_object(*fixture(malformed), entries[0][0].hex())

    def test_delta_program_size_boundary(self):
        base_id = object_id("blob", b"")
        target_id = object_id("blob", b"x")
        program = b"\0\x01\x01x"
        entries = [(base_id, plain(3, b"")), (target_id, ref(base_id, program))]
        with mock.patch.object(reader.git_delta, "PROGRAM_LIMIT", len(program)):
            self.assertEqual(reader.read_object(*fixture(entries), target_id.hex()), ("blob", b"x"))
        with mock.patch.object(reader.git_delta, "PROGRAM_LIMIT", len(program) - 1):
            with self.assertRaisesRegex(ValueError, "object size limit"):
                reader.read_object(*fixture(entries), target_id.hex())
        oversized = header(7, reader.git_delta.PROGRAM_LIMIT + 1) + base_id + zlib.compress(b"")
        with self.assertRaisesRegex(ValueError, "object size limit"):
            reader.read_object(*fixture([(base_id, plain(3, b"")), (target_id, oversized)]),
                               target_id.hex())

    def test_delta_instruction_work_limit(self):
        base_id = object_id("blob", b"")
        count = reader.git_delta.OPERATION_LIMIT
        for amount, accepted in ((count, True), (count + 1, False)):
            data = b"x" * amount
            program = delta_size(0) + delta_size(amount) + b"\x01x" * amount
            target_id = object_id("blob", data)
            pack, index = fixture([(base_id, plain(3, b"")), (target_id, ref(base_id, program))])
            if accepted:
                self.assertEqual(reader.read_object(pack, index, target_id.hex()), ("blob", data))
            else:
                with self.assertRaisesRegex(ValueError, "operation limit"):
                    reader.read_object(pack, index, target_id.hex())

    def test_bounded_reader_reuses_only_exact_immutable_inputs(self):
        pack, index = decode(REF_PACK), zlib.decompress(decode(REF_INDEX))
        cache = reader.BoundedReader()
        with mock.patch.object(reader, "_parse", wraps=reader._parse) as parse:
            for oid in (BASE_ID, TARGET_ID, BASE_ID):
                self.assertEqual(cache.read(pack, index, oid),
                                 reader.read_object(pack, index, oid))
            # The direct read_object calls above each parse; the cache parsed once.
            self.assertEqual(parse.call_count, 4)
            # Distinct but equal immutable bytes do not trigger parsing.
            self.assertEqual(cache.read(bytes(bytearray(pack)), bytes(bytearray(index)), BASE_ID)[0],
                             "blob")
            self.assertEqual(parse.call_count, 4)
            changed, changed_index = fixture([(object_id("blob", b"new"), plain(3, b"new"))])
            self.assertEqual(cache.read(changed, changed_index, object_id("blob", b"new").hex()),
                             ("blob", b"new"))
            self.assertEqual(parse.call_count, 5)
            with self.assertRaisesRegex(KeyError, "unavailable"):
                cache.read(pack, index, BASE_ID)
            self.assertEqual(parse.call_count, 5)
            with self.assertRaises(KeyError):
                cache.read(changed, changed_index, object_id("blob", b"new").hex())

    def test_bounded_reader_refuses_corruption_missing_and_mutable_inputs(self):
        pack, index = decode(REF_PACK), zlib.decompress(decode(REF_INDEX))
        for bad_pack, bad_index, oid in (
            (pack[:-1] + b"x", index, BASE_ID),
            (pack, index[:-1] + b"x", BASE_ID),
            (pack, index, "0" * 40),
            (bytearray(pack), index, BASE_ID),
            (pack, bytearray(index), BASE_ID),
            (pack, index, BASE_ID.upper()),
        ):
            cache = reader.BoundedReader()
            self.assertEqual(cache.read(pack, index, BASE_ID)[0], "blob")
            with self.subTest(oid=oid, pack_type=type(bad_pack), index_type=type(bad_index)):
                with self.assertRaises(KeyError):
                    cache.read(bad_pack, bad_index, oid)
                with self.assertRaises(KeyError):
                    cache.read(pack, index, BASE_ID)

    def test_bounded_reader_call_budget_and_two_attempts(self):
        pack, index = decode(REF_PACK), zlib.decompress(decode(REF_INDEX))
        cache = reader.BoundedReader()
        with mock.patch.object(reader, "_parse", wraps=reader._parse) as parse:
            for _ in range(reader.READER_CALL_LIMIT):
                self.assertEqual(cache.read(pack, index, BASE_ID)[0], "blob")
            self.assertEqual(parse.call_count, 1)
            with self.assertRaises(KeyError) as raised:
                cache.read(pack, index, BASE_ID)
            self.assertIn("call limit", str(raised.exception.__cause__))
            self.assertEqual(parse.call_count, 1)
        # A corrupt second pair is validated, refuses, and permanently poisons
        # this instance rather than returning an earlier cached observation.
        cache = reader.BoundedReader()
        cache.read(pack, index, BASE_ID)
        with mock.patch.object(reader, "_parse", wraps=reader._parse) as parse:
            with self.assertRaises(KeyError):
                cache.read(pack[:-1] + b"x", index, BASE_ID)
            with self.assertRaises(KeyError):
                cache.read(pack, index, BASE_ID)
            self.assertEqual(parse.call_count, 1)


if __name__ == "__main__":
    unittest.main()
