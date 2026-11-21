"""Pure, bounded decoder for an explicitly supplied SHA-1 loose object."""

import hashlib
import re
import zlib


OBJECT_LIMIT = 256 * 1024
COMPRESSED_LIMIT = 264 * 1024
# "commit 262144\0" is the longest accepted header.
INFLATED_LIMIT = OBJECT_LIMIT + len(b"commit 262144\0")
HEADER = re.compile(rb"(commit|tree|blob|tag) (0|[1-9][0-9]{0,5})")


def read_object(compressed, oid):
    """Return (kind, raw bytes), or raise ValueError on refusal."""
    if type(compressed) is not bytes:
        raise ValueError("compressed object must be bytes")
    if len(compressed) > COMPRESSED_LIMIT:
        raise ValueError("compressed object size limit")
    if (type(oid) is not str or len(oid) != 40
            or re.fullmatch(r"[0-9a-f]{40}", oid, re.ASCII) is None):
        raise ValueError("invalid object ID")

    try:
        decoder = zlib.decompressobj()
        data = decoder.decompress(compressed, INFLATED_LIMIT + 1)
    except zlib.error as error:
        raise ValueError("invalid compressed stream") from error
    if (len(data) > INFLATED_LIMIT or not decoder.eof
            or decoder.unconsumed_tail or decoder.unused_data):
        raise ValueError("compressed stream size or boundary mismatch")

    end = data.find(b"\0", 0, len(b"commit 262144\0"))
    if end == -1:
        raise ValueError("invalid object header")
    header = HEADER.fullmatch(data[:end])
    if header is None:
        raise ValueError("invalid object header")
    size = int(header.group(2))
    if size > OBJECT_LIMIT or len(data) - end - 1 != size:
        raise ValueError("object size mismatch or limit")
    if hashlib.sha1(data).hexdigest() != oid:
        raise ValueError("object identity mismatch")
    return header.group(1).decode("ascii"), data[end + 1:]
