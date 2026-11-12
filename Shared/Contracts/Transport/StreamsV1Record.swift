//
//  StreamsV1Record.swift
//  FluxKlang
//
//  The streams a trace declares, as the media contract v1 trace's top-level `streams` array (#107 STR1,
//  media-contract §6.5): validated fail-closed and encoded deterministically. Pure: it reads a list and writes no
//  file; it numbers and reorders nothing.
//

import Foundation

/// The `streams` header (an array of `$defs.stream`) of a contract v1 trace. Built only by `make`.
///
/// A trace with no streams omits the header (the checker treats an absent header and `[]` alike), so `make`
/// refuses an empty list. Ordinals are the caller's, fixed at prepare time (§6.5): they need not be dense or start
/// at 0, and the list keeps the caller's order. They are written exactly from 0 through `Int.max`; the schema has
/// no maximum, so a larger value is schema-valid but cannot be held.
///
/// Not checked here, because they need the rest of the trace: that every `stream` a record names is declared, that
/// a stream's `media` and `direction` fit the record that uses it, and the dispatch order of §6.5. Refusing a
/// repeated ordinal is this exporter's rule and is stricter than the checker, which accepts it.
struct StreamsV1Record: Hashable, Sendable {
    enum Media: String, CaseIterable, Hashable, Sendable { case audio, midi, state }
    enum Direction: String, CaseIterable, Hashable, Sendable { case playback, capture }

    struct Stream: Hashable, Sendable {
        let id: StreamID
        let ordinal: Int
        let media: Media
        let direction: Direction
    }

    /// The same bound as `ClocksV1Record`'s tempo segments and `ActionReadiness`'s action capacity.
    static let maximumStreams = 4096

    /// The streams in the caller's order, never sorted.
    let streams: [Stream]

    /// Builds the header from `streams`, or throws the first refusal in the order `StreamsV1RecordRefusal`
    /// documents. Never clamps, remaps, sorts, drops or deduplicates a stream.
    static func make(_ streams: [Stream]) throws(StreamsV1RecordRefusal) -> StreamsV1Record {
        guard !streams.isEmpty else { throw .empty }
        guard streams.count <= maximumStreams else { throw .tooManyStreams(count: streams.count) }
        var ids = Set<StreamID>()
        var ordinals = Set<Int>()
        for stream in streams {
            guard MediaContractV1ID.matches(stream.id.rawValue) else { throw .invalidStreamID(stream.id) }
            guard stream.ordinal >= 0 else { throw .negativeOrdinal(stream.id, stream.ordinal) }
            guard ids.insert(stream.id).inserted else { throw .duplicateStreamID(stream.id) }
            guard ordinals.insert(stream.ordinal).inserted else {
                throw .duplicateOrdinal(stream.id, ordinal: stream.ordinal)
            }
        }
        return StreamsV1Record(streams: streams)
    }

    private init(streams: [Stream]) {
        self.streams = streams
    }

    /// Compact UTF-8 JSON with sorted keys (`ContractCoding`): one array of `{direction, media, ordinal, streamId}`
    /// members in the caller's order. Identical input encodes to identical bytes. The output is bounded by the
    /// input: at most 4096 members, each with an ID of at most `ContractID.maximumLength` (128) bytes.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension StreamsV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case streamId, ordinal, media, direction
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(streams.map(Member.init))
    }

    private struct Member: Encodable {
        let stream: Stream

        init(_ stream: Stream) {
            self.stream = stream
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stream.id, forKey: .streamId)
            try container.encode(stream.ordinal, forKey: .ordinal)
            try container.encode(stream.media.rawValue, forKey: .media)
            try container.encode(stream.direction.rawValue, forKey: .direction)
        }
    }
}
