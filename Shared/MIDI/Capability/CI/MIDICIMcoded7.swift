//
//  MIDICIMcoded7.swift
//  FluxKlang
//
//  Mcoded7, the 7-bit encoding MIDI-CI Property Exchange uses to carry 8-bit data inside System Exclusive messages,
//  where every data byte must be below 0x80 (#83, slice MCO1). A pure value pair; nothing calls it yet.
//
//  Layout: the data is cut into groups of up to 7 bytes. A group is one header byte followed by one byte per data
//  byte, each holding the low 7 bits. Data byte k of a group (0 to 6) has its bit 7 at header bit 6 - k; header bit 7
//  is 0, and the unused header bits of a short final group are 0 when encoding. There is no empty trailing group.
//
//  Sources: the bit order was checked against two public implementations that agree (JUCE `juce_CIEncodings.cpp` and
//  AM_MIDI2.0Lib `mcoded7.h`). The ktmidi source orders the header bits the other way and is not followed. The
//  MIDI Association specification text (M2-103-UM) was not read. Decoding refuses a byte of 0x80 or more first, then
//  a lone header byte at the end (the second is this codec's own judgment), and ignores header bits beyond the data
//  of a short final group, as JUCE does.
//

enum MIDICIMcoded7 {
    private static let groupDataBytes = 7

    /// Encodes any bytes as bytes that are all below 0x80. The output is `8 * (n / 7)` bytes plus `n % 7 + 1` more
    /// when `n % 7` is not 0.
    static func encode(_ bytes: [UInt8]) -> [UInt8] {
        let remainder = bytes.count % groupDataBytes
        var output: [UInt8] = []
        output.reserveCapacity(8 * (bytes.count / groupDataBytes) + (remainder == 0 ? 0 : remainder + 1))
        var start = 0
        while start < bytes.count {
            let end = min(start + groupDataBytes, bytes.count)
            var header: UInt8 = 0
            for index in start..<end where bytes[index] & 0x80 != 0 {
                header |= 1 << UInt8(6 - (index - start))
            }
            output.append(header)
            for index in start..<end {
                output.append(bytes[index] & 0x7F)
            }
            start = end
        }
        return output
    }

    /// Decodes Mcoded7, refusing a byte of 0x80 or more (the first one, by index) before a lone final header byte.
    static func decode(_ encoded: [UInt8]) throws(MIDICIMcoded7Refusal) -> [UInt8] {
        for (offset, byte) in encoded.enumerated() where byte >= 0x80 {
            throw .dataByteHigh(offset: offset)
        }
        if encoded.count % 8 == 1 {
            throw .truncatedGroup(offset: encoded.count - 1)
        }
        var output: [UInt8] = []
        output.reserveCapacity(encoded.count)
        var start = 0
        while start < encoded.count {
            let header = encoded[start]
            let end = min(start + 8, encoded.count)
            for index in (start + 1)..<end {
                let highBit = (header >> UInt8(6 - (index - start - 1))) & 1
                output.append(encoded[index] | (highBit << 7))
            }
            start = end
        }
        return output
    }
}
