# Compressed Property Exchange bodies (#858, part of #83/#48)

This is local software policy, not a MIDI interoperability certification.
M2-102-UM/M2-103-UM were **not** independently read for this work. Compression
before Mcoded7 and coding the whole body before chunking remain assumptions.
The decoder consumes an already reassembled body; this adds no negotiation,
resource interpretation, JSON decoding, transaction authority or application adoption.

## Decode and refusal order

1. Reject encoded input above 262,144 bytes (inclusive ceiling unchanged), before
   inspecting encoding or bytes (`tooLong`).
2. Refuse unknown encodings (`unsupportedEncoding`). ASCII behavior is unchanged.
3. For Mcoded7 and zlib+Mcoded7, use the existing whole-body Mcoded7 decoder:
   first high byte (`byteHigh`), then lone final header (`truncatedGroup`).
   Unused bits in a short final Mcoded7 header stay ignored.
4. For zlib+Mcoded7 only, require one RFC 1950 zlib-wrapped DEFLATE stream.
   System zlib validates termination and checksum. Empty compressed input,
   truncation, corruption, preset dictionary requirements, raw DEFLATE, gzip,
   trailing bytes and concatenated streams yield `invalidCompressedData`.
   A valid compressed empty stream succeeds.
5. The independent decoded ceiling is also 262,144 bytes, inclusive.
   `decodedTooLong(limit:)` means overflow was observed, not that the final
   uncompressed length was measured. Detected overflow wins over integrity
   failure; decoding does not continue to look for a later checksum failure.

Single-stream framing, strict trailing-byte rejection and both size limits are
engineering choices, not asserted MIDI requirements. Failure never returns a prefix.
Content retains kind/data → restricted-kind count → header → body precedence,
Get Inquiry/Set Reply absent-body skipping, envelope/request ID and parsed header
fields. A compressed empty stream is still nonempty property data for the kind
rule. Chunking/reassembly and their envelope/count policy are unchanged.

## Bound and system dependency

Normal SDK `import zlib` supplies system linkage (verified in a tiny SwiftPM probe).
One private helper uses `inflateInit_`, then one `inflate(..., Z_FINISH)` call with
a fixed 262,145-byte output buffer: only one byte beyond the limit can be produced.
It checks output size before status, requires `Z_STREAM_END` and zero unconsumed
input for success, and always ends an initialized stream. There is no retry loop,
unbounded accumulator, handwritten DEFLATE implementation or third-party package.

The installed SDK's `zlib.h` documents single-call `Z_FINISH`: all pending
input/output is processed when space suffices; otherwise the call returns without
requiring the caller to continue. Initialization failure also yields
`invalidCompressedData` with no output, rather than an unsupported-encoding fallback.

## Evidence and remaining qualification

Existing audited body/content roots cover fixed independently generated Python-zlib
goldens, binary/empty bodies, real chunk/wire/reassembly paths cut inside a Mcoded7
group, decoded boundaries, malformed streams and refusal precedence. The existing
seeded body oracle retains compressed cases using a separate bounded `uncompress2`
entry point and consumed-input check; expected fixed plaintext is never obtained
from the decoder under test.

Local selective SwiftPM evidence does not replace independent review, coordinator
registration, or native hosted compile/tests. No hardware, iOS, TSan, kernel,
persistence, transport activation or full #83/#48 completion is claimed.
