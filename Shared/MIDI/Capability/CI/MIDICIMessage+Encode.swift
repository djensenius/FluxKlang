/// 7-bit-per-byte, least significant byte first, as MUIDs, sizes and 14-bit lengths are coded in MIDI-CI.
enum MIDICIWire {
    static func encode(_ value: UInt32, byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8((value >> UInt32(7 * $0)) & 0x7F) }
    }

    /// `bytes` are 7-bit data bytes (the decoder checks every byte after 0x7E first).
    static func decode(_ bytes: [UInt8]) -> UInt32 {
        bytes.reversed().reduce(0) { ($0 << 7) | UInt32($1) }
    }
}

extension MIDICIMessage {
    /// The canonical payload (without F0 and F7) for this message. Every cross-field rule is checked here, at the
    /// point of use, whatever built the header; the result is a pure function of the message and the limits.
    /// Refusal order: a CI 1.1 ACK (`unsupportedFormat(1)`), `sourceIsBroadcast`, the destination rule, then the
    /// body (output path id, function block pairing, function block range, the NAK report pairing, the Invalidate
    /// target, the text length) and last `payloadTooLarge`, which depends on the body size.
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        guard !(kind == .ack && header.format == .ci11) else { throw .unsupportedFormat(header.format.rawValue) }
        try Self.validateAddressing(kind, source: header.source, destination: header.destination)
        let body = try encodedBody(limits: limits)
        let total = MIDICILayout.headerBytes + body.count
        guard total <= limits.maximumPayloadBytes else { throw .payloadTooLarge(total) }
        let prefix: [UInt8] = [
            MIDICILayout.universalNonRealTime, header.device.rawValue, MIDICILayout.ciSubID1,
            kind.rawValue, header.format.rawValue
        ]
        return prefix + MIDICIWire.encode(header.source.rawValue, byteCount: 4)
            + MIDICIWire.encode(header.destination.rawValue, byteCount: 4) + body
    }

    private func encodedBody(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        switch self {
        case let .discovery(header, info):
            return try Self.discoveryBody(info, format: header.format)
        case let .discoveryReply(header, info, block):
            let body = try Self.discoveryBody(info, format: header.format)
            return body + (try Self.functionBlockBytes(block, format: header.format))
        case let .invalidateMUID(_, target):
            guard !target.isBroadcast else { throw .targetIsBroadcast }
            return MIDICIWire.encode(target.rawValue, byteCount: 4)
        case let .ack(_, report):
            return try Self.statusBody(report, limits: limits)
        case let .nak(header, report):
            switch (header.format, report) {
            case (.ci11, .some): throw .statusReportNotAllowed
            case (.ci12, .none): throw .statusReportRequired
            case (.ci11, .none): return []
            case let (.ci12, .some(report)): return try Self.statusBody(report, limits: limits)
            }
        }
    }

    private static func functionBlockBytes(_ block: UInt8?, format: MIDICIFormat) throws(MIDICIRefusal) -> [UInt8] {
        switch (format, block) {
        case (.ci11, .some): throw .functionBlockNotAllowed
        case (.ci12, .none): throw .functionBlockRequired
        case (.ci11, .none): return []
        case let (.ci12, .some(value)):
            guard value < 0x80 else { throw .fieldOutOfRange(.functionBlock, value: Int(value)) }
            return [value]
        }
    }

    private static func discoveryBody(
        _ info: MIDICIDiscoveryInfo, format: MIDICIFormat
    ) throws(MIDICIRefusal) -> [UInt8] {
        var pathByte: [UInt8] = []
        switch (format, info.outputPathID) {
        case (.ci11, .some): throw .outputPathIDNotAllowed
        case (.ci12, .none): throw .outputPathIDRequired
        case let (.ci12, .some(path)): pathByte = [path]
        case (.ci11, .none): break
        }
        let identity = info.identity
        return identity.manufacturer
            + MIDICIWire.encode(UInt32(identity.family), byteCount: 2)
            + MIDICIWire.encode(UInt32(identity.model), byteCount: 2)
            + identity.softwareRevision
            + [info.capabilityCategory]
            + MIDICIWire.encode(info.maximumSysExSize, byteCount: 4)
            + pathByte
    }

    private static func statusBody(
        _ report: MIDICIStatusReport, limits: MIDICILimits
    ) throws(MIDICIRefusal) -> [UInt8] {
        let textCount = report.text.utf8.count
        guard textCount <= limits.maximumTextBytes else { throw .textTooLong(textCount) }
        let fixed = [report.originalSubID, report.statusCode, report.statusData] + report.details
        return fixed + MIDICIWire.encode(UInt32(textCount), byteCount: 2) + Array(report.text.utf8)
    }
}
