//
//  MIDICaptureProtocol.swift
//  FluxKlang
//
//  Container versus effective protocol of one MIDI capture (#112 CL4,
//  media-contract.md §9.1). Every field derives from the endpoint and port
//  protocols and the packet's Message Type, never from the packet's values.
//

/// The endpoint's native protocol (`kMIDIPropertyProtocolID`); `unknown` when missing or unrecognised.
enum MIDIEndpointProtocol: String, Hashable, Sendable, CaseIterable {
    case midi1, midi2, unknown
}

/// The protocol the input port was created with; also the effective protocol of a capture.
enum MIDIPortProtocol: String, Hashable, Sendable, CaseIterable {
    case midi1, midi2
}

/// The §9.1 protocol fields of one capture. Built only by `classify`.
struct MIDIProtocolStamp: Hashable, Sendable {
    let endpoint: MIDIEndpointProtocol
    let port: MIDIPortProtocol
    /// `midi2` only for a packet from a `midi2` endpoint through a `midi2` port: MT 0x4, or another non-channel-voice
    /// type such as example 10's MT 0x0 JR Timestamp. Otherwise `midi1`; MT 0x2 is always `midi1`.
    let effective: MIDIPortProtocol

    private init(endpoint: MIDIEndpointProtocol, port: MIDIPortProtocol, effective: MIDIPortProtocol) {
        self.endpoint = endpoint
        self.port = port
        self.effective = effective
    }

    /// The endpoint protocol every derived field assumes: `unknown` counts as `midi1`.
    var assumedEndpoint: MIDIPortProtocol {
        endpoint == .midi2 ? .midi2 : .midi1
    }

    /// `translatedBy == os`: the assumed endpoint protocol differs from the port's (derived, not documented).
    var translatedByOS: Bool {
        assumedEndpoint != port
    }

    /// False exactly when the endpoint protocol is `unknown`.
    var verified: Bool {
        endpoint != .unknown
    }

    /// Classifies `packet` as received on `port` from an endpoint reporting `endpoint`. Channel voice must arrive in
    /// the port's protocol (MT 0x2 on `midi1`, MT 0x4 on `midi2`); anything else is refused.
    static func classify(_ packet: UMPPacket, endpoint: MIDIEndpointProtocol,
                         port: MIDIPortProtocol) throws(MIDICaptureRefusal) -> MIDIProtocolStamp {
        let type = packet.messageType
        switch (type, port) {
        case (.midi1ChannelVoice, .midi2), (.midi2ChannelVoice, .midi1):
            throw .channelVoiceProtocolMismatch(messageType: type, port: port)
        default:
            break
        }
        // MT 0x2 never reaches here on a midi2 port, so it is always effective midi1.
        let native = endpoint == .midi2 && port == .midi2
        return MIDIProtocolStamp(endpoint: endpoint, port: port, effective: native ? .midi2 : .midi1)
    }
}
