"""Static Git fixture and adversarial in-memory loose-object specimens."""

import hashlib
import os
import random
import socket
import subprocess
import unittest
from unittest import mock
import zlib

import git_loose as reader
import test_git_pack as pack_fixture


def object_data(kind, content):
    return kind + b" " + str(len(content)).encode("ascii") + b"\0" + content


def object_id(data):
    return hashlib.sha1(data).hexdigest()


class GitLooseTests(unittest.TestCase):
    def test_git_produced_fixture_and_empty_git_blob(self):
        base = b"".join(("line %04d words and data\n" % i).encode() for i in range(100))
        loose = pack_fixture.decode(pack_fixture.LOOSE)
        with mock.patch("builtins.open", side_effect=AssertionError("file access")), \
                mock.patch.object(os, "getenv", side_effect=AssertionError("environment")), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")):
            self.assertEqual(reader.read_object(loose, pack_fixture.BASE_ID), ("blob", base))
            self.assertEqual(
                reader.read_object(zlib.compress(b"blob 0\0"),
                                   "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
                ("blob", b""),
            )

    def test_all_kinds_and_binary_content(self):
        for kind in (b"commit", b"tree", b"blob", b"tag"):
            for content in (b"", b"\0\xffbinary\0"):
                data = object_data(kind, content)
                with self.subTest(kind=kind, content=content):
                    self.assertEqual(reader.read_object(zlib.compress(data), object_id(data)),
                                     (kind.decode("ascii"), content))

    def test_limits_and_bounded_inflation(self):
        # A stored (uncompressed DEFLATE) stream fits the cap at the content limit.
        rng = random.Random(893)
        content = bytes(rng.getrandbits(8) for _ in range(reader.OBJECT_LIMIT))
        data = object_data(b"commit", content)
        compressed = zlib.compress(data, level=0)
        self.assertLessEqual(len(compressed), reader.COMPRESSED_LIMIT)
        self.assertEqual(reader.read_object(compressed, object_id(data)), ("commit", content))

        with mock.patch.object(reader.zlib, "decompressobj",
                               wraps=zlib.decompressobj) as make_decoder:
            with self.assertRaisesRegex(ValueError, "compressed object size limit"):
                reader.read_object(b"x" * (reader.COMPRESSED_LIMIT + 1), "0" * 40)
            make_decoder.assert_not_called()

        for data in (object_data(b"blob", b"x" * (reader.OBJECT_LIMIT + 1)),
                     b"blob 1\0" + b"x" * (10 * 1024 * 1024)):
            with self.subTest(length=len(data)):
                with self.assertRaises(ValueError):
                    reader.read_object(zlib.compress(data), object_id(data))

        real_decoder = zlib.decompressobj()
        with mock.patch.object(reader.zlib, "decompressobj") as make_decoder:
            make_decoder.return_value = mock.Mock(wraps=real_decoder)
            with self.assertRaises(ValueError):
                reader.read_object(zlib.compress(b"x" * (1024 * 1024)), "0" * 40)
            make_decoder.return_value.decompress.assert_called_once()
            self.assertEqual(make_decoder.return_value.decompress.call_args.args[1],
                             reader.INFLATED_LIMIT + 1)

    def test_stream_boundaries_and_formats(self):
        data = object_data(b"blob", b"hello")
        stream = zlib.compress(data)
        raw = zlib.compressobj(wbits=-zlib.MAX_WBITS)
        gzip = zlib.compressobj(wbits=zlib.MAX_WBITS | 16)
        dictionary = zlib.compressobj(zdict=b"blob hello")
        invalid = (
            b"", b"not zlib", stream[:-1], stream[:2],
            stream + b"\0", stream + zlib.compress(b""),
            raw.compress(data) + raw.flush(), gzip.compress(data) + gzip.flush(),
            dictionary.compress(data) + dictionary.flush(),
            stream[:-1] + bytes([stream[-1] ^ 1]),
        )
        for compressed in invalid:
            with self.subTest(compressed=compressed):
                with self.assertRaises(ValueError):
                    reader.read_object(compressed, object_id(data))

    def test_noncanonical_headers_and_lengths(self):
        invalid = (
            b"", b"blob 0", b"blob\0", b"blob \0", b"blob 00\0",
            b"blob 01\0x", b"blob +1\0x", b"blob -1\0x", b"blob  1\0x",
            b"blob\t1\0x", b"Blob 1\0x", b"ofs-delta 1\0x",
            b"blob \xff\0", b"blob 1\n\0x", b"blob 1\0", b"blob 0\0x",
            b"blob 262145\0", b"blob 9999999999999999999999\0",
            b"x" * 1000 + b"\0",
        )
        for data in invalid:
            with self.subTest(data=data[:40]):
                with self.assertRaises(ValueError):
                    reader.read_object(zlib.compress(data), object_id(data))

    def test_identity_and_strict_input_types(self):
        data = object_data(b"blob", b"hello")
        compressed = zlib.compress(data)
        oid = object_id(data)

        class BytesSubclass(bytes):
            pass

        class StrSubclass(str):
            pass

        for bad in (bytearray(compressed), memoryview(compressed), BytesSubclass(compressed),
                    None, "compressed"):
            with self.subTest(compressed_type=type(bad)):
                with self.assertRaises(ValueError):
                    reader.read_object(bad, oid)
        for bad in (oid.upper(), oid[:-1], oid + "0", "g" * 40, "0" * 40,
                    StrSubclass(oid), bytes.fromhex(oid), None, 1, "é" * 40):
            with self.subTest(oid=bad):
                with self.assertRaises(ValueError):
                    reader.read_object(compressed, bad)


if __name__ == "__main__":
    unittest.main()
