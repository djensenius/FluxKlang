/// Sub-id 2 of the profile messages handled by `MIDICIProfileMessage`.
enum MIDICIProfileKind: UInt8, Sendable {
    case inquiry = 0x20
    case inquiryReply = 0x21
    case setProfileOn = 0x22
    case setProfileOff = 0x23
    case enabledReport = 0x24
    case disabledReport = 0x25
    case addedReport = 0x26
    case removedReport = 0x27

    /// M2-101-UM v1.2, section 3.3.3, allows the Broadcast MUID only for Discovery, Invalidate MUID, the four reports
    /// and Profile Specific Data. A report must be broadcast (Tables 20, 21, 26 and 27; ktmidi and JUCE send the four
    /// reports to the broadcast MUID), and Set Profile On and Off, which an Initiator sends to one responder, need
    /// one MUID (`destinationIsBroadcast`; ktmidi and JUCE accept a broadcast destination on receipt, so this is
    /// stricter). The Inquiry and its Reply stay `.either` (only a broadcast source is refused): neither ktmidi nor
    /// JUCE constrains them, although section 3.3.3 does not list them for the Broadcast MUID either.
    var destinationRule: MIDICIDestinationRule {
        switch self {
        case .inquiry, .inquiryReply: return .either
        case .setProfileOn, .setProfileOff: return .oneMUID
        case .enabledReport, .disabledReport, .addedReport, .removedReport: return .broadcast
        }
    }
}

/// MIDI-CI Profile Inquiry (sub-id 2 0x20), Reply to Profile Inquiry (0x21), Set Profile On (0x22) and Off (0x23) and
/// the Profile Enabled, Disabled, Added and Removed Reports (0x24 to 0x27), kept apart from the management messages
/// of `MIDICIMessage` (whose decoder still refuses 0x20 to 0x27 with `unknownSubID`). The Profile Details Inquiry and
/// Reply (0x28 and 0x29) and Profile Specific Data (0x2F) are not decoded here.
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then:
/// - 0x20 Profile Inquiry: no body, so the payload is exactly 13 bytes.
/// - 0x21 Reply: enabled count (2 bytes, 14 bit, least significant first), that many 5-byte profile ids, disabled
///   count (2 bytes, the same coding), that many 5-byte profile ids. The minimum payload is 17 bytes.
/// - 0x22 Set Profile On: a 5-byte profile id, then in CI 1.2 only the Number of Channels Requested (2 bytes, 14 bit,
///   least significant first). The payload is 20 bytes in CI 1.2 and 18 in CI 1.1.
/// - 0x23 Set Profile Off: a 5-byte profile id, then in CI 1.2 only 2 reserved bytes. The payload is 20 bytes in
///   CI 1.2 and 18 in CI 1.1.
/// - 0x24 Enabled and 0x25 Disabled Report: a 5-byte profile id, then in CI 1.2 only the channel count (2 bytes,
///   14 bit, least significant first). The payload is 20 bytes in CI 1.2 and 18 in CI 1.1. ktmidi always writes
///   and reads the count; JUCE writes it `if 0x02 <= version`, as the specification adds it in message version 2.
/// - 0x26 Added and 0x27 Removed Report: a 5-byte profile id only, in both formats (18 bytes).
/// 0x20 and 0x21 do not differ between CI 1.1 and CI 1.2. A profile id is five raw 7-bit bytes, copied as they are.
///
/// Provenance: M2-101-UM v1.2 (11 May 2023). Set Profile On and Off follow section 7.8, Table 24, and section 7.9,
/// Table 25 (the fields after the profile id were added in message version 2), section 3.3.3 (the Broadcast MUID is
/// not a destination for either), section 5.3 (a receiver ignores reserved values; the Set Profile Off reserved
/// bytes are skipped on that reading) and Appendix D (an Initiator sends both). The reports follow sections 7.4 and
/// 7.5 (Tables 20 and 21) and sections 7.10 and 7.11 (Tables 26 and 27). The layouts were cross-checked against
/// ktmidi (`ktmidi-ci/.../ci/CIFactory.kt`, `CIRetrieval.kt` and the sizes in `Message.kt`) and JUCE
/// (`modules/juce_midi_ci/detail/juce_CIMessageMeta.h` and `juce_CIMarshalling.h`, which write each count with two
/// size bytes, and `ci/juce_CIProfileHost.cpp`); the three agree. ktmidi has only the 20-byte form of Set Profile On
/// and Off, and writes 0 as the count of Set Profile Off. JUCE writes the count of Set Profile On and the reserved
/// bytes of Set Profile Off `if 0x02 <= version`. Neither source validates profile id bytes on parse; this codec
/// refuses every byte of 0x80 or more. No byte array was copied from any source.
enum MIDICIProfileMessage: Equatable, Hashable, Sendable {
    case inquiry(MIDICIHeader)
    /// Each list holds at most `maximumProfilesPerList` ids, in wire order. Duplicates, and an id in both lists, are
    /// kept as received: the codec does not judge the device's answer.
    case inquiryReply(MIDICIHeader, enabled: [MIDICapabilityProfileID], disabled: [MIDICapabilityProfileID])
    /// As `enabledReport`: `channels` is the Number of Channels Requested, present exactly when the header's format
    /// is CI 1.2. It is kept as received and not interpreted: the specification asks for 0 when the device id is 0x7E
    /// or 0x7F (the width of the group or function block decides), and that is not checked here.
    case setProfileOn(MIDICIHeader, profile: MIDICapabilityProfileID, channels: UInt16?)
    /// In CI 1.2 two reserved bytes follow the profile id (none in CI 1.1): `decode` skips them whatever their 7-bit
    /// value and `encode` writes 0x00 0x00, so a non-zero reserved value is not preserved.
    case setProfileOff(MIDICIHeader, profile: MIDICapabilityProfileID)
    /// `channels` is the 14-bit channel count: present exactly when the header's format is CI 1.2 (`decode` reads
    /// it only then; `encode` refuses a mismatch). It is kept as received. JUCE writes 0 when the profile is not on
    /// a single channel (group or function block wide); that is JUCE's convention, not interpreted here.
    case enabledReport(MIDICIHeader, profile: MIDICapabilityProfileID, channels: UInt16?)
    /// As `enabledReport`.
    case disabledReport(MIDICIHeader, profile: MIDICapabilityProfileID, channels: UInt16?)
    case addedReport(MIDICIHeader, profile: MIDICapabilityProfileID)
    case removedReport(MIDICIHeader, profile: MIDICapabilityProfileID)

    /// The inclusive bound of each list: the capability resolver's profile bound, never above the 14-bit count.
    static let maximumProfilesPerList = min(MIDICapabilityLimits.maximumProfiles, 0x3FFF)
    /// Bytes of each list count.
    static let countBytes = 2
    /// Bytes of the CI 1.2 channel count of Set Profile On and of the Enabled and Disabled Reports, and its inclusive
    /// bound (14 bit).
    static let channelCountBytes = 2
    static let maximumChannelCount: UInt16 = 0x3FFF
    /// Bytes of the CI 1.2 reserved field of Set Profile Off. It is as long as a channel count, and `checkLength`
    /// treats the two alike.
    static let offReservedBytes = channelCountBytes

    var header: MIDICIHeader {
        switch self {
        case let .inquiry(header), let .inquiryReply(header, _, _), let .setProfileOn(header, _, _),
             let .setProfileOff(header, _), let .enabledReport(header, _, _), let .disabledReport(header, _, _),
             let .addedReport(header, _), let .removedReport(header, _):
            return header
        }
    }

    var kind: MIDICIProfileKind {
        switch self {
        case .inquiry: return .inquiry
        case .inquiryReply: return .inquiryReply
        case .setProfileOn: return .setProfileOn
        case .setProfileOff: return .setProfileOff
        case .enabledReport: return .enabledReport
        case .disabledReport: return .disabledReport
        case .addedReport: return .addedReport
        case .removedReport: return .removedReport
        }
    }

    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and steps 1 to 11 follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)` (its management-only checks do not apply here):
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (this covers the device id,
    ///     the counts, the channel count, the reserved bytes of Set Profile Off and every profile id byte);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x20 to 0x27: `unknownSubID`;
    ///  6. format (byte 4) not 1 or 2: `unsupportedFormat`;
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the length. An Inquiry is exactly 13 bytes (more is `trailingBytes`). A Reply: fewer than 15 bytes is
    ///     `truncated(15)`; an enabled count above `maximumProfilesPerList` is `tooManyProfiles`; fewer bytes than
    ///     the enabled ids need is `truncated(15 + 5E)`; then fewer than the disabled count needs is
    ///     `truncated(17 + 5E)`; a disabled count above the bound is `tooManyProfiles`; fewer bytes than the
    ///     disabled ids need is `truncated(17 + 5E + 5D)`; more is `trailingBytes`. Each count is compared with the
    ///     bound before the length it implies and before any id is read, so a hostile count drives no work. Set
    ///     Profile On and Off and an Enabled or Disabled Report are exactly 20 bytes in CI 1.2 and 18 in CI 1.1, an
    ///     Added or Removed Report exactly 18: fewer is `truncated(expected)`, more is `trailingBytes`;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast`; then `destinationNotBroadcast` for the four reports, and
    ///     `destinationIsBroadcast` for Set Profile On and Off (the Inquiry and its Reply may be addressed to
    ///     broadcast or one MUID);
    /// 11. the device id (always 7-bit by then; 0x7E and 0x7F are accepted as they are);
    /// 12. the body: the profile ids in wire order (enabled first in a Reply), then the channel count of a report or
    ///     of Set Profile On. The reserved bytes of a CI 1.2 Set Profile Off are skipped, whatever their value.
    /// The device id and profile id wrappers of steps 11 and 12 are defensive: step 3 makes them unreachable (by
    /// inspection; no test reaches them).
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIProfileMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIProfileKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard let format = MIDICIFormat(rawValue: payload[4]) else { throw .unsupportedFormat(payload[4]) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        try checkLength(payload, kind: kind, format: format)
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(kind.destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: format, source: source, destination: destination)
        return try decodeBody(kind, header: header, reader: &reader)
    }

    /// Step 12.
    private static func decodeBody(
        _ kind: MIDICIProfileKind, header: MIDICIHeader, reader: inout MIDICIReader
    ) throws(MIDICIRefusal) -> MIDICIProfileMessage {
        switch kind {
        case .inquiry:
            return .inquiry(header)
        case .inquiryReply:
            let enabled = try readList(&reader)
            let disabled = try readList(&reader)
            return .inquiryReply(header, enabled: enabled, disabled: disabled)
        case .setProfileOn:
            let profile = try readProfile(&reader)
            let channels = try readChannelCount(&reader, format: header.format)
            return .setProfileOn(header, profile: profile, channels: channels)
        case .setProfileOff:
            let profile = try readProfile(&reader)
            if header.format == .ci12 { _ = try reader.take(offReservedBytes) }
            return .setProfileOff(header, profile: profile)
        case .enabledReport, .disabledReport:
            let profile = try readProfile(&reader)
            let channels = try readChannelCount(&reader, format: header.format)
            return kind == .enabledReport
                ? .enabledReport(header, profile: profile, channels: channels)
                : .disabledReport(header, profile: profile, channels: channels)
        case .addedReport:
            return .addedReport(header, profile: try readProfile(&reader))
        case .removedReport:
            return .removedReport(header, profile: try readProfile(&reader))
        }
    }

    /// Step 8. A Reply reads only its two count fields, each after the bytes before it are known to exist. CI 1.2
    /// ends Set Profile On and Off and the Enabled and Disabled Reports with 2 bytes (the channel count, or the
    /// reserved bytes of Set Profile Off), which CI 1.1 does not have.
    private static func checkLength(
        _ payload: [UInt8], kind: MIDICIProfileKind, format: MIDICIFormat
    ) throws(MIDICIRefusal) {
        var expected = MIDICILayout.headerBytes
        switch kind {
        case .inquiry:
            break
        case .setProfileOn, .setProfileOff, .enabledReport, .disabledReport:
            expected += MIDICapabilityProfileID.byteCount + (format == .ci12 ? channelCountBytes : 0)
        case .addedReport, .removedReport:
            expected += MIDICapabilityProfileID.byteCount
        case .inquiryReply:
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
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
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
        for _ in 0..<count { profiles.append(try readProfile(&reader)) }
        return profiles
    }

    /// The CI 1.2 channel count of a report or of Set Profile On (nil in CI 1.1, where there is none). Step 3 has
    /// refused every high byte, so the value is at most 0x3FFF.
    private static func readChannelCount(
        _ reader: inout MIDICIReader, format: MIDICIFormat
    ) throws(MIDICIRefusal) -> UInt16? {
        guard format == .ci12 else { return nil }
        return UInt16(try reader.wireValue(byteCount: channelCountBytes))
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

    /// The canonical payload (without F0 and F7). Refusal order: `sourceIsBroadcast`, then `destinationNotBroadcast`
    /// (the four reports) or `destinationIsBroadcast` (Set Profile On and Off), then the body: `tooManyProfiles` for
    /// the enabled list and then the disabled list (each before any of its ids is written), or for an Enabled or
    /// Disabled Report or a Set Profile On the channel count pairing (`channelCountNotAllowed` in CI 1.1,
    /// `channelCountRequired` in CI 1.2) and then its range (`fieldOutOfRange(.channelCount)` above 0x3FFF); last
    /// `payloadTooLarge`. Every profile id is 7-bit by construction (`MIDICapabilityProfileID.make`). A CI 1.2 Set
    /// Profile Off always writes its reserved bytes as 0x00.
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
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
        case .inquiry:
            return []
        case let .inquiryReply(_, enabled, disabled):
            let enabledBytes = try Self.listBytes(enabled)
            return enabledBytes + (try Self.listBytes(disabled))
        case let .enabledReport(header, profile, channels), let .disabledReport(header, profile, channels),
             let .setProfileOn(header, profile, channels):
            return profile.bytes + (try Self.channelCountField(channels, format: header.format))
        case let .setProfileOff(header, profile):
            return profile.bytes + [UInt8](repeating: 0, count: header.format == .ci12 ? Self.offReservedBytes : 0)
        case let .addedReport(_, profile), let .removedReport(_, profile):
            return profile.bytes
        }
    }

    private static func channelCountField(_ channels: UInt16?, format: MIDICIFormat) throws(MIDICIRefusal) -> [UInt8] {
        switch (format, channels) {
        case (.ci11, .some): throw .channelCountNotAllowed
        case (.ci12, .none): throw .channelCountRequired
        case (.ci11, .none): return []
        case let (.ci12, .some(value)):
            guard value <= maximumChannelCount else { throw .fieldOutOfRange(.channelCount, value: Int(value)) }
            return MIDICIWire.encode(UInt32(value), byteCount: channelCountBytes)
        }
    }

    private static func listBytes(_ profiles: [MIDICapabilityProfileID]) throws(MIDICIRefusal) -> [UInt8] {
        guard profiles.count <= maximumProfilesPerList else {
            throw .tooManyProfiles(count: profiles.count, limit: maximumProfilesPerList)
        }
        return MIDICIWire.encode(UInt32(profiles.count), byteCount: countBytes) + profiles.flatMap(\.bytes)
    }
}
