/// A bounds-checked cursor over a payload: a read past the end throws `truncated` and never touches the array.
struct MIDICIReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int) {
        self.bytes = bytes
        self.offset = offset
    }

    mutating func take(_ count: Int) throws(MIDICIRefusal) -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else {
            throw .truncated(need: offset + count, have: bytes.count)
        }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func byte() throws(MIDICIRefusal) -> UInt8 {
        try take(1)[0]
    }

    mutating func wireValue(byteCount: Int) throws(MIDICIRefusal) -> UInt32 {
        MIDICIWire.decode(try take(byteCount))
    }
}

extension MIDICIMessage {
    /// Decodes a payload as `MIDI1Event.sysEx` carries it (F0 and F7 excluded, so byte 0 is 0x7E). Every byte after
    /// the first must be a 7-bit data byte; the length must be exact. The first failing step wins, in this order:
    ///  1. size: more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is
    ///     `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (offset 2 is always `notCI`,
    ///     because step 2 runs first);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x70, 0x71, 0x7D, 0x7E or 0x7F: `unknownSubID` (this includes valid MIDI-CI
    ///     sub-ids that this slice does not decode, such as 0x72, 0x73 and the profile and property exchange);
    ///  6. format (byte 4) not 1 or 2: `unsupportedFormat`; an ACK in CI 1.1 is `unsupportedFormat(1)` too, because
    ///     no source reviewed defines it;
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the length of the kind: Discovery is 29 (CI 1.1) or 30 (CI 1.2), Discovery Reply is 29 or 31, Invalidate
    ///     MUID is 17, a CI 1.1 NAK is 13, an ACK or a CI 1.2 NAK is 23 plus the declared text length. For an ACK
    ///     and a CI 1.2 NAK (a CI 1.1 NAK needs 13 bytes): fewer than 23 bytes is `truncated(23)`, then a declared
    ///     text length above the limit is `textTooLong`, then fewer bytes than expected is `truncated(expected)`,
    ///     then more is `trailingBytes`;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first, then the
    ///     destination);
    /// 10. addressing: `sourceIsBroadcast`, then `destinationNotBroadcast` (Discovery, Invalidate MUID) or
    ///     `destinationIsBroadcast` (the others);
    /// 11. the device id (always 7-bit by then);
    /// 12. the body, in field order: identity, capability category, size limit, output path id, the Invalidate
    ///     target (`invalidMUID`, then `targetIsBroadcast`), the status report fields and the text.
    /// The `fieldOutOfRange` and `fieldLength` refusals of step 12 are defensive: steps 3 and 8 make them
    /// unreachable on decode (by inspection; no test reaches them). The text of ACK and NAK is 7-bit ASCII but may
    /// hold control bytes (0x00-0x1F and 0x7F): sanitise it before logging or showing it.
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIMessage {
        try checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard let format = MIDICIFormat(rawValue: payload[4]) else { throw .unsupportedFormat(payload[4]) }
        guard !(kind == .ack && format == .ci11) else { throw .unsupportedFormat(format.rawValue) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        try checkLength(payload, kind: kind, format: format, limits: limits)
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try validateAddressing(kind, source: source, destination: destination)
        let device = try wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: format, source: source, destination: destination)
        return try decodeBody(kind, header: header, reader: &reader)
    }

    /// Unreachable by inspection (the decoder has already refused every byte of 0x80 or more); no test reaches it.
    private static func wrapDevice(_ byte: UInt8) throws(MIDICIRefusal) -> SysExDeviceID {
        do {
            return try SysExDeviceID(byte)
        } catch {
            throw .dataByteHigh(offset: 1)
        }
    }

    /// Size, notCI and 7-bit checks that need only the first bytes. Afterwards `payload.count >= 5`.
    private static func checkEnvelope(_ payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) {
        guard payload.count <= limits.maximumPayloadBytes else { throw .payloadTooLarge(payload.count) }
        guard let first = payload.first else { throw .truncated(need: 1, have: 0) }
        guard first == MIDICILayout.universalNonRealTime else { throw .notCI }
        if payload.count >= 3, payload[2] != MIDICILayout.ciSubID1 { throw .notCI }
        if let offset = payload.indices.dropFirst().first(where: { payload[$0] >= 0x80 }) {
            throw .dataByteHigh(offset: offset)
        }
        guard payload.count >= MIDICILayout.prefixBytes else {
            throw .truncated(need: MIDICILayout.prefixBytes, have: payload.count)
        }
    }

    private static func checkLength(
        _ payload: [UInt8], kind: MIDICIKind, format: MIDICIFormat, limits: MIDICILimits
    ) throws(MIDICIRefusal) {
        let expected: Int
        switch kind {
        case .discovery:
            expected = MIDICILayout.headerBytes + MIDICILayout.discoveryBodyBytes + (format == .ci12 ? 1 : 0)
        case .discoveryReply:
            expected = MIDICILayout.headerBytes + MIDICILayout.discoveryBodyBytes + (format == .ci12 ? 2 : 0)
        case .invalidateMUID:
            expected = MIDICILayout.headerBytes + MIDICILayout.invalidateBodyBytes
        case .nak where format == .ci11:
            expected = MIDICILayout.headerBytes
        case .ack, .nak:
            guard payload.count >= MIDICILayout.statusBytesBeforeText else {
                throw .truncated(need: MIDICILayout.statusBytesBeforeText, have: payload.count)
            }
            let declared = Int(MIDICIWire.decode(Array(payload[21...22])))
            guard declared <= limits.maximumTextBytes else { throw .textTooLong(declared) }
            expected = MIDICILayout.statusBytesBeforeText + declared
        }
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
    }

    private static func decodeBody(
        _ kind: MIDICIKind, header: MIDICIHeader, reader: inout MIDICIReader
    ) throws(MIDICIRefusal) -> MIDICIMessage {
        switch kind {
        case .discovery:
            return .discovery(header, try decodeDiscovery(format: header.format, reader: &reader))
        case .discoveryReply:
            let info = try decodeDiscovery(format: header.format, reader: &reader)
            let block: UInt8? = header.format == .ci12 ? try reader.byte() : nil
            return .discoveryReply(header, info, functionBlock: block)
        case .invalidateMUID:
            let target = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
            guard !target.isBroadcast else { throw .targetIsBroadcast }
            return .invalidateMUID(header, target: target)
        case .ack:
            return .ack(header, try decodeStatus(reader: &reader))
        case .nak:
            return .nak(header, header.format == .ci12 ? try decodeStatus(reader: &reader) : nil)
        }
    }

    private static func decodeDiscovery(
        format: MIDICIFormat, reader: inout MIDICIReader
    ) throws(MIDICIRefusal) -> MIDICIDiscoveryInfo {
        let manufacturer = try reader.take(MIDICILayout.manufacturerBytes)
        let family = try reader.wireValue(byteCount: 2)
        let model = try reader.wireValue(byteCount: 2)
        let revision = try reader.take(MIDICILayout.revisionBytes)
        let identity = try MIDICIDeviceIdentity.make(
            manufacturer: manufacturer, family: UInt16(family), model: UInt16(model), softwareRevision: revision)
        let category = try reader.byte()
        let maximumSize = try reader.wireValue(byteCount: 4)
        var path: UInt8?
        if format == .ci12 { path = try reader.byte() }
        return try MIDICIDiscoveryInfo.make(
            identity: identity, capabilityCategory: category, maximumSysExSize: maximumSize, outputPathID: path)
    }

    private static func decodeStatus(reader: inout MIDICIReader) throws(MIDICIRefusal) -> MIDICIStatusReport {
        let original = try reader.byte()
        let code = try reader.byte()
        let data = try reader.byte()
        let details = try reader.take(MIDICILayout.detailsBytes)
        let length = try reader.wireValue(byteCount: 2)
        let text = try reader.take(Int(length))
        var scalars = String.UnicodeScalarView()
        for byte in text { scalars.append(Unicode.Scalar(byte)) }
        return try MIDICIStatusReport.make(
            originalSubID: original, statusCode: code, statusData: data, details: details, text: String(scalars))
    }
}
