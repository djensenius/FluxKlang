//
//  PeerControlMessage.swift
//  FluxKlang
//
//  The canonical binary codec for the payload of a `PeerFrameKind.control` frame
//  (#95, slice S2). It only converts values: no clock, no randomness, no
//  transport. Decode is total: any byte string yields a value or one typed
//  refusal, and no refusal returns a partial value.
//

import Foundation

/// One control message. The layout is provisional v1 (Q-PEER-WIRE); every
/// integer is big-endian and every double travels as its IEEE-754 bit pattern.
///
///     message  = tag:u8 body
///     tag      = 1 snapshot | 2 delta | 3 resync | 4 command | 5 result
///     id       = length:u8 (1...128) utf8 bytes
///     session  = host:id hostGeneration:u64 connection:id connectionGeneration:u64
///     revs     = patch capability permission parameter graph (5 x u64, each 0...2^53-1)
///     value    = bits:u64 (finite) unit:u8 (1 decibels 2 normalized 3 percent 4 pan 5 index 6 boolean)
///     snapshot = session sequence:u64 revs count:u32 (id value) * count
///     delta    = session sequence:u64 revs updates:u32 removals:u32 (id value) * updates id * removals
///     resync   = session lastApplied:u64 reason:u8 (1 gap expected:u64 found:u64 | 2 repeated:u64
///                | 3 unappliable | 4 snapshotRefused)
///     command  = sequence:u64 intent (see `PeerControlMessage+Command.swift`)
///     result   = sequence:u64 command:id outcome (see `PeerControlMessage+Command.swift`)
///
/// Snapshot and delta entries are sorted strictly ascending by the UTF-8 bytes
/// of their id, and delta updates and removals are disjoint, so every message
/// has exactly one encoding: equal bytes decode to equal messages, and decoding
/// then encoding reproduces the bytes bit for bit. The converse does not hold
/// for signed zero: `Double ==` treats +0.0 and -0.0 as equal, so two messages
/// that compare `==` can differ in the sign of a zero and then encode to
/// different bytes. Command and result messages carry no session header:
/// the intent holds its own epochs, and staleness is the command processor's
/// decision, not the codec's. Sequences are 0...2^53-1 and generations are
/// 1...2^53-1; a decoded value goes through the same throwing factories as a
/// local one, and a factory refusal is `malformed`. An unknown tag inside a
/// message is `malformed`; only the first payload byte can be `unknownTag`.
///
/// Deviation from `PeerResyncReason`: the inner `PeerSyncError` detail is
/// host-local and never crosses the wire (`PeerResyncWireReason`).
///
/// Decode order: payload size, tag, session, sequence and revisions, entry counts
/// against the limits, entry counts against the remaining bytes, then the entries.
/// The layout is not versioned and is not negotiated; this slice is not wired into
/// any transport.
enum PeerControlMessage: Equatable, Sendable {
    case snapshot(PeerSyncSnapshot)
    case delta(PeerSyncDelta)
    case resync(PeerResyncWireRequest)
    case command(PeerCommandEnvelope)
    case result(PeerCommandResult)

    /// The first payload byte.
    enum Tag: UInt8, CaseIterable, Sendable {
        case snapshot = 1
        case delta = 2
        case resync = 3
        case command = 4
        case result = 5
    }

    /// Fixed wire bounds. `PermissionFingerprint.utf8Bounds` is the fingerprint bound.
    enum Wire {
        static let idBytes = 1...128
        /// The smallest snapshot entry or delta update: a one-byte id, its length, a double and a unit.
        static let minimumValueEntryBytes = 11
        /// The smallest delta removal: a one-byte id and its length.
        static let minimumRemovalBytes = 2
    }

    var tag: Tag {
        switch self {
        case .snapshot: .snapshot
        case .delta: .delta
        case .resync: .resync
        case .command: .command
        case .result: .result
        }
    }
}

/// Why a resync was requested, without the host-local `PeerSyncError` detail.
enum PeerResyncWireReason: Hashable, Sendable {
    case gap(expected: PeerSequence, found: PeerSequence)
    case repeated(PeerSequence)
    case unappliable
    case snapshotRefused

    init(_ reason: PeerResyncReason) {
        switch reason {
        case .gap(let expected, let found): self = .gap(expected: expected, found: found)
        case .repeated(let sequence): self = .repeated(sequence)
        case .unappliable: self = .unappliable
        case .snapshotRefused: self = .snapshotRefused
        }
    }
}

/// The wire form of `PeerResyncRequest`.
struct PeerResyncWireRequest: Hashable, Sendable {
    let session: PeerSyncSession
    let lastApplied: PeerSequence
    let reason: PeerResyncWireReason

    init(session: PeerSyncSession, lastApplied: PeerSequence, reason: PeerResyncWireReason) {
        self.session = session
        self.lastApplied = lastApplied
        self.reason = reason
    }

    init(_ request: PeerResyncRequest) {
        self.init(session: request.session, lastApplied: request.lastApplied,
                  reason: PeerResyncWireReason(request.reason))
    }
}

/// Why a value cannot be encoded.
enum PeerControlUnencodable: Hashable, Sendable {
    /// A `CommandIntent` carrying extension data, top-level or nested in a known object: the wire has no place for it.
    case unknownFields
    /// `CommandResult.trigger` is deferred in this slice.
    case trigger
    /// A delta that updates and removes the same id.
    case overlappingChanges
    /// An id or fingerprint whose UTF-8 length is outside its bounds.
    case textLength(Int)
    /// An integer outside its wire field (a negative or 2^32 or larger ledger capacity).
    case integerOutOfRange(Int)
}

enum PeerControlMessageError: Error, Hashable, Sendable {
    /// The bytes ended early, a field was invalid, or bytes trail the message.
    /// `offset` is the first byte of the field that could not be read or validated.
    case malformed(offset: Int)
    case unknownTag(UInt8)
    case sessionMismatch
    /// More entries than the limits allow; the count that was refused.
    case tooManyEntries(Int)
    /// Unsorted, duplicate or overlapping entries.
    case notCanonical
    case nonFiniteValue
    case unencodable(PeerControlUnencodable)
    /// The payload size that exceeded `PeerFrameLimits.maximumPayloadBytes`.
    case payloadTooLarge(Int)
}

/// A closed enumeration that crosses the wire as one byte. Decode looks the byte
/// up in `wireCases`, so a case missing there is refused rather than guessed.
protocol PeerControlCoded: Sendable {
    static var wireCases: [Self] { get }
    var wireCode: UInt8 { get }
}

extension PeerControlCoded {
    init?(wireCode: UInt8) {
        guard let match = Self.wireCases.first(where: { $0.wireCode == wireCode }) else { return nil }
        self = match
    }
}

extension ControlClass: PeerControlCoded {
    static var wireCases: [ControlClass] { allCases }

    var wireCode: UInt8 {
        switch self {
        case .live: 1
        case .structural: 2
        case .hazardous: 3
        case .safety: 4
        case .proposal: 5
        }
    }
}

extension CommandOrigin: PeerControlCoded {
    static var wireCases: [CommandOrigin] { [.human, .controller, .assistant] }

    var wireCode: UInt8 {
        switch self {
        case .human: 1
        case .controller: 2
        case .assistant: 3
        }
    }
}

extension ParameterUnit: PeerControlCoded {
    static var wireCases: [ParameterUnit] { [.decibels, .normalized, .percent, .pan, .index, .boolean] }

    var wireCode: UInt8 {
        switch self {
        case .decibels: 1
        case .normalized: 2
        case .percent: 3
        case .pan: 4
        case .index: 5
        case .boolean: 6
        }
    }
}

extension GenerationKind: PeerControlCoded {
    static var wireCases: [GenerationKind] { allCases }

    var wireCode: UInt8 {
        switch self {
        case .sampleClock: 1
        case .transport: 2
        case .musicalMap: 3
        case .source: 4
        case .context: 5
        case .cancelScope: 6
        }
    }
}
