//
//  MIDICIPropertyBodyRefusal.swift
//  FluxKlang
//
//  Why `MIDICIPropertyBody.decode(_:encoding:)` refused property data (#83, slice M83-PXH2, issue #824). A separate
//  type from `MIDICIRefusal`, which covers the message envelope, and from `MIDICIMcoded7Refusal`, whose two cases it
//  renames. Nothing calls it yet.
//

/// The cases are listed in the order `MIDICIPropertyBody.decode(_:encoding:)` checks them. `byteHigh` and
/// `truncatedGroup` name an `offset`, an index in the property data.
enum MIDICIPropertyBodyRefusal: Error, Equatable, Hashable, Sendable {
    /// 1. More than `limit` (`MIDICIPropertyBody.maximumBytes`) bytes, in any encoding; nothing was read.
    case tooLong(count: Int, limit: Int)
    /// 2. An unknown encoding, kept as named; nothing was read.
    case unsupportedEncoding(MIDICIPropertyEncoding)
    /// 3. A byte of 0x80 or more; `offset` is the first one's.
    case byteHigh(offset: Int)
    /// 4. Either Mcoded7 encoding: a final header byte has no data byte after it; `offset` is that header's index.
    case truncatedGroup(offset: Int)
    /// 5. zlib+Mcoded7 produced at least `limit + 1` bytes. The final size is deliberately not measured.
    /// Detected overflow wins over an integrity failure; no partial output is returned.
    case decodedTooLong(limit: Int)
    /// 6. System zlib could not initialize or decode exactly one complete RFC1950 stream with a valid checksum.
    /// Includes absent/truncated/corrupt streams, dictionary requirements, trailing bytes and concatenated streams.
    case invalidCompressedData
}
