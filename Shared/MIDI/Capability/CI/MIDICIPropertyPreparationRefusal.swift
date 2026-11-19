//
//  MIDICIPropertyPreparationRefusal.swift
//  FluxKlang
//
//  Typed refusals for the additive raw-body chunker overload (#865, part of #83/#48).
//  The encoded-byte chunker and receive refusal types are unchanged.
//

/// First failure in raw-body preparation order. No failure returns partial bytes or chunks.
enum MIDICIPropertyPreparationRefusal: Error, Equatable, Hashable, Sendable {
    /// 1. Get Inquiry or Set Reply received a nonempty ORIGINAL body, before any size or byte check.
    case rawBodyNotAllowed(kind: MIDICIPropertyDataKind, count: Int)
    /// 2. The original body exceeds the independent inclusive 262,144-byte raw ceiling.
    case rawBodyTooLong(count: Int, limit: Int)
    /// 3. The original header bytes failed the existing parser, with its refusal unchanged.
    case header(MIDICIPropertyHeaderRefusal)
    /// 4. Existing ASCII validation or an unsupported encoding name. Preparation uses only `byteHigh`
    /// and `unsupportedEncoding`; it never invokes the compressed receive decoder.
    case body(MIDICIPropertyBodyRefusal)
    /// 4. System zlib could not prepare a complete stream within the fixed SDK-call storage contract.
    /// Includes a compression bound larger than the fixed buffer, or any non-Z_OK compression return.
    case compressionFailed
    /// 4. Whole-body encoding would exceed the inclusive 262,144-byte encoded ceiling.
    /// `count` is exact, computed before allocating Mcoded7 output, including after compression.
    case encodedBodyTooLong(count: Int, limit: Int)
    /// 5. The existing encoded-byte chunker refused, with its refusal and internal precedence unchanged.
    case chunking(MIDICIPropertyChunkingRefusal)
}
