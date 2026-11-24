"""Bounded in-memory Git pack delta application; not a Git object reader."""

# See gitformat-pack(5), "Size encoding" and "Deltified representation".
BASE_LIMIT = 1024 * 1024
PROGRAM_LIMIT = 1024 * 1024
OUTPUT_LIMIT = 256 * 1024
OPERATION_LIMIT = 65536
MAX_SIZE = 2**63 - 1


def _size(program, position):
    value = 0
    for index in range(9):  # At most 63 bits; never shift an unbounded integer.
        if position == len(program):
            raise ValueError("truncated delta size")
        byte = program[position]
        position += 1
        value |= (byte & 0x7f) << (7 * index)
        if not byte & 0x80:
            if index and byte == 0:
                raise ValueError("noncanonical delta size")
            return value, position
    raise ValueError("overflowing delta size")


def apply_delta(base, program):
    """Apply one delta to explicit bytes, or raise ValueError without partial output.

    Base and program are capped at 1 MiB each, reconstructed output at 256 KiB,
    and instructions at 65536. Size varints are minimal, at most 2**63-1.
    No pack, index, compressed stream, object ID, or delta chain is processed.
    """
    return _apply_delta(base, program, BASE_LIMIT, PROGRAM_LIMIT, OUTPUT_LIMIT,
                        OPERATION_LIMIT)


def _apply_delta(base, program, base_limit, program_limit, output_limit, operation_limit):
    """apply_delta with explicit caps; only git_pack's fixed profiles select them."""
    if type(base) is not bytes or type(program) is not bytes:
        raise ValueError("delta inputs must be bytes")
    if len(base) > base_limit or len(program) > program_limit:
        raise ValueError("delta input size limit")
    base_size, position = _size(program, 0)
    output_size, position = _size(program, position)
    if base_size != len(base):
        raise ValueError("delta base size mismatch")
    if output_size > output_limit:
        raise ValueError("delta output size limit")

    output = bytearray()
    base_view = memoryview(base)
    program_view = memoryview(program)
    operations = 0
    while position < len(program):
        operations += 1
        if operations > operation_limit:
            raise ValueError("delta operation limit")
        opcode = program[position]
        position += 1
        if opcode & 0x80:
            offset = size = 0
            for bit in range(7):
                if opcode & (1 << bit):
                    if position == len(program):
                        raise ValueError("truncated delta copy")
                    byte = program[position]
                    position += 1
                    if bit < 4:
                        offset |= byte << (8 * bit)
                    else:
                        size |= byte << (8 * (bit - 4))
            if size == 0:
                size = 0x10000
            if offset > len(base) or size > len(base) - offset:
                raise ValueError("delta copy outside base")
            if size > output_size - len(output):
                raise ValueError("delta output size mismatch")
            output.extend(base_view[offset:offset + size])
        elif opcode:
            if opcode > len(program) - position:
                raise ValueError("truncated delta insert")
            if opcode > output_size - len(output):
                raise ValueError("delta output size mismatch")
            output.extend(program_view[position:position + opcode])
            position += opcode
        else:
            raise ValueError("reserved delta opcode")
    if len(output) != output_size:
        raise ValueError("delta output size mismatch")
    return bytes(output)
