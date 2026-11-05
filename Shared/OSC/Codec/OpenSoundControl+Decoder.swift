//
//  OpenSoundControl+Decoder.swift
//  FluxKlang
//
//  Decodes one OSC 1.0 packet. Only canonical bytes are accepted (zero padding,
//  exact element sizes, no trailing bytes), so encoding a decoded packet
//  reproduces its input. Unknown type tags and tagless messages are refused.
//

extension OpenSoundControl {
    static let bundleHeader: [UInt8] = Array("#bundle".utf8) + [0]

    struct Decoder: Sendable {
        var limits: Limits

        init(limits: Limits = .standard) {
            self.limits = limits
        }

        func decode(_ bytes: [UInt8]) throws(CodecError) -> Packet {
            guard !bytes.isEmpty else { throw .emptyPacket }
            guard bytes.count <= limits.maximumPacketBytes else {
                throw .packetTooLarge(byteCount: bytes.count, limit: limits.maximumPacketBytes)
            }
            guard bytes.count % 4 == 0 else { throw .packetNotAligned(byteCount: bytes.count) }
            var reader = ByteReader(bytes)
            var elements = 0
            return try decodePacket(&reader, depth: 0, elements: &elements)
        }

        /// Decodes a packet that must be a message.
        func decodeMessage(_ bytes: [UInt8]) throws(CodecError) -> Message {
            guard case .message(let message) = try decode(bytes) else { throw .unrecognizedPacket }
            return message
        }

        private func decodePacket(
            _ reader: inout ByteReader, depth: Int, elements: inout Int
        ) throws(CodecError) -> Packet {
            switch reader.nextByte {
            case UInt8(ascii: "/"): return .message(try decodeMessage(&reader))
            case UInt8(ascii: "#"): return .bundle(try decodeBundle(&reader, depth: depth + 1, elements: &elements))
            default: throw .unrecognizedPacket
            }
        }

        private func decodeMessage(_ reader: inout ByteReader) throws(CodecError) -> Message {
            let addressBytes = try reader.readString(
                maximumBytes: limits.maximumStringBytes, tooLong: .stringTooLong(limit: limits.maximumStringBytes)
            )
            let address = try AddressPattern(bytes: addressBytes, limits: limits)
            guard reader.nextByte == UInt8(ascii: ",") else { throw .missingTypeTags }
            let tagLimit = limits.maximumArguments < Int.max ? limits.maximumArguments + 1 : Int.max
            let tags = try reader.readString(
                maximumBytes: tagLimit, tooLong: .tooManyArguments(limit: limits.maximumArguments)
            ).dropFirst()
            if let unknown = tags.first(where: { !Self.knownTags.contains($0) }) { throw .unknownTypeTag(unknown) }
            var arguments: [Argument] = []
            arguments.reserveCapacity(tags.count)
            for tag in tags { arguments.append(try decodeArgument(tag, from: &reader)) }
            guard reader.isAtEnd else { throw .trailingBytes }
            return Message(address: address, arguments: arguments)
        }

        static let knownTags = Set("ifsbhdtTFNI".utf8)
        private static let unitArguments: [UInt8: Argument] = [
            UInt8(ascii: "T"): .true, UInt8(ascii: "F"): .false, UInt8(ascii: "N"): .nil, UInt8(ascii: "I"): .impulse
        ]

        private func decodeArgument(_ tag: UInt8, from reader: inout ByteReader) throws(CodecError) -> Argument {
            switch tag {
            case UInt8(ascii: "i"): return .int32(Int32(bitPattern: try reader.readUInt32()))
            case UInt8(ascii: "f"): return .float32(Float(bitPattern: try reader.readUInt32()))
            case UInt8(ascii: "s"): return .string(try decodeString(from: &reader))
            case UInt8(ascii: "b"): return .blob(try reader.readBlob(maximumBytes: limits.maximumBlobBytes))
            case UInt8(ascii: "h"): return .int64(Int64(bitPattern: try reader.readUInt64()))
            case UInt8(ascii: "d"): return .float64(Double(bitPattern: try reader.readUInt64()))
            case UInt8(ascii: "t"): return .timeTag(TimeTag(rawValue: try reader.readUInt64()))
            default:
                guard let unit = Self.unitArguments[tag] else { throw .unknownTypeTag(tag) }
                return unit
            }
        }

        private func decodeString(from reader: inout ByteReader) throws(CodecError) -> String {
            let bytes = try reader.readString(
                maximumBytes: limits.maximumStringBytes, tooLong: .stringTooLong(limit: limits.maximumStringBytes)
            )
            guard let string = String(validating: bytes, as: UTF8.self) else { throw .invalidUTF8 }
            return string
        }

        private func decodeBundle(
            _ reader: inout ByteReader, depth: Int, elements: inout Int
        ) throws(CodecError) -> Bundle {
            guard try reader.readBytes(OpenSoundControl.bundleHeader.count) == OpenSoundControl.bundleHeader else {
                throw .unrecognizedPacket
            }
            guard depth <= limits.maximumBundleDepth else { throw .bundleTooDeep(limit: limits.maximumBundleDepth) }
            let timeTag = TimeTag(rawValue: try reader.readUInt64())
            var contents: [Packet] = []
            while !reader.isAtEnd {
                elements += 1
                guard elements <= limits.maximumBundleElements else {
                    throw .tooManyElements(limit: limits.maximumBundleElements)
                }
                let size = Int32(bitPattern: try reader.readUInt32())
                guard size > 0, size % 4 == 0 else { throw .invalidElementSize(size) }
                var element = try reader.split(Int(size))
                contents.append(try decodePacket(&element, depth: depth, elements: &elements))
            }
            return Bundle(timeTag: timeTag, elements: contents)
        }
    }
}
