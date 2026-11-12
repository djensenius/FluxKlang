/// Sub-id 2 of the profile messages handled by `MIDICIProfileMessage`.
enum MIDICIProfileKind: UInt8, Sendable {
    case inquiry = 0x20
    case inquiryReply = 0x21
    case enabledReport = 0x24
    case disabledReport = 0x25
    case addedReport = 0x26
    case removedReport = 0x27

    /// Neither ktmidi nor JUCE constrains the destination of the Inquiry and its Reply (`.either`: only a broadcast
    /// source is refused). Both send the four reports to the broadcast MUID, so a report must be broadcast.
    var destinationRule: MIDICIDestinationRule {
        switch self {
        case .inquiry, .inquiryReply: return .either
        case .enabledReport, .disabledReport, .addedReport, .removedReport: return .broadcast
        }
    }
}

/// MIDI-CI Profile Inquiry (sub-id 2 0x20), Reply to Profile Inquiry (0x21) and the Profile Enabled, Disabled, Added
/// and Removed Reports (0x24 to 0x27), kept apart from the management messages of `MIDICIMessage` (whose decoder
/// still refuses 0x20 to 0x27 with `unknownSubID`). Set Profile On (0x22) and Off (0x23) are not decoded here.
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then:
/// - 0x20 Profile Inquiry: no body, so the payload is exactly 13 bytes.
/// - 0x21 Reply: enabled count (2 bytes, 14 bit, least significant first), that many 5-byte profile ids, disabled
///   count (2 bytes, the same coding), that many 5-byte profile ids. The minimum payload is 17 bytes.
/// - 0x24 Enabled and 0x25 Disabled Report: a 5-byte profile id, then in CI 1.2 only the channel count (2 bytes,
///   14 bit, least significant first). The payload is 20 bytes in CI 1.2 and 18 in CI 1.1. ktmidi always writes
///   and reads the count; the 18-byte CI 1.1 form comes from JUCE alone (it writes the count `if 0x02 <= version`).
/// - 0x26 Added and 0x27 Removed Report: a 5-byte profile id only, in both formats (18 bytes).
/// 0x20 and 0x21 do not differ between CI 1.1 and CI 1.2. A profile id is five raw 7-bit bytes, copied as they are.
///
/// Provenance: the MIDI Association specification was not reachable. The layout was cross-checked against ktmidi
/// (`ktmidi-ci/.../ci/CIFactory.kt`, `CIRetrieval.kt` and the minimum sizes in `Message.kt`) and JUCE
/// (`modules/juce_midi_ci/detail/juce_CIMessageMeta.h` and `juce_CIMarshalling.h`, which write each count with
/// two size bytes, and `ci/juce_CIProfileHost.cpp`). For the reports: ktmidi `midiCIProfileReport` (20 bytes),
/// the 18-byte Added and Removed Reports and `CIRetrieval.kt` (the count at offsets 18 and 19), and JUCE
/// `juce_CIMessageMeta.h` (the count only `if 0x02 <= version`). Neither source validates profile id bytes on
/// parse; this codec refuses every byte of 0x80 or more. No byte array was copied from either source.
enum MIDICIProfileMessage: Equatable, Hashable, Sendable {
    case inquiry(MIDICIHeader)
    /// Each list holds at most `maximumProfilesPerList` ids, in wire order. Duplicates, and an id in both lists, are
    /// kept as received: the codec does not judge the device's answer.
    case inquiryReply(MIDICIHeader, enabled: [MIDICapabilityProfileID], disabled: [MIDICapabilityProfileID])
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
    /// Bytes of the CI 1.2 channel count of the Enabled and Disabled Reports, and its inclusive bound (14 bit).
    static let channelCountBytes = 2
    static let maximumChannelCount: UInt16 = 0x3FFF

    var header: MIDICIHeader {
        switch self {
        case let .inquiry(header), let .inquiryReply(header, _, _), let .enabledReport(header, _, _),
             let .disabledReport(header, _, _), let .addedReport(header, _), let .removedReport(header, _):
            return header
        }
    }

    var kind: MIDICIProfileKind {
        switch self {
        case .inquiry: return .inquiry
        case .inquiryReply: return .inquiryReply
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
    ///     the counts, the channel count and every profile id byte);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x20, 0x21 or 0x24 to 0x27: `unknownSubID`;
    ///  6. format (byte 4) not 1 or 2: `unsupportedFormat`;
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the length. An Inquiry is exactly 13 bytes (more is `trailingBytes`). A Reply: fewer than 15 bytes is
    ///     `truncated(15)`; an enabled count above `maximumProfilesPerList` is `tooManyProfiles`; fewer bytes than
    ///     the enabled ids need is `truncated(15 + 5E)`; then fewer than the disabled count needs is
    ///     `truncated(17 + 5E)`; a disabled count above the bound is `tooManyProfiles`; fewer bytes than the
    ///     disabled ids need is `truncated(17 + 5E + 5D)`; more is `trailingBytes`. Each count is compared with the
    ///     bound before the length it implies and before any id is read, so a hostile count drives no work. An
    ///     Enabled or Disabled Report is exactly 20 bytes in CI 1.2 and 18 in CI 1.1, an Added or Removed Report
    ///     exactly 18: fewer is `truncated(expected)`, more is `trailingBytes`;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast`; then, for the four reports only, `destinationNotBroadcast` (the Inquiry
    ///     and its Reply may be addressed to broadcast or one MUID);
    /// 11. the device id (always 7-bit by then; 0x7E and 0x7F are accepted as they are);
    /// 12. the body: the profile ids in wire order (enabled first in a Reply), then a report's channel count.
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
        switch kind {
        case .inquiry:
            return .inquiry(header)
        case .inquiryReply:
            let enabled = try readList(&reader)
            let disabled = try readList(&reader)
            return .inquiryReply(header, enabled: enabled, disabled: disabled)
        case .enabledReport, .disabledReport:
            let profile = try readProfile(&reader)
            var channels: UInt16?
            if format == .ci12 { channels = UInt16(try reader.wireValue(byteCount: channelCountBytes)) }
            return kind == .enabledReport
                ? .enabledReport(header, profile: profile, channels: channels)
                : .disabledReport(header, profile: profile, channels: channels)
        case .addedReport:
            return .addedReport(header, profile: try readProfile(&reader))
        case .removedReport:
            return .removedReport(header, profile: try readProfile(&reader))
        }
    }

    /// Step 8. A Reply reads only its two count fields, each after the bytes before it are known to exist.
    private static func checkLength(
        _ payload: [UInt8], kind: MIDICIProfileKind, format: MIDICIFormat
    ) throws(MIDICIRefusal) {
        var expected = MIDICILayout.headerBytes
        switch kind {
        case .inquiry:
            break
        case .enabledReport, .disabledReport:
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

    /// The canonical payload (without F0 and F7). Refusal order: `sourceIsBroadcast`, then (reports only)
    /// `destinationNotBroadcast`, then the body: `tooManyProfiles` for the enabled list and then the disabled list
    /// (each before any of its ids is written), or for an Enabled or Disabled Report the channel count pairing
    /// (`channelCountNotAllowed` in CI 1.1, `channelCountRequired` in CI 1.2) and then its range
    /// (`fieldOutOfRange(.channelCount)` above 0x3FFF); last `payloadTooLarge`. Every profile id is 7-bit by
    /// construction (`MIDICapabilityProfileID.make`).
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
        case let .enabledReport(header, profile, channels), let .disabledReport(header, profile, channels):
            return profile.bytes + (try Self.channelCountField(channels, format: header.format))
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
