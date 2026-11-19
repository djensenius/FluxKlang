# Property Exchange completed-content chunk count (#846)

Part of #83/#48. This explicitly extends #828's final-content contract after
#838/#842. Previously accepted empty multi-chunk Get Inquiry and Set Reply
content now receives `singleChunkRequired(kind:chunkCount:)`.

This is intentional **local receive-content compatibility tightening**, not a
newly verified normative receiver requirement. M2-102/M2-103 were not read.
The original codec's “lenient receive, strict send” contract remains intact;
it does not require final-content leniency.

## Boundary and order

`MIDICIPropertyReassembly` now requires immutable `chunkCount: UInt16` evidence.
Single completion copies the validated input count; multi completion copies the
entry's validated declared count. There is no default or new validating factory.
Every actual completion retains the number declared by its fragments.

`MIDICIPropertyContent.decode` checks, in order:

1. Get Inquiry/Set Reply property data: existing `propertyDataNotAllowed` with
   its existing kind/byte-count payload.
2. Those kinds' count other than one: `singleChunkRequired` with exact kind and
   declared count, including zero in a directly constructed malformed value.
3. Header parsing: existing wrapped refusal unchanged.
4. Body decoding for the other kinds: existing wrapped refusal unchanged.

Count one still skips body decoding for the restricted kinds, preserving even
unsupported encoding names in the parsed header. Other kinds acquire **no**
count validation at this boundary. Successful content fields are unchanged.
Coding occurs before chunking; Mcoded7 groups may still span fragments.

## Unchanged and excluded

Reassembler admission, single-chunk pass-through, source/request keying,
limits, envelope continuity, refusal ordering, drop/restart/isolation and
discard APIs are unchanged. Codec wire behavior and receive-lenient
noncanonical device IDs are unchanged. No transport, endpoint/session identity,
request correlation, timers, persistence, hardware or live consumer is added.
Neither count nor envelope equality establishes authority or authentication.

The focused tests extend the existing audited `MIDICIPropertyContentTests`
root. They cover both restricted kinds and CI formats at counts 1/2/3 through
the real codec/reassembler/content sequence, direct zero-count inputs,
combined-defect precedence, unchanged other-kind/Mcoded7 behavior and consistent
noncanonical devices. Existing fragment-based and seeded oracles retain count
evidence; chunker round trips check actual fragment counts.

Local Debug/Release SwiftPM mirror results are algorithm evidence only, not
native target membership or audit receipts. Coordinator-owned registration,
specification hash, generated project and exact-head hosted Apple/Lint/Mac
gates remain separate requirements.
