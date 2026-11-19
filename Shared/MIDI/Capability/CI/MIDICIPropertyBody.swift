//
//  MIDICIPropertyBody.swift
//  FluxKlang
//
//  The property data of a MIDI-CI Property Exchange message, decoded by the encoding its header names (#83, slice
//  M83-PXH2, issue #824; compressed bodies #858): a bounded decode using the standard library and system zlib. Only
//  `MIDICIPropertyContent.decode(_:)` calls it, and nothing calls that yet.
//
//  Provenance: the Property Exchange specifications (M2-102-UM, the Common Rules, and M2-103-UM, the resources) were
//  not read. That ASCII property data is 7-bit, and that `zlib+Mcoded7` is compressed before it is Mcoded7 coded, are
//  inferred from the encoding names and were not checked against the specification. The limit (262,144 bytes) is the
//  reassembler's own ceiling (`MIDICIPropertyReassembler.propertyBytesCeiling`), not a specified value.
//

import zlib

/// Decodes the property data of one Property Exchange message (`MIDICIPropertyReassembly.propertyData`, which is
/// still coded as received) by the `MIDICIPropertyEncoding` its header names. ASCII, Mcoded7 and
/// `zlib+Mcoded7` are decoded; other names are refused. Rules that depend on the message kind
/// (`MIDICIPropertyDataKind.hasNoPropertyData`) and the JSON in the decoded bytes are not checked here; the kind rule
/// is `MIDICIPropertyContent.decode(_:)`'s. Only `MIDICIPropertyContent.decode(_:)` calls it, through
/// `decodeBody(_:)`, and nothing calls that yet.
enum MIDICIPropertyBody {
    /// The most property data `decode(_:encoding:)` accepts, inclusive: the reassembler's ceiling, 262,144 bytes.
    static let maximumBytes = MIDICIPropertyReassembler.propertyBytesCeiling

    /// Decodes property data. It refuses, in this order:
    /// 1. more than `maximumBytes` (262,144) bytes, as `tooLong`, before reading any byte, in every encoding;
    /// 2. an unknown name, as `unsupportedEncoding`, before reading any byte;
    /// 3. a byte of 0x80 or more, as `byteHigh` at the first one;
    /// 4. for either Mcoded7 encoding, a lone header byte at the end, as `truncatedGroup` at its offset;
    /// 5. for zlib+Mcoded7, decoded overflow as `decodedTooLong`, otherwise a stream that cannot be decoded
    ///    completely as `invalidCompressedData`. Detected overflow wins without continuing inflation.
    ///
    /// ASCII is returned as a byte-for-byte copy: control bytes and DEL are kept, and the text is not checked. Mcoded7
    /// is `MIDICIMcoded7.decode` with its refusals renamed, so the header bits beyond the data of a short final group
    /// are ignored, as there. zlib+Mcoded7 then inflates one RFC1950 stream, with an independent inclusive
    /// `maximumBytes` output ceiling. Single-stream framing and rejection of trailing bytes/dictionaries are local
    /// policy. Compression before Mcoded7 before whole-body chunking is assumed, not specification-verified.
    static func decode(
        _ bytes: [UInt8], encoding: MIDICIPropertyEncoding
    ) throws(MIDICIPropertyBodyRefusal) -> [UInt8] {
        guard bytes.count <= maximumBytes else { throw .tooLong(count: bytes.count, limit: maximumBytes) }
        switch encoding {
        case .ascii:
            if let offset = bytes.firstIndex(where: { $0 >= 0x80 }) { throw .byteHigh(offset: offset) }
            return bytes
        case .mcoded7, .zlibMcoded7:
            let decoded: [UInt8]
            do throws(MIDICIMcoded7Refusal) {
                decoded = try MIDICIMcoded7.decode(bytes)
            } catch {
                switch error {
                case .dataByteHigh(let offset): throw .byteHigh(offset: offset)
                case .truncatedGroup(let offset): throw .truncatedGroup(offset: offset)
                }
            }
            return encoding == .mcoded7 ? decoded : try inflateBody(decoded)
        case .other:
            throw .unsupportedEncoding(encoding)
        }
    }

    /// One bounded system call: zlib's Z_FINISH processes all input when the supplied output space suffices.
    /// No retry/accumulator can materialize more than one byte beyond the decoded ceiling. Pointers stay scoped
    /// to their arrays, zlib does not mutate input, and every initialized stream is ended on every return path.
    private static func inflateBody(_ compressed: [UInt8]) throws(MIDICIPropertyBodyRefusal) -> [UInt8] {
        guard !compressed.isEmpty else { throw .invalidCompressedData }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw .invalidCompressedData
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: maximumBytes + 1)
        let status = compressed.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        // Size first, even when this call also found an integrity error. Never continue to seek a later checksum.
        guard stream.total_out <= maximumBytes else { throw .decodedTooLong(limit: maximumBytes) }
        guard status == Z_STREAM_END, stream.avail_in == 0 else { throw .invalidCompressedData }
        return Array(output.prefix(Int(stream.total_out)))
    }
}

extension MIDICIPropertyHeader {
    /// Decodes `bytes`, the property data of this header's message, by this header's `encoding` (`.ascii` when
    /// `mutualEncoding` is absent), as `MIDICIPropertyBody.decode(_:encoding:)` does. Only
    /// `MIDICIPropertyContent.decode(_:)` calls it, and nothing calls that yet.
    func decodeBody(_ bytes: [UInt8]) throws(MIDICIPropertyBodyRefusal) -> [UInt8] {
        try MIDICIPropertyBody.decode(bytes, encoding: encoding)
    }
}
