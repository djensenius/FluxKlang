import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The Validation suite of #83 ("New UMPCapabilityTests with packet/fallback/exchange fixtures", slice UCT1). Every
/// test starts from wire words or bytes and runs the real decoders, `MIDICapabilityResolver.negotiate` and, for the
/// fallback losses, `UMPMIDI2ToMIDI1Translator`. Topics against the #83 acceptance ("Legacy works without CI;
/// fidelity loss/downgrade and API availability are explicit"):
/// - `+Packet`: UMP Endpoint Info and Function Block Info (and Name) words → facts → granted level, features and
///   blocks; hostile words are refused with a typed refusal and contribute nothing (groups/function blocks).
/// - `+Fallback`: no CI answer or a CI NAK gives `legacyByteStream`; a MIDI 1.0-only peer records the downgrade, and
///   `possibleTranslationLosses` is checked against what the translator really reports ("legacy works without CI",
///   "fidelity loss/downgrade explicit").
/// - `+Exchange`: MIDI-CI Discovery, Discovery Reply and Reply to Profile Inquiry bytes → answer → negotiation; the
///   profile bound; how identity is keyed ("bounded profile discovery", "Unique ID alone is not universal identity").
/// API availability and property exchange are not covered: no production API for either exists yet.
///
/// Decoded messages become `MIDICapabilityFacts` through the production adapter, `MIDICapabilityDiscovery` (#572);
/// `discovery(_:ci:)` below only decodes and feeds it, in order. Every word and byte below was written by hand
/// from the layouts documented in `UMPStreamMessage+Decode.swift`, `MIDICIMessage.swift` and
/// `MIDICIProfileMessage.swift`, never produced by an encoder.
#if os(macOS)
@Suite("UMP capability", .productionAccessAudit)
#else
@Suite("UMP capability")
#endif
struct UMPCapabilityTests {
    typealias Facts = MIDICapabilityFacts
    typealias CIAnswer = MIDICapabilityCIAnswer
    typealias Block = UMPStreamFunctionBlockInfo

    // MARK: - UMP Stream words (MT 0xF)

    /// Endpoint Info, UMP 1.1: static blocks, 2 blocks, MIDI 1.0 and 2.0, receives jitter reduction.
    static let endpointMIDI2: [UInt32] = [0xF001_0101, 0x8200_0302, 0, 0]
    /// Endpoint Info, UMP 1.1: static blocks, 1 block, MIDI 1.0 only, no jitter reduction.
    static let endpointMIDI1: [UInt32] = [0xF001_0101, 0x8100_0100, 0, 0]
    /// Block 0: active, index 0, UI both, not MIDI 1.0, bidirectional; groups 0-1, CI version 2, one SysEx8 stream.
    static let block0: [UInt32] = [0xF011_8033, 0x0002_0201, 0, 0]
    /// Block 1: active, index 1, UI receiver, MIDI 1.0 unrestricted, input; group 2, CI version 1, no SysEx8.
    static let block1: [UInt32] = [0xF011_8115, 0x0201_0100, 0, 0]
    /// Block 0 of a MIDI 1.0 endpoint: active, UI both, MIDI 1.0 unrestricted, bidirectional; group 0, CI version 1.
    static let midi1Block0: [UInt32] = [0xF011_8037, 0x0001_0100, 0, 0]
    /// Function Block Name, complete packet, block 0, "Synth" (lane byte 0 is the index).
    static let block0Name: [UInt32] = [0xF012_0053, 0x796E_7468, 0, 0]

    static let expectedBlock0 = Block(
        index: 0, isActive: true, uiHint: .both, midi1Mode: .notMIDI1, direction: .bidirectional,
        firstGroup: 0, groupCount: 2, midiCIVersion: 2, maximumSysEx8Streams: 1)
    static let expectedBlock1 = Block(
        index: 1, isActive: true, uiHint: .receiver, midi1Mode: .unrestricted, direction: .input,
        firstGroup: 2, groupCount: 1, midiCIVersion: 1, maximumSysEx8Streams: 0)
    /// The downgrade block 1 (MIDI 1.0 unrestricted) records on a MIDI 2.0 endpoint.
    static let block1MIDI1Only = MIDICapabilityDowngrade(
        reason: .functionBlockMIDI1Only, lost: [],
        possibleTranslationLosses: MIDICapabilityResolver.midi2ToMIDI1Losses, functionBlockIndices: [1])

    // MARK: - MIDI-CI bytes (payload without F0 and F7)

    /// MUID 0x01234567 (this host), 7 bits per byte, least significant first.
    static let hostMUID: [UInt8] = [0x67, 0x0A, 0x0D, 0x09]
    /// MUID 0x07654321 (the device).
    static let deviceMUID: [UInt8] = [0x21, 0x06, 0x15, 0x3B]
    static let broadcastMUID: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F]

    /// Discovery body: manufacturer 00 21 09, family 0x0102, model 0x0003, revision 1.0.0.0, category 0x0E
    /// (profile configuration bit 0x04 set), maximum SysEx 512.
    static let deviceBody: [UInt8] = [
        0x00, 0x21, 0x09, 0x02, 0x02, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x04, 0x00, 0x00
    ]
    /// As `deviceBody` but manufacturer 00 20 6B and model 0x0004: another device identity.
    static let otherBody: [UInt8] = [
        0x00, 0x20, 0x6B, 0x02, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x04, 0x00, 0x00
    ]
    /// As `deviceBody` but category 0x0A: the profile configuration bit is clear.
    static let silentBody: [UInt8] = [
        0x00, 0x21, 0x09, 0x02, 0x02, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x04, 0x00, 0x00
    ]

    static func prefix(_ subID: UInt8) -> [UInt8] {
        [0x7E, 0x7F, 0x0D, subID, 0x02]
    }

    /// CI 1.2 Discovery from this host to broadcast, output path 0 (the host's own body reuses `otherBody`).
    static let discovery = prefix(0x70) + hostMUID + broadcastMUID + otherBody + [0x00]
    /// CI 1.2 Discovery Reply from the device to this host, output path 0, function block 0.
    static let reply = prefix(0x71) + deviceMUID + hostMUID + deviceBody + [0x00, 0x00]
    /// CI 1.2 NAK from the device to this host for the Discovery (original sub-id 0x70), status 0, no text.
    static let nak = prefix(0x7F) + deviceMUID + hostMUID + [0x70, 0x00, 0x00, 0, 0, 0, 0, 0, 0x00, 0x00]
    /// CI 1.1 NAK: the 13-byte header only.
    static let nak11 = [0x7E, 0x7F, 0x0D, 0x7F, 0x01] + deviceMUID + hostMUID

    static let profileA: [UInt8] = [0x7E, 0x00, 0x01, 0x01, 0x00]
    static let profileB: [UInt8] = [0x00, 0x21, 0x09, 0x05, 0x06]
    static let profileC: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
    /// Reply to Profile Inquiry from the device: enabled [B, A], disabled [C].
    static let profileReply = prefix(0x21) + deviceMUID + hostMUID
        + [0x02, 0x00] + profileB + profileA + [0x01, 0x00] + profileC

    /// A Reply to Profile Inquiry built from counts (the at-limit lists cannot be written out by hand). Profile `n`
    /// is `7E 00 hi lo 01` with `n` split 7 bits per byte, so every id is distinct and 7-bit.
    static func profileReply(enabled: Int, disabled: Int, from start: Int = 0) -> [UInt8] {
        func list(_ range: Range<Int>) -> [UInt8] {
            [UInt8(range.count & 0x7F), UInt8(range.count >> 7)]
                + range.flatMap { [0x7E, 0x00, UInt8($0 >> 7), UInt8($0 & 0x7F), 0x01] }
        }
        let middle = start + enabled
        return prefix(0x21) + deviceMUID + hostMUID + list(start..<middle) + list(middle..<(middle + disabled))
    }

    // MARK: - Pipeline helpers

    static func limits() throws -> UMPStreamLimits {
        try UMPStreamLimits.make(maximumTextBytes: 255)
    }

    static func stream(_ words: [UInt32]) throws -> UMPStreamMessage {
        try UMPStreamMessage.decode(UMPPacket(words: words), limits: limits())
    }

    /// Decodes a MIDI-CI payload with the decoder its sub-id 2 selects (0x20 to 0x27: the profile messages).
    static func collect(ci payload: [UInt8], into discovery: inout MIDICapabilityDiscovery) throws {
        if payload.count > 3, (0x20...0x27).contains(payload[3]) {
            try discovery.collect(MIDICIProfileMessage.decode(payload: payload, limits: .standard))
        } else {
            try discovery.collect(MIDICIMessage.decode(payload: payload, limits: .standard))
        }
    }

    /// Decodes every Stream packet, then every MIDI-CI payload, in order, and collects each one in a fresh
    /// `MIDICapabilityDiscovery`. The first decode or collect refusal is thrown, so a refusal yields no facts at all.
    static func discovery(_ packets: [[UInt32]], ci payloads: [[UInt8]] = []) throws -> MIDICapabilityDiscovery {
        var discovery = MIDICapabilityDiscovery()
        for words in packets {
            try discovery.collect(stream(words))
        }
        for payload in payloads {
            try collect(ci: payload, into: &discovery)
        }
        return discovery
    }

    static func facts(_ packets: [[UInt32]], ci payloads: [[UInt8]] = []) throws -> Facts {
        try discovery(packets, ci: payloads).facts
    }

    /// The adapter's answer for a Discovery Reply (or a NAK, or nothing) and, when given, a Reply to Profile Inquiry.
    static func ciAnswer(reply: [UInt8]?, profiles: [UInt8]? = nil) throws -> CIAnswer {
        try facts([], ci: [reply, profiles].compactMap { $0 }).ciAnswer
    }

    static func negotiate(_ packets: [[UInt32]], ci payloads: [[UInt8]] = []) throws -> MIDINegotiatedCapability {
        try MIDICapabilityResolver.negotiate(facts(packets, ci: payloads))
    }

    /// The resolver refusal for these facts, or nil when negotiation succeeds.
    static func refusal(_ facts: Facts) -> MIDICapabilityRefusal? {
        do {
            _ = try MIDICapabilityResolver.negotiate(facts)
            return nil
        } catch {
            return error
        }
    }
}
