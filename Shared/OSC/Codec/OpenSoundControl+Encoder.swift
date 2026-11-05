//
//  OpenSoundControl+Encoder.swift
//  FluxKlang
//
//  Encodes OSC 1.0 packets. Every value is checked against the limits before it
//  is written, so the encoder only ever emits canonical bytes the decoder with
//  the same limits accepts.
//

extension OpenSoundControl {
    struct Encoder: Sendable {
        var limits: Limits

        init(limits: Limits = .standard) {
            self.limits = limits
        }

        func encode(_ packet: Packet) throws(CodecError) -> [UInt8] {
            var writer = ByteWriter()
            var elements = 0
            try write(packet, into: &writer, depth: 0, elements: &elements)
            try requireWithinPacketLimit(writer.bytes.count)
            return writer.bytes
        }

        func encode(_ message: Message) throws(CodecError) -> [UInt8] {
            try encode(.message(message))
        }

        private func requireWithinPacketLimit(_ count: Int) throws(CodecError) {
            guard count <= limits.maximumPacketBytes else {
                throw .packetTooLarge(byteCount: count, limit: limits.maximumPacketBytes)
            }
        }

        private func write(
            _ packet: Packet, into writer: inout ByteWriter, depth: Int, elements: inout Int
        ) throws(CodecError) {
            switch packet {
            case .message(let message): try write(message, into: &writer)
            case .bundle(let bundle): try write(bundle, into: &writer, depth: depth + 1, elements: &elements)
            }
        }

        private func write(_ message: Message, into writer: inout ByteWriter) throws(CodecError) {
            let address = try AddressPattern(bytes: message.address.bytes, limits: limits)
            guard message.arguments.count <= limits.maximumArguments else {
                throw .tooManyArguments(limit: limits.maximumArguments)
            }
            writer.appendString(address.bytes)
            writer.appendString([UInt8(ascii: ",")] + message.arguments.map(\.typeTag))
            for argument in message.arguments {
                try write(argument, into: &writer)
                try requireWithinPacketLimit(writer.bytes.count)
            }
        }

        private func write(_ argument: Argument, into writer: inout ByteWriter) throws(CodecError) {
            switch argument {
            case .int32(let value): writer.append(UInt32(bitPattern: value))
            case .float32(let value): writer.append(value.bitPattern)
            case .string(let value): writer.appendString(try stringBytes(value))
            case .blob(let value): writer.appendBlob(try blobBytes(value))
            case .int64(let value): writer.append(UInt64(bitPattern: value))
            case .float64(let value): writer.append(value.bitPattern)
            case .timeTag(let value): writer.append(value.rawValue)
            case .true, .false, .nil, .impulse: break
            }
        }

        private func stringBytes(_ value: String) throws(CodecError) -> [UInt8] {
            let bytes = Array(value.utf8)
            guard !bytes.contains(0) else { throw .stringContainsNul }
            guard bytes.count <= limits.maximumStringBytes else {
                throw .stringTooLong(limit: limits.maximumStringBytes)
            }
            return bytes
        }

        private func blobBytes(_ value: [UInt8]) throws(CodecError) -> [UInt8] {
            guard value.count <= limits.maximumBlobBytes, value.count <= Int(Int32.max) else {
                throw .blobTooLarge(byteCount: value.count, limit: limits.maximumBlobBytes)
            }
            return value
        }

        private func write(
            _ bundle: Bundle, into writer: inout ByteWriter, depth: Int, elements: inout Int
        ) throws(CodecError) {
            guard depth <= limits.maximumBundleDepth else { throw .bundleTooDeep(limit: limits.maximumBundleDepth) }
            writer.append(bytes: OpenSoundControl.bundleHeader)
            writer.append(bundle.timeTag.rawValue)
            for element in bundle.elements {
                elements += 1
                guard elements <= limits.maximumBundleElements else {
                    throw .tooManyElements(limit: limits.maximumBundleElements)
                }
                var nested = ByteWriter()
                try write(element, into: &nested, depth: depth, elements: &elements)
                try requireWithinPacketLimit(nested.bytes.count)
                guard nested.bytes.count <= Int(Int32.max) else {
                    throw .packetTooLarge(byteCount: nested.bytes.count, limit: limits.maximumPacketBytes)
                }
                writer.append(UInt32(truncatingIfNeeded: nested.bytes.count))
                writer.append(bytes: nested.bytes)
                try requireWithinPacketLimit(writer.bytes.count)
            }
        }
    }
}
