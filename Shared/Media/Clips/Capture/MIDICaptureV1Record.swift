//
//  MIDICaptureV1Record.swift
//  FluxKlang
//
//  An accepted MIDI capture as the media contract v1 `midiCaptureRecord` (#112 MXR1): exactly the
//  schema's fields, validated fail-closed and encoded deterministically. Pure: it writes no file
//  and assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `midiCapture` record of a contract v1 trace (media-contract.md §9.1–§9.2). Built only by `make`.
///
/// Every field comes from one `MIDICaptureRecord`, which only `MIDICaptureLog` builds. The capture's types already
/// guarantee the schema's other bounds, so they have no refusal here: 1 to 4 UMP words (`UMPPacket`), host ticks in
/// 0...UInt64.max (`HostStamp`), a frame in Int64 (`SampleStamp`), and protocol fields the contract allows
/// (`MIDIProtocolStamp`). The capture's sample clock, generation and musical round-trip frame are not part of the
/// record.
struct MIDICaptureV1Record: Hashable, Sendable {
    static let kind = "midiCapture"
    /// A bound of this exporter, not of the schema (which needs only a non-empty note): the TKX1 note bound.
    static let maximumNoteBytes = MediaContractV1Note.maximumBytes

    let seq: Int
    let stream: StreamID
    /// The packet's words verbatim, each as uppercase `0x` plus 8 hex digits.
    let ump: [String]
    let hostTicks: UInt64
    let frame: Int64
    /// Present exactly when the capture has musical ticks (a transport was anchored).
    let musicalTicks: Int64?
    let endpointProtocol: MIDIEndpointProtocol
    let portProtocol: MIDIPortProtocol
    /// `os` exactly when `MIDIProtocolStamp.translatedByOS`, otherwise `none`.
    let translatedBy: String
    let effective: MIDIPortProtocol
    /// False exactly when the endpoint protocol is `unknown`. Written only when false, as in example 10; the
    /// checker reads an absent `verified` as true.
    let verified: Bool
    let note: String?

    /// Builds the record for `capture` at trace position `seq`, or throws the first refusal in the order
    /// `MIDICaptureV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ capture: MIDICaptureRecord, seq: Int,
                     note: String? = nil) throws(MIDICaptureV1RecordRefusal) -> MIDICaptureV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(capture.stream.rawValue) else { throw .invalidStream(capture.stream) }
        if let ticks = capture.musicalTicks, ticks < 0 { throw .negativeMusicalTicks(ticks) }
        if let note {
            let bytes = note.utf8.count
            guard MediaContractV1Note.isValid(note) else {
                throw .invalidNote(bytes: bytes)
            }
        }
        let stamp = capture.protocolStamp
        let translatedBy = stamp.translatedByOS ? "os" : "none"
        return MIDICaptureV1Record(
            seq: seq, stream: capture.stream, ump: capture.packet.words.map { String(format: "0x%08X", $0) },
            hostTicks: capture.host.ticks, frame: capture.sample.frame, musicalTicks: capture.musicalTicks,
            endpointProtocol: stamp.endpoint, portProtocol: stamp.port, translatedBy: translatedBy,
            effective: stamp.effective, verified: stamp.verified, note: note)
    }

    private init(seq: Int, stream: StreamID, ump: [String], hostTicks: UInt64, frame: Int64, musicalTicks: Int64?,
                 endpointProtocol: MIDIEndpointProtocol, portProtocol: MIDIPortProtocol, translatedBy: String,
                 effective: MIDIPortProtocol, verified: Bool, note: String?) {
        self.seq = seq
        self.stream = stream
        self.ump = ump
        self.hostTicks = hostTicks
        self.frame = frame
        self.musicalTicks = musicalTicks
        self.endpointProtocol = endpointProtocol
        self.portProtocol = portProtocol
        self.translatedBy = translatedBy
        self.effective = effective
        self.verified = verified
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the schema's
    /// fields; `musicalTicks` and `note` are omitted when absent and `verified` when true. Records built from the
    /// same capture and `seq`, with byte-identical `note` text, encode to identical bytes. Swift `String` equality is
    /// canonical, so records whose notes differ only in Unicode normalization (`"\u{00E9}"` vs `"e\u{0301}"`)
    /// compare equal but encode differently; text is never normalized.
    /// The output is bounded: at most 4 words, a stream ID of at most `ContractID.maximumLength` (128) bytes, and a
    /// note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension MIDICaptureV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, stream, ump, hostTicks, frame, musicalTicks, endpointProtocol, portProtocol, translatedBy
        case effective, verified, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(stream, forKey: .stream)
        try container.encode(ump, forKey: .ump)
        try container.encode(hostTicks, forKey: .hostTicks)
        try container.encode(frame, forKey: .frame)
        try container.encodeIfPresent(musicalTicks, forKey: .musicalTicks)
        try container.encode(endpointProtocol.rawValue, forKey: .endpointProtocol)
        try container.encode(portProtocol.rawValue, forKey: .portProtocol)
        try container.encode(translatedBy, forKey: .translatedBy)
        try container.encode(effective.rawValue, forKey: .effective)
        try container.encodeIfPresent(verified ? nil : false, forKey: .verified)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
