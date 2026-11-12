/// Sub-id 2 of the profile messages handled by `MIDICIProfileMessage`.
enum MIDICIProfileKind: UInt8, Sendable {
    case inquiry = 0x20
    case inquiryReply = 0x21
}

/// MIDI-CI Profile Inquiry (sub-id 2 0x20) and Reply to Profile Inquiry (0x21), kept apart from the management
/// messages of `MIDICIMessage` (whose decoder still refuses 0x20 and 0x21 with `unknownSubID`).
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then:
/// - 0x20 Profile Inquiry: no body, so the payload is exactly 13 bytes.
/// - 0x21 Reply: enabled count (2 bytes, 14 bit, least significant first), that many 5-byte profile ids, disabled
///   count (2 bytes, the same coding), that many 5-byte profile ids. The minimum payload is 17 bytes.
/// Neither message differs between CI 1.1 and CI 1.2. A profile id is five raw 7-bit bytes, copied as they are.
///
/// Provenance: the MIDI Association specification was not reachable. The layout was cross-checked against ktmidi
/// (`ktmidi-ci/.../ci/CIFactory.kt`, `CIRetrieval.kt` and the minimum sizes in `Message.kt`) and JUCE
/// (`modules/juce_midi_ci/detail/juce_CIMessageMeta.h` and `juce_CIMarshalling.h`, which write each count with
/// two size bytes, and `ci/juce_CIProfileHost.cpp`). Neither source validates profile id bytes on parse; this codec
/// refuses every byte of 0x80 or more. No byte array was copied from either source.
enum MIDICIProfileMessage: Equatable, Hashable, Sendable {
    case inquiry(MIDICIHeader)
    /// Each list holds at most `maximumProfilesPerList` ids, in wire order. Duplicates, and an id in both lists, are
    /// kept as received: the codec does not judge the device's answer.
    case inquiryReply(MIDICIHeader, enabled: [MIDICapabilityProfileID], disabled: [MIDICapabilityProfileID])

    /// The inclusive bound of each list: the capability resolver's profile bound, never above the 14-bit count.
    static let maximumProfilesPerList = min(MIDICapabilityLimits.maximumProfiles, 0x3FFF)
    /// Bytes of each list count.
    static let countBytes = 2

    var header: MIDICIHeader {
        switch self {
        case let .inquiry(header), let .inquiryReply(header, _, _):
            return header
        }
    }

    var kind: MIDICIProfileKind {
        switch self {
        case .inquiry: return .inquiry
        case .inquiryReply: return .inquiryReply
        }
    }

    /// Neither ktmidi nor JUCE constrains the destination MUID of these two messages, so the shared rule is applied
    /// with `.either`: only a broadcast source is refused.
    static let destinationRule = MIDICIDestinationRule.either

    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and steps 1 to 11 follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)` (its management-only checks do not apply here):
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (this covers the device id,
    ///     the counts and every profile id byte);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x20 or 0x21: `unknownSubID`;
    ///  6. format (byte 4) not 1 or 2: `unsupportedFormat`;
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the length. An Inquiry is exactly 13 bytes (more is `trailingBytes`). A Reply: fewer than 15 bytes is
    ///     `truncated(15)`; an enabled count above `maximumProfilesPerList` is `tooManyProfiles`; fewer bytes than
    ///     the enabled ids need is `truncated(15 + 5E)`; then fewer than the disabled count needs is
    ///     `truncated(17 + 5E)`; a disabled count above the bound is `tooManyProfiles`; fewer bytes than the
    ///     disabled ids need is `truncated(17 + 5E + 5D)`; more is `trailingBytes`. Each count is compared with the
    ///     bound before the length it implies and before any id is read, so a hostile count drives no work;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast` (the destination may be broadcast or one MUID);
    /// 11. the device id (always 7-bit by then; 0x7E and 0x7F are accepted as they are);
    /// 12. the body: the profile ids in wire order, enabled first.
    /// The device id and profile id wrappers of steps 11 and 12 are defensive: step 3 makes them unreachable (by
    /// inspection; no test reaches them).
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIProfileMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIProfileKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard let format = MIDICIFormat(rawValue: payload[4]) else { throw .unsupportedFormat(payload[4]) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        try checkLength(payload, kind: kind)
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: format, source: source, destination: destination)
        switch kind {
        case .inquiry:
            return .inquiry(header)
        case .inquiryReply:
            let enabled = try readList(&reader)
            let disabled = try readList(&reader)
            return .inquiryReply(header, enabled: enabled, disabled: disabled)
        }
    }

    /// Step 8. Reads only the two count fields, each after the bytes before it are known to exist.
    private static func checkLength(_ payload: [UInt8], kind: MIDICIProfileKind) throws(MIDICIRefusal) {
        var expected = MIDICILayout.headerBytes
        if kind == .inquiryReply {
            for _ in 0..<2 {
                expected += countBytes
                guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
                let declared = Int(MIDICIWire.decode(Array(payload[(expected - countBytes)..<expected])))
                guard declared <= maximumProfilesPerList else {
                    throw .tooManyProfiles(count: declared, limit: maximumProfilesPerList)
                }
                expected += declared * MIDICapabilityProfileID.byteCount
                guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
            }
        }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
    }

    /// Step 12 for one list. The count was bounded and the length checked in step 8; the guards here are defensive.
    private static func readList(_ reader: inout MIDICIReader) throws(MIDICIRefusal) -> [MIDICapabilityProfileID] {
        let count = Int(try reader.wireValue(byteCount: countBytes))
        guard count <= maximumProfilesPerList else {
            throw .tooManyProfiles(count: count, limit: maximumProfilesPerList)
        }
        var profiles: [MIDICapabilityProfileID] = []
        profiles.reserveCapacity(count)
        for _ in 0..<count {
            let start = reader.offset
            let bytes = try reader.take(MIDICapabilityProfileID.byteCount)
            do {
                profiles.append(try MIDICapabilityProfileID.make(bytes: bytes))
            } catch {
                switch error {
                case let .invalidProfileID(_, offset): throw .dataByteHigh(offset: start + offset)
                default: throw .dataByteHigh(offset: start)
                }
            }
        }
        return profiles
    }

    // MARK: Encode

    /// The canonical payload (without F0 and F7). Refusal order: `sourceIsBroadcast`, then `tooManyProfiles` for
    /// the enabled list and then the disabled list (each before any of its ids is written), and last
    /// `payloadTooLarge`. Every profile id is 7-bit by construction (`MIDICapabilityProfileID.make`).
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        try MIDICIMessage.validateAddressing(
            Self.destinationRule, source: header.source, destination: header.destination)
        var body: [UInt8] = []
        if case let .inquiryReply(_, enabled, disabled) = self {
            body = try Self.listBytes(enabled)
            body += try Self.listBytes(disabled)
        }
        let total = MIDICILayout.headerBytes + body.count
        guard total <= limits.maximumPayloadBytes else { throw .payloadTooLarge(total) }
        let prefix: [UInt8] = [
            MIDICILayout.universalNonRealTime, header.device.rawValue, MIDICILayout.ciSubID1,
            kind.rawValue, header.format.rawValue
        ]
        return prefix + MIDICIWire.encode(header.source.rawValue, byteCount: 4)
            + MIDICIWire.encode(header.destination.rawValue, byteCount: 4) + body
    }

    private static func listBytes(_ profiles: [MIDICapabilityProfileID]) throws(MIDICIRefusal) -> [UInt8] {
        guard profiles.count <= maximumProfilesPerList else {
            throw .tooManyProfiles(count: profiles.count, limit: maximumProfilesPerList)
        }
        return MIDICIWire.encode(UInt32(profiles.count), byteCount: countBytes) + profiles.flatMap(\.bytes)
    }
}
