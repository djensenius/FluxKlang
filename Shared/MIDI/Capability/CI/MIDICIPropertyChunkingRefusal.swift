//
//  MIDICIPropertyChunkingRefusal.swift
//  FluxKlang
//
//  Why `MIDICIPropertyChunker.chunks(_:header:requestID:headerData:propertyData:limits:)` refused to cut a Property
//  Exchange message into chunks (#83, slice M83-PXO, issue #831). A separate type from `MIDICIRefusal`, which covers
//  the message envelope; it wraps a refusal of `MIDICIPropertyChunk.make` unchanged. Nothing calls it yet.
//

/// The cases are listed in the order `MIDICIPropertyChunker.chunks` checks them. Cases 1 to 4 are arithmetic on the
/// lengths and the limit: no byte is read and no chunk is built before they pass.
enum MIDICIPropertyChunkingRefusal: Error, Equatable, Hashable, Sendable {
    /// 1. Property data in a kind without it (`MIDICIPropertyDataKind.hasNoPropertyData`: Get Inquiry and Set Reply);
    /// `count` is its length in bytes.
    case propertyDataNotAllowed(kind: MIDICIPropertyDataKind, count: Int)
    /// 2. More property data than `MIDICIPropertyReassembler.propertyBytesCeiling` (262,144 bytes).
    case propertyDataTooLong(count: Int, limit: Int)
    /// 3. `limits.maximumPayloadBytes` cannot hold the first chunk's header data, or one byte of a non-empty property
    /// data: `needed` is the smallest payload limit that can.
    case payloadLimitTooSmall(needed: Int, limit: Int)
    /// 4. More chunks than the 14-bit chunk count holds (`MIDICIPropertyChunk.maximumFieldValue`, 16,383).
    case tooManyChunks(count: Int, limit: Int)
    /// 5. `MIDICIPropertyChunk.make` refused a chunk (the first one that fails, in chunk order); the refusal is
    /// unchanged.
    case chunk(MIDICIRefusal)
}
