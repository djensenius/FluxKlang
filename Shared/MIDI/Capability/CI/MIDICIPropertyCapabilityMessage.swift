/// Sub-id 2 of the property exchange capability messages handled by `MIDICIPropertyCapabilityMessage`.
enum MIDICIPropertyCapabilityKind: UInt8, Sendable {
    case inquiry = 0x30
    case reply = 0x31
}

/// The Property Exchange major and minor version, carried by the CI 1.2 form only. Both are 7-bit and kept as
/// received; the codec does not judge which versions a device may announce.
struct MIDICIPropertyExchangeVersion: Equatable, Hashable, Sendable {
    private(set) var major: UInt8
    private(set) var minor: UInt8

    private init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    static func make(major: UInt8, minor: UInt8) throws(MIDICIRefusal) -> MIDICIPropertyExchangeVersion {
        guard major < 0x80 else { throw .fieldOutOfRange(.propertyExchangeMajorVersion, value: Int(major)) }
        guard minor < 0x80 else { throw .fieldOutOfRange(.propertyExchangeMinorVersion, value: Int(minor)) }
        return MIDICIPropertyExchangeVersion(major: major, minor: minor)
    }
}

/// The body shared by the Inquiry and its Reply. `simultaneousRequests` is the 7-bit number of simultaneous
/// property exchange requests supported, kept as received (0 included). `version` exists only in CI 1.2; the
/// pairing with the header's format is checked by `encode`.
struct MIDICIPropertyCapabilities: Equatable, Hashable, Sendable {
    private(set) var simultaneousRequests: UInt8
    private(set) var version: MIDICIPropertyExchangeVersion?

    private init(simultaneousRequests: UInt8, version: MIDICIPropertyExchangeVersion?) {
        self.simultaneousRequests = simultaneousRequests
        self.version = version
    }

    static func make(
        simultaneousRequests: UInt8, version: MIDICIPropertyExchangeVersion?
    ) throws(MIDICIRefusal) -> MIDICIPropertyCapabilities {
        guard simultaneousRequests < 0x80 else {
            throw .fieldOutOfRange(.simultaneousRequests, value: Int(simultaneousRequests))
        }
        return MIDICIPropertyCapabilities(simultaneousRequests: simultaneousRequests, version: version)
    }
}

/// MIDI-CI Inquiry: Property Exchange Capabilities (sub-id 2 0x30) and Reply to Property Exchange Capabilities
/// (0x31), kept apart from `MIDICIMessage` and `MIDICIProfileMessage` (whose decoders still refuse 0x30 and 0x31
/// with `unknownSubID`). Only this handshake is decoded: Get and Set Property Data, subscriptions and notifications
/// (0x34 to 0x3F) are refused here with `unknownSubID` and no property payload is read.
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then, identical for 0x30 and 0x31:
/// - CI 1.1 (format 0x01): the number of simultaneous requests (1 byte). The payload is exactly 14 bytes.
/// - CI 1.2 (format 0x02): the number of simultaneous requests, the Property Exchange major version and minor
///   version (1 byte each). The payload is exactly 16 bytes.
/// The device id is wrapped as received, as the other CI decoders do. The references send 0x7F (AM_MIDI2.0Lib
/// hard-codes it; ktmidi's constant `ADDRESS_FUNCTION_BLOCK` is 0x7F), but 0x7F is not enforced here.
///
/// Provenance: the MIDI Association specification was not reachable. The layout was cross-checked against
/// AM_MIDI2.0Lib (`src/midiCIMessageCreate.cpp` `sendPECapabilityRequest` / `sendPECapabilityReply`, which return
/// 14 bytes for CI version 1 and 16 otherwise; `src/midiCIProcessor.cpp` `processPESysex`, which completes after
/// the 14th byte in version 1 and the 16th otherwise), JUCE (`modules/juce_midi_ci/detail/juce_CIMessageMeta.h`,
/// which writes the two version bytes `if 0x02 <= version`) and ktmidi (`ktmidi-ci/.../ci/CIFactory.kt`
/// `midiCIPropertyGetCapabilities`, which always writes the 16-byte CI 1.2 form, and `CIRetrieval.kt`, which reads
/// byte 13 only). JUCE ignores trailing fields of a newer version; this codec, like the other CI decoders, refuses
/// a format above 0x02 and any trailing byte. No byte array was copied from any source.
enum MIDICIPropertyCapabilityMessage: Equatable, Hashable, Sendable {
    case inquiry(MIDICIHeader, MIDICIPropertyCapabilities)
    case reply(MIDICIHeader, MIDICIPropertyCapabilities)

    /// Bytes of the CI 1.1 body (the request count) and of the CI 1.2 body (the count and the two version bytes).
    static let ci11BodyBytes = 1
    static let ci12BodyBytes = 3

    /// None of the three references constrains the destination of the Inquiry or its Reply in its encoder or its
    /// 0x30 / 0x31 parsing, so either a broadcast or one MUID is accepted; only a broadcast source is refused.
    static let destinationRule = MIDICIDestinationRule.either

    var header: MIDICIHeader {
        switch self {
        case let .inquiry(header, _), let .reply(header, _):
            return header
        }
    }

    var capabilities: MIDICIPropertyCapabilities {
        switch self {
        case let .inquiry(_, capabilities), let .reply(_, capabilities):
            return capabilities
        }
    }

    var kind: MIDICIPropertyCapabilityKind {
        switch self {
        case .inquiry: return .inquiry
        case .reply: return .reply
        }
    }

    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and steps 1 to 11 follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)` (its management-only checks do not apply here):
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (this covers the device id,
    ///     the request count and both version bytes);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x30 or 0x31: `unknownSubID` (this includes 0x34 to 0x3F);
    ///  6. format (byte 4) not 1 or 2: `unsupportedFormat`;
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the length: exactly 14 bytes in CI 1.1 and 16 in CI 1.2; fewer is `truncated(expected)`, more is
    ///     `trailingBytes`;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast` (the destination may be broadcast or one MUID);
    /// 11. the device id (always 7-bit by then; 0x7E and 0x7F are accepted as they are);
    /// 12. the body: the request count, then in CI 1.2 the major and minor version.
    /// The device id wrapper of step 11 (`dataByteHigh(offset: 1)`) and the `fieldOutOfRange` refusals of step 12
    /// are defensive: step 3 makes them unreachable (by inspection; no test reaches them).
    static func decode(
        payload: [UInt8], limits: MIDICILimits
    ) throws(MIDICIRefusal) -> MIDICIPropertyCapabilityMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIPropertyCapabilityKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard let format = MIDICIFormat(rawValue: payload[4]) else { throw .unsupportedFormat(payload[4]) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        let expected = MIDICILayout.headerBytes + (format == .ci12 ? ci12BodyBytes : ci11BodyBytes)
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: format, source: source, destination: destination)
        let requests = try reader.byte()
        var version: MIDICIPropertyExchangeVersion?
        if format == .ci12 {
            let major = try reader.byte()
            version = try MIDICIPropertyExchangeVersion.make(major: major, minor: try reader.byte())
        }
        let capabilities = try MIDICIPropertyCapabilities.make(simultaneousRequests: requests, version: version)
        switch kind {
        case .inquiry: return .inquiry(header, capabilities)
        case .reply: return .reply(header, capabilities)
        }
    }

    // MARK: Encode

    /// The canonical payload (without F0 and F7). Refusal order: `sourceIsBroadcast`, then the version pairing
    /// (`propertyVersionNotAllowed` in CI 1.1, `propertyVersionRequired` in CI 1.2), last `payloadTooLarge`. The
    /// request count and the version bytes are 7-bit by construction (`make`).
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        try MIDICIMessage.validateAddressing(
            Self.destinationRule, source: header.source, destination: header.destination)
        let capabilities = self.capabilities
        var body = [capabilities.simultaneousRequests]
        switch (header.format, capabilities.version) {
        case (.ci11, .some): throw .propertyVersionNotAllowed
        case (.ci12, .none): throw .propertyVersionRequired
        case (.ci11, .none): break
        case let (.ci12, .some(version)): body += [version.major, version.minor]
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
}
