# Compressed Property Exchange bodies (#858/#865, part of #83/#48)

This is local software policy, not a MIDI interoperability certification.
M2-102-UM/M2-103-UM were **not** independently read for this work. Compression
before Mcoded7 and coding the whole body before chunking are explicitly ratified
**local policy** for #865, shared with the #858 receive assumption. This is not
a claim that #83 specified outbound compression or that a MIDI peer accepts it.
The decoder consumes an already reassembled body; the new raw-body overload
prepares messages through the existing pure chunker. Neither adds negotiation,
resource interpretation, JSON body decoding, transaction authority, transport,
emission or application adoption.

## Raw preparation API and refusal order (#865)

The one additive entry point is:

```swift
MIDICIPropertyChunker.chunks(
    _:header:requestID:headerData:rawBody:limits:
) throws(MIDICIPropertyPreparationRefusal) -> [MIDICIPropertyDataMessage]
```

The existing `propertyData:` overload still takes already encoded bytes. Its
implementation and refusals are unchanged. Preparation checks, in order:

1. Nonempty **original** raw body in Get Inquiry/Set Reply:
   `rawBodyNotAllowed(kind:count:)`, even if oversized or otherwise invalid.
2. Raw count above the independent inclusive 262,144-byte ceiling:
   `rawBodyTooLong(count:limit:)`, before header parsing or compression.
3. Parse caller-supplied `headerData` through `MIDICIPropertyHeader.parse`:
   `header(MIDICIPropertyHeaderRefusal)` unchanged. Empty header bytes are invalid;
   `{}` is valid and selects default ASCII.
4. Encode the complete body using the parsed encoding:
   - ASCII reuses `MIDICIPropertyBody.decode(..., encoding: .ascii)` as the
     identity validator, preserving controls and DEL; the first high byte is
     `body(.byteHigh(offset:))`.
   - Unknown names are `body(.unsupportedEncoding(encoding))`, including empty
     raw input for body-bearing kinds.
   - Mcoded7 preflights `n + ceil(n / 7)` before calling the existing encoder.
     At the inclusive 262,144 encoded-byte ceiling, 229,376 prepacking bytes
     fit exactly; 229,377 need 262,146 bytes and are refused before packing.
   - zlib+Mcoded7 first compresses one RFC1950 stream at SDK default compression,
     then performs the same size preflight, then packs the entire stream once.
     There is no body segmentation before compression or packing.
   - SDK bound/status failures yield `compressionFailed`; successful compression
     whose packing is too large yields `encodedBodyTooLong(count:limit:)`.
     That count is exact, not a measured prefix or the raw-body count.
5. Delegate original header bytes and prepared property bytes to the unchanged
   chunker; wrap any error as `chunking(MIDICIPropertyChunkingRefusal)` without
   changing its kind/size/payload-fit/count/chunk-factory precedence.

Get Inquiry/Set Reply with empty raw input skip step 4, **not** header parsing
or downstream chunking. Even unknown encoding names are retained and skipped.
All other kinds encode empty bodies normally: ASCII/Mcoded7 produce no property
bytes; zlib+Mcoded7 produces a nonempty packed compressed empty stream.

The parser is lossy: it drops unknown member values. Preparation reads its
encoding but never serializes it. Original header bytes, whitespace, unknown
values and key spelling/order are preserved in chunk 1. Envelope, request ID and
greedy cuts are the existing chunker's. Addressing checks remain in message
`encode(limits:)`, not preparation. The independent limits stay 16,383 chunks
for chunking and 256 for reassembly; preparation does not reconcile them.

## Raw compression storage and SDK contract

The private chunker helper uses `import zlib`, not a new compressor API or
third-party dependency. Source/API inspection used the installed
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/zlib.h`
(header version 1.2.12):

- Lines 65–67 describe the default in-memory format as RFC1950 around RFC1951.
- Lines 1255–1268 declare `compress2`: destination length is the supplied
  capacity on entry and actual compressed length on exit; capacity must be at
  least `compressBound(sourceLen)`. Success is `Z_OK`; memory, buffer and invalid
  level failures are distinct non-success codes.
- Lines 1271–1275 document `compressBound` as an upper bound for that call.
- Lines 1296–1302 document `uncompress2`'s consumed-input count, used in tests.

Every compression uses one fixed 263,168-byte Swift output array (raw ceiling
plus 1 KiB for wrapper/block overhead). Before allocating it, the helper checks
the SDK's `compressBound(raw.count)` against that capacity. A future SDK bound
that exceeds the fixed storage is refused, never accommodated by growing it.
After one `compress2` call, only `Z_OK` and a returned length within capacity
permit use of the output. Every other status discards it. The compressed length
is preflighted before copying its prefix or allocating Mcoded7 output.

Nonempty input shares the caller's immutable array; empty input supplies a
one-byte dummy array with source length zero, avoiding a null source pointer.
Pointers are scoped to the arrays for the SDK call. `compress2` owns its stream
lifecycle; this helper retains no zlib stream or partial result. It requests no
dictionary, performs no retry and has no fallback or output-growth accumulator.
Mcoded7 output is at most 262,144 bytes. Chunk/message/header parsing arrays and
the bounded compressed-prefix copy still allocate. SDK-internal allocations
are not bounded by the output array alone: this is **not realtime-safe or
whole-operation allocation-free**, nor a total-memory/CPU-time guarantee.
Compressed byte identity across SDK versions is not promised.

## Decode and refusal order (unchanged)

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

Normal SDK `import zlib` supplies system linkage (the earlier #858 slice recorded
a tiny SwiftPM probe; no such probe was run in the #865 source stage).
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

The new `MIDICIPropertyChunkerTests+Body`, `+BodyBounds`, `+BodyOrder` and
`+BodyCompatibility` extensions reuse the existing audited chunker root and its
wire encode/decode → reassembler helper, then invoke the real content decoder.
All chain fixtures require at most 256 chunks; separate count-policy fixtures
deliberately stop at chunking/wire encoding for 257/16,383 chunks.
Compressed-output expectations use fixed original plaintext, test-side arithmetic
unpacking, and the existing bounded `uncompress2` reference. That is a separate
entry point into **the same zlib**, not an independent DEFLATE implementation.
Tests do not assert compressed byte identity.

The #865 stage is source plus strict changed-Swift lint only: no compile, test
execution, mirror, native/Xcode, TSan or hardware run is claimed. Coordinator
registration must add the two production sources and four test extensions;
the existing audit root stays unchanged. Later source-faithful validation needs
the canonical MIDI closure, the chunker root (including seeded cases), header,
Mcoded7, body/content and message/reassembler helpers and their existing tests.
SDK allocation failure and a future SDK exceeding the fixed bound have no
injected runtime fixtures; those guards require source review.

Earlier local selective SwiftPM evidence does not qualify these new sources or
replace independent review, coordinator registration, or native hosted
compile/tests. No hardware, iOS-runtime, TSan, kernel, persistence, transport
activation or full #83/#48 completion is claimed.
