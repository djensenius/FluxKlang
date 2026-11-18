//
//  MIDICIPropertyBody.swift
//  FluxKlang
//
//  The property data of a MIDI-CI Property Exchange message, decoded by the encoding its header names (#83, slice
//  M83-PXH2, issue #824): a pure, bounded decode that uses only the standard library. Nothing calls it yet.
//
//  Provenance: the Property Exchange specifications (M2-102-UM, the Common Rules, and M2-103-UM, the resources) were
//  not read. That ASCII property data is 7-bit, and that `zlib+Mcoded7` is compressed before it is Mcoded7 coded, are
//  inferred from the encoding names and were not checked against the specification. The limit (262,144 bytes) is the
//  reassembler's own ceiling (`MIDICIPropertyReassembler.propertyBytesCeiling`), not a specified value.
//

/// Decodes the property data of one Property Exchange message (`MIDICIPropertyReassembly.propertyData`, which is
/// still coded as received) by the `MIDICIPropertyEncoding` its header names. ASCII and Mcoded7 are decoded;
/// `zlib+Mcoded7` and any other name are refused, an empty body included. Rules that depend on the message kind
/// (`MIDICIPropertyDataKind.hasNoPropertyData`) and the JSON in the decoded bytes are not checked. Nothing calls it
/// yet.
enum MIDICIPropertyBody {
    /// The most property data `decode(_:encoding:)` accepts, inclusive: the reassembler's ceiling, 262,144 bytes.
    static let maximumBytes = MIDICIPropertyReassembler.propertyBytesCeiling

    /// Decodes property data. It refuses, in this order:
    /// 1. more than `maximumBytes` (262,144) bytes, as `tooLong`, before reading any byte, in every encoding;
    /// 2. `zlib+Mcoded7` or any other name, as `unsupportedEncoding`, before reading any byte;
    /// 3. a byte of 0x80 or more, as `byteHigh` at the first one;
    /// 4. for Mcoded7, a lone header byte at the end, as `truncatedGroup` at its offset.
    ///
    /// ASCII is returned as a byte-for-byte copy: control bytes and DEL are kept, and the text is not checked. Mcoded7
    /// is `MIDICIMcoded7.decode` with its refusals renamed, so the header bits beyond the data of a short final group
    /// are ignored, as there.
    static func decode(
        _ bytes: [UInt8], encoding: MIDICIPropertyEncoding
    ) throws(MIDICIPropertyBodyRefusal) -> [UInt8] {
        guard bytes.count <= maximumBytes else { throw .tooLong(count: bytes.count, limit: maximumBytes) }
        switch encoding {
        case .ascii:
            if let offset = bytes.firstIndex(where: { $0 >= 0x80 }) { throw .byteHigh(offset: offset) }
            return bytes
        case .mcoded7:
            do throws(MIDICIMcoded7Refusal) {
                return try MIDICIMcoded7.decode(bytes)
            } catch {
                switch error {
                case .dataByteHigh(let offset): throw .byteHigh(offset: offset)
                case .truncatedGroup(let offset): throw .truncatedGroup(offset: offset)
                }
            }
        case .zlibMcoded7, .other:
            throw .unsupportedEncoding(encoding)
        }
    }
}

extension MIDICIPropertyHeader {
    /// Decodes `bytes`, the property data of this header's message, by this header's `encoding` (`.ascii` when
    /// `mutualEncoding` is absent), as `MIDICIPropertyBody.decode(_:encoding:)` does. Nothing calls it yet.
    func decodeBody(_ bytes: [UInt8]) throws(MIDICIPropertyBodyRefusal) -> [UInt8] {
        try MIDICIPropertyBody.decode(bytes, encoding: encoding)
    }
}
