//
//  OpenSoundControl+Bytes.swift
//  FluxKlang
//
//  Big-endian, 4-byte-aligned primitives. Every read is bounds-checked against
//  the reader's end, padding must be zero, and no length math can overflow.
//

extension OpenSoundControl {
    /// Zero bytes needed to bring `count` up to a multiple of four.
    static func padding(after count: Int) -> Int {
        (4 - count % 4) % 4
    }

    struct ByteWriter: Sendable {
        private(set) var bytes: [UInt8] = []

        mutating func append(_ value: UInt32) {
            for shift in stride(from: 24, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }

        mutating func append(_ value: UInt64) {
            append(UInt32(truncatingIfNeeded: value >> 32))
            append(UInt32(truncatingIfNeeded: value))
        }

        mutating func append(bytes values: [UInt8]) {
            bytes.append(contentsOf: values)
        }

        /// OSC-string: content, a NUL, then zeros to the next multiple of four.
        mutating func appendString(_ content: [UInt8]) {
            bytes.append(contentsOf: content)
            let terminatorAndPadding = OpenSoundControl.padding(after: content.count + 1) + 1
            bytes.append(contentsOf: [UInt8](repeating: 0, count: terminatorAndPadding))
        }

        /// OSC-blob: big-endian Int32 size, content, then zero padding.
        mutating func appendBlob(_ content: [UInt8]) {
            append(UInt32(truncatingIfNeeded: content.count))
            bytes.append(contentsOf: content)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: OpenSoundControl.padding(after: content.count)))
        }
    }

    /// Reads `bytes[offset..<end]`; nested readers share storage without copying.
    struct ByteReader: Sendable {
        private let bytes: [UInt8]
        private(set) var offset: Int
        let end: Int

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            offset = 0
            end = bytes.count
        }

        private init(_ bytes: [UInt8], offset: Int, end: Int) {
            self.bytes = bytes
            self.offset = offset
            self.end = end
        }

        var remaining: Int { end - offset }
        var isAtEnd: Bool { offset == end }
        var nextByte: UInt8? { offset < end ? bytes[offset] : nil }

        mutating func readUInt32() throws(CodecError) -> UInt32 {
            guard remaining >= 4 else { throw .truncated }
            var value: UInt32 = 0
            for byte in bytes[offset..<(offset + 4)] { value = value << 8 | UInt32(byte) }
            offset += 4
            return value
        }

        mutating func readUInt64() throws(CodecError) -> UInt64 {
            let high = try readUInt32()
            return UInt64(high) << 32 | UInt64(try readUInt32())
        }

        mutating func readBytes(_ count: Int) throws(CodecError) -> [UInt8] {
            guard count >= 0, count <= remaining else { throw .truncated }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        /// Splits off the next `count` bytes as their own reader.
        mutating func split(_ count: Int) throws(CodecError) -> ByteReader {
            guard count >= 0, count <= remaining else { throw .truncated }
            defer { offset += count }
            return ByteReader(bytes, offset: offset, end: offset + count)
        }

        /// Reads an OSC-string of at most `maximumBytes` content bytes; scanning
        /// stops after `maximumBytes + 1` bytes so oversize input costs bounded work.
        mutating func readString(maximumBytes: Int, tooLong: CodecError) throws(CodecError) -> [UInt8] {
            let scanLimit = maximumBytes < remaining ? maximumBytes + 1 : remaining
            guard let terminator = bytes[offset..<(offset + max(scanLimit, 0))].firstIndex(of: 0) else {
                throw scanLimit > maximumBytes ? tooLong : .unterminatedString
            }
            let content = Array(bytes[offset..<terminator])
            offset = terminator + 1
            try skipPadding(OpenSoundControl.padding(after: content.count + 1))
            return content
        }

        /// Reads an OSC-blob of at most `maximumBytes` bytes.
        mutating func readBlob(maximumBytes: Int) throws(CodecError) -> [UInt8] {
            let size = Int32(bitPattern: try readUInt32())
            guard size >= 0 else { throw .negativeLength(size) }
            guard Int(size) <= maximumBytes else { throw .blobTooLarge(byteCount: Int(size), limit: maximumBytes) }
            let content = try readBytes(Int(size))
            try skipPadding(OpenSoundControl.padding(after: content.count))
            return content
        }

        private mutating func skipPadding(_ count: Int) throws(CodecError) {
            guard count <= remaining else { throw .truncated }
            guard bytes[offset..<(offset + count)].allSatisfy({ $0 == 0 }) else { throw .nonZeroPadding }
            offset += count
        }
    }
}
