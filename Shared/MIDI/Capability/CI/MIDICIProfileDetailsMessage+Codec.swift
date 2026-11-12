extension MIDICIProfileDetailsMessage {
    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and the rest follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)`:
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (the whole body is 7-bit
    ///     data: the device id, the MUIDs, the profile id, the target, the lengths and the data);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x28, 0x29 or 0x2F: `unknownSubID`;
    ///  6. format (byte 4): for 0x28 and 0x29 anything but 2 (0x01 included) is `unsupportedFormat`; for 0x2F
    ///     anything but 1 or 2;
    ///  7. fewer than 13 bytes: `truncated(13)`; then fewer than the fixed part of the kind (19, 21 or 22 bytes):
    ///     `truncated(fixed)`;
    ///  8. the length: the exact total is the fixed part, plus dl (0x29) or n (0x2F). Fewer bytes is
    ///     `truncated(total)` (so a hostile declared length is a `truncated`, and nothing is sized from it before
    ///     this check), more is `trailingBytes(excess)`. 0x28 is exactly 19 bytes;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast`, then for 0x28 and 0x29 `destinationIsBroadcast`;
    /// 11. the device id, wrapped as received (any 7-bit value);
    /// 12. the body: the profile id, the target and the data, kept as received.
    /// The device id wrapper of step 11 and the profile id failure of step 12 are defensive: step 3 makes them
    /// unreachable (by inspection; no test reaches them).
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIProfileDetailsMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIProfileDetailsKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard let format = MIDICIFormat(rawValue: payload[4]), kind.accepts(format) else {
            throw .unsupportedFormat(payload[4])
        }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        guard payload.count >= kind.fixedBytes else { throw .truncated(need: kind.fixedBytes, have: payload.count) }
        let expected = kind.fixedBytes + declaredDataLength(payload, kind: kind)
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(kind.destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: format, source: source, destination: destination)
        return try decodeBody(kind, header: header, reader: &reader)
    }

    /// Step 8: dl (offsets 19 and 20) of a Reply, n (offsets 18 to 21) of Profile Specific Data, 0 for the Inquiry.
    /// The payload holds at least `kind.fixedBytes`, so both fields exist.
    private static func declaredDataLength(_ payload: [UInt8], kind: MIDICIProfileDetailsKind) -> Int {
        switch kind {
        case .detailsInquiry: return 0
        case .detailsReply: return Int(MIDICIWire.decode(Array(payload[19...20])))
        case .specificData: return Int(MIDICIWire.decode(Array(payload[18...21])))
        }
    }

    /// Step 12.
    private static func decodeBody(
        _ kind: MIDICIProfileDetailsKind, header: MIDICIHeader, reader: inout MIDICIReader
    ) throws(MIDICIRefusal) -> MIDICIProfileDetailsMessage {
        let profile = try readProfile(&reader)
        switch kind {
        case .detailsInquiry:
            return .detailsInquiry(header, profile: profile, target: try reader.byte())
        case .detailsReply:
            let target = try reader.byte()
            let length = try reader.wireValue(byteCount: 2)
            return .detailsReply(header, profile: profile, target: target, data: try reader.take(Int(length)))
        case .specificData:
            let length = try reader.wireValue(byteCount: 4)
            return .specificData(header, profile: profile, data: try reader.take(Int(length)))
        }
    }

    /// One 5-byte profile id. Step 3 has refused every high byte, so the mapping to `dataByteHigh` is defensive.
    private static func readProfile(_ reader: inout MIDICIReader) throws(MIDICIRefusal) -> MIDICapabilityProfileID {
        let start = reader.offset
        let bytes = try reader.take(MIDICapabilityProfileID.byteCount)
        do {
            return try MIDICapabilityProfileID.make(bytes: bytes)
        } catch {
            switch error {
            case let .invalidProfileID(_, offset): throw .dataByteHigh(offset: start + offset)
            default: throw .dataByteHigh(offset: start)
            }
        }
    }

    // MARK: Encode

    /// The canonical payload (without F0 and F7). Refusal order: the format rule (`unsupportedFormat(1)` for 0x28 and
    /// 0x29 in a CI 1.1 header), `sourceIsBroadcast`, `destinationIsBroadcast` (0x28 and 0x29 only), an inquiry target
    /// of 0x80 or more (`fieldOutOfRange(.inquiryTarget)`), a data byte of 0x80 or more
    /// (`fieldOutOfRange(.inquiryTargetData)` or `.profileSpecificData`), a Reply's data above 0x3FFF bytes
    /// (`fieldOutOfRange(.inquiryTargetDataLength)`), last `payloadTooLarge`. The profile id is 7-bit by construction.
    /// The 28-bit length of Profile Specific Data cannot be exceeded: the payload cap is at most 4,096 bytes.
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        guard kind.accepts(header.format) else { throw .unsupportedFormat(header.format.rawValue) }
        try MIDICIMessage.validateAddressing(
            kind.destinationRule, source: header.source, destination: header.destination)
        let body = try encodedBody()
        let total = MIDICILayout.headerBytes + body.count
        guard total <= limits.maximumPayloadBytes else { throw .payloadTooLarge(total) }
        let prefix: [UInt8] = [
            MIDICILayout.universalNonRealTime, header.device.rawValue, MIDICILayout.ciSubID1,
            kind.rawValue, header.format.rawValue
        ]
        return prefix + MIDICIWire.encode(header.source.rawValue, byteCount: 4)
            + MIDICIWire.encode(header.destination.rawValue, byteCount: 4) + body
    }

    private func encodedBody() throws(MIDICIRefusal) -> [UInt8] {
        switch self {
        case let .detailsInquiry(_, profile, target):
            return profile.bytes + [try Self.checkedTarget(target)]
        case let .detailsReply(_, profile, target, data):
            let targetByte = try Self.checkedTarget(target)
            try Self.checkSevenBit(data, field: .inquiryTargetData)
            guard data.count <= Self.maximumReplyDataBytes else {
                throw .fieldOutOfRange(.inquiryTargetDataLength, value: data.count)
            }
            return profile.bytes + [targetByte] + MIDICIWire.encode(UInt32(data.count), byteCount: 2) + data
        case let .specificData(_, profile, data):
            try Self.checkSevenBit(data, field: .profileSpecificData)
            return profile.bytes + MIDICIWire.encode(UInt32(data.count), byteCount: 4) + data
        }
    }

    private static func checkedTarget(_ target: UInt8) throws(MIDICIRefusal) -> UInt8 {
        guard target < 0x80 else { throw .fieldOutOfRange(.inquiryTarget, value: Int(target)) }
        return target
    }

    private static func checkSevenBit(_ data: [UInt8], field: MIDICIRefusal.Field) throws(MIDICIRefusal) {
        if let high = data.first(where: { $0 >= 0x80 }) { throw .fieldOutOfRange(field, value: Int(high)) }
    }
}
