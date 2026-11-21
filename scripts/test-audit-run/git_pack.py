"""Pure, bounded reader for an explicitly supplied SHA-1 pack and v2 index."""

import hashlib
import re
import struct
import zlib

import git_delta


PACK_LIMIT = 8 * 1024 * 1024
INDEX_LIMIT = 1024 * 1024
OBJECT_COUNT_LIMIT = 4096
OBJECT_LIMIT = 256 * 1024
INFLATE_LIMIT = 8 * 1024 * 1024
RESULT_LIMIT = 8 * 1024 * 1024
DEPTH_LIMIT = 32
READER_CALL_LIMIT = 64
READER_PARSE_LIMIT = 2
KINDS = {1: "commit", 2: "tree", 3: "blob", 4: "tag"}


def _u32(data, position):
    return struct.unpack_from(">I", data, position)[0]


def _fail(message):
    raise ValueError(message)


def _entry_header(pack, start, end):
    position = start
    byte = pack[position]
    position += 1
    kind = (byte >> 4) & 7
    size = byte & 15
    shift = 4
    # The input pack is capped; reject huge/nonminimal header integers.
    while byte & 128:
        if position == end or shift > 25:
            _fail("invalid object size header")
        byte = pack[position]
        position += 1
        size |= (byte & 127) << shift
        shift += 7
        if not byte & 128 and byte == 0:
            _fail("noncanonical object size header")
    if kind not in (*KINDS, 6, 7):
        _fail("unsupported object type")
    if size > (git_delta.PROGRAM_LIMIT if kind in (6, 7) else OBJECT_LIMIT):
        _fail("object size limit")
    base = None
    if kind == 7:
        if end - position < 20:
            _fail("truncated reference base")
        base = pack[position:position + 20]
        position += 20
    elif kind == 6:
        if position == end:
            _fail("truncated offset base")
        byte = pack[position]
        position += 1
        distance = byte & 127
        while byte & 128:
            if position == end or distance >= PACK_LIMIT:
                _fail("invalid offset base")
            byte = pack[position]
            position += 1
            distance = ((distance + 1) << 7) | (byte & 127)
        if not distance or distance > start - 12:
            _fail("invalid offset base")
        base = start - distance
    if position == end:
        _fail("missing compressed stream")
    return kind, size, base, position


def _inputs(pack, index):
    if type(pack) is not bytes or type(index) is not bytes:
        _fail("pack and index must be bytes")
    if len(pack) > PACK_LIMIT or len(index) > INDEX_LIMIT:
        _fail("input size limit")


def _oid(oid):
    if type(oid) is not str or re.fullmatch(r"[0-9a-f]{40}", oid, re.ASCII) is None:
        _fail("invalid object ID")
    return bytes.fromhex(oid)


def _parse(pack, index):
    _inputs(pack, index)
    if len(pack) < 32 or pack[:8] != b"PACK\0\0\0\2":
        _fail("unsupported pack header")
    if len(index) < 8 + 1024 + 40 or index[:8] != b"\xfftOc\0\0\0\2":
        _fail("unsupported index header")
    if hashlib.sha1(memoryview(pack)[:-20]).digest() != pack[-20:]:
        _fail("pack checksum mismatch")
    if (hashlib.sha1(memoryview(index)[:-20]).digest() != index[-20:]
            or index[-40:-20] != pack[-20:]):
        _fail("index checksum or pack identity mismatch")
    count = _u32(index, 8 + 255 * 4)
    if count > OBJECT_COUNT_LIMIT or _u32(pack, 8) != count:
        _fail("object count limit or mismatch")
    names_start = 8 + 1024
    crc_start = names_start + 20 * count
    offsets_start = crc_start + 4 * count
    large_start = offsets_start + 4 * count
    if large_start + 40 > len(index) or (len(index) - large_start - 40) % 8:
        _fail("invalid index length")
    large_count = (len(index) - large_start - 40) // 8
    if large_count > count:
        _fail("invalid large offset table")
    names = []
    offsets = []
    used_large = set()
    fanout = [0] * 256
    for i in range(count):
        name = index[names_start + 20 * i:names_start + 20 * (i + 1)]
        if names and name <= names[-1]:
            _fail("duplicate or unsorted object ID")
        names.append(name)
        fanout[name[0]] += 1
        offset = _u32(index, offsets_start + 4 * i)
        if offset & 0x80000000:
            slot = offset & 0x7fffffff
            if slot >= large_count or slot in used_large:
                _fail("invalid large offset reference")
            used_large.add(slot)
            offset = struct.unpack_from(">Q", index, large_start + 8 * slot)[0]
            if offset < 0x80000000:
                _fail("noncanonical large offset")
        if offset < 12 or offset >= len(pack) - 20:
            _fail("invalid object offset")
        offsets.append(offset)
    if len(used_large) != large_count:
        _fail("unused large offsets")
    total = 0
    for i, n in enumerate(fanout):
        total += n
        if _u32(index, 8 + 4 * i) != total:
            _fail("invalid index fanout")
    if len(set(offsets)) != count:
        _fail("duplicate object offset")
    ordered = sorted(offsets)
    if (ordered and ordered[0] != 12) or (not ordered and len(pack) != 32):
        _fail("pack object layout mismatch")
    by_offset = {offset: i for i, offset in enumerate(offsets)}
    by_name = {name: i for i, name in enumerate(names)}
    records = [None] * count
    inflated = 0
    view = memoryview(pack)
    for number, start in enumerate(ordered):
        end = ordered[number + 1] if number + 1 < count else len(pack) - 20
        i = by_offset[start]
        if zlib.crc32(view[start:end]) != _u32(index, crc_start + 4 * i):
            _fail("object CRC mismatch")
        kind, size, base, position = _entry_header(pack, start, end)
        inflated += size
        if inflated > INFLATE_LIMIT:
            _fail("aggregate inflate limit")
        try:
            decoder = zlib.decompressobj()
            data = decoder.decompress(view[position:end], size + 1)
        except zlib.error as error:
            raise ValueError("invalid compressed stream") from error
        if (len(data) != size or not decoder.eof or decoder.unconsumed_tail
                or decoder.unused_data):
            _fail("compressed stream size or boundary mismatch")
        if kind == 6:
            if base not in by_offset:
                _fail("offset base outside pack")
            base = by_offset[base]
        elif kind == 7:
            if base not in by_name:
                _fail("reference base outside pack")
            base = by_name[base]
        records[i] = (kind, data, base)

    results = [None] * count
    active = set()
    result_bytes = 0

    def resolve(i):
        nonlocal result_bytes
        if results[i] is not None:
            return results[i]
        if i in active or len(active) >= DEPTH_LIMIT:
            _fail("cyclic or overly deep delta chain")
        active.add(i)
        kind, data, base = records[i]
        if base is None:
            result = (KINDS[kind], data, 1)
        else:
            base_kind, base_data, depth = resolve(base)
            if depth >= DEPTH_LIMIT:
                _fail("delta depth limit")
            data = git_delta.apply_delta(base_data, data)
            result = (base_kind, data, depth + 1)
        result_bytes += len(data)
        if result_bytes > RESULT_LIMIT:
            _fail("aggregate result limit")
        digest = hashlib.sha1()
        digest.update(f"{result[0]} {len(data)}\0".encode("ascii"))
        digest.update(data)
        if digest.digest() != names[i]:
            _fail("object identity mismatch")
        active.remove(i)
        results[i] = result
        return result

    for i in range(count):
        resolve(i)
    return {name: (results[i][0], results[i][1]) for i, name in enumerate(names)}


def _lookup(objects, oid):
    name = _oid(oid)
    if name not in objects:
        _fail("object unavailable")
    return objects[name]


def read_object(pack, index, oid):
    """Return (kind, raw bytes), or ValueError; validate the entire supplied pack."""
    _inputs(pack, index)
    _oid(oid)
    return _lookup(_parse(pack, index), oid)


class BoundedReader:
    """One observe/validate invocation's bounded, explicit-input object adapter."""

    def __init__(self):
        self._calls = 0
        self._parses = 0
        self._cached = None
        self._failed = False

    def read(self, pack, index, oid):
        """Read freshly supplied bytes; raise KeyError on any parser refusal."""
        try:
            if self._failed:
                _fail("reader already refused")
            self._calls += 1
            if self._calls > READER_CALL_LIMIT:
                _fail("reader call limit")
            _inputs(pack, index)
            _oid(oid)
            if (self._cached is None or pack != self._cached[0]
                    or index != self._cached[1]):
                self._cached = None
                self._parses += 1
                if self._parses > READER_PARSE_LIMIT:
                    _fail("reader parse limit")
                objects = _parse(pack, index)
                self._cached = (pack, index, objects)
            return _lookup(self._cached[2], oid)
        except ValueError as error:
            self._cached = None
            self._failed = True
            raise KeyError("Git pack observation unavailable") from error
