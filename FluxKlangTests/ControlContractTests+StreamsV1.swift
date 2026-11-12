//
//  ControlContractTests+StreamsV1.swift
//  FluxKlangTests
//
//  The media contract v1 `streams` header builder (#107 STR1): every example's header byte for byte, extra golden
//  rows, the 4096 bound, shape and determinism. Refusals are in ControlContractTests+StreamsV1Refusals.swift.
//

import Foundation
import Testing
@testable import FluxKlang

typealias StreamsV1Stream = StreamsV1Record.Stream

/// A `StreamID` from a runtime string; the tests only pass IDs `ContractID` itself admits.
func streamsV1ID(_ raw: String) -> StreamID {
    guard let id = StreamID(rawValue: raw) else { preconditionFailure("Not a ContractID: \(raw)") }
    return id
}

func streamsV1(_ id: String, _ ordinal: Int, _ media: StreamsV1Record.Media = .midi,
               _ direction: StreamsV1Record.Direction = .capture) -> StreamsV1Stream {
    StreamsV1Stream(id: streamsV1ID(id), ordinal: ordinal, media: media, direction: direction)
}

private func json(_ record: StreamsV1Record) throws -> String {
    try #require(String(data: record.encodedJSON(), encoding: .utf8))
}

private struct GoldenStreams {
    let label: String
    let streams: [StreamsV1Stream]
    let json: String
}

private func member(_ direction: String, _ media: String, _ ordinal: String, _ id: String) -> String {
    #"{"direction":"\#(direction)","media":"\#(media)","ordinal":\#(ordinal),"streamId":"\#(id)"}"#
}

private let longID = "str." + String(repeating: "a", count: 124)

/// Examples: the `streams` array of each example file, via
/// `json.dumps(streams, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`. Rows without `ex` are
/// hand-derived and validated against `$defs.stream` with the checker's `validate`.
private let goldenStreams: [GoldenStreams] = [
    .init(label: "ex 01", streams: [streamsV1("str.bed", 0, .audio, .playback)],
          json: "[" + member("playback", "audio", "0", "str.bed") + "]"),
    .init(label: "ex 03",
          streams: [streamsV1("str.state", 0, .state, .playback), streamsV1("str.verse", 1, .midi, .playback),
                    streamsV1("str.keys-in", 2, .midi, .capture)],
          json: "[" + member("playback", "state", "0", "str.state") + "," + member("playback", "midi", "1", "str.verse")
            + "," + member("capture", "midi", "2", "str.keys-in") + "]"),
    .init(label: "ex 04", streams: [streamsV1("str.pads-in", 0)],
          json: "[" + member("capture", "midi", "0", "str.pads-in") + "]"),
    .init(label: "ex 05", streams: [streamsV1("str.backing", 0, .audio, .playback)],
          json: "[" + member("playback", "audio", "0", "str.backing") + "]"),
    .init(label: "ex 08", streams: [streamsV1("str.take-in", 0, .audio, .capture)],
          json: "[" + member("capture", "audio", "0", "str.take-in") + "]"),
    .init(label: "ex 09", streams: [streamsV1("str.keys-a", 0), streamsV1("str.keys-b", 1)],
          json: "[" + member("capture", "midi", "0", "str.keys-a") + "," + member("capture", "midi", "1", "str.keys-b")
            + "]"),
    .init(label: "ex 10", streams: [streamsV1("str.synth", 0), streamsV1("str.synth-legacy", 1),
                                    streamsV1("str.synth-unknown", 2)],
          json: "[" + member("capture", "midi", "0", "str.synth") + ","
            + member("capture", "midi", "1", "str.synth-legacy") + ","
            + member("capture", "midi", "2", "str.synth-unknown") + "]"),
    .init(label: "ex 11 12", streams: [streamsV1("str.take-in", 0, .audio, .capture)],
          json: "[" + member("capture", "audio", "0", "str.take-in") + "]")
]

private let handDerivedStreams: [GoldenStreams] = [
    .init(label: "all media x direction",
          streams: [streamsV1("str.a", 0, .audio, .playback), streamsV1("str.b", 1, .audio, .capture),
                    streamsV1("str.c", 2, .midi, .playback), streamsV1("str.d", 3, .midi, .capture),
                    streamsV1("str.e", 4, .state, .playback), streamsV1("str.f", 5, .state, .capture)],
          json: "[" + member("playback", "audio", "0", "str.a") + "," + member("capture", "audio", "1", "str.b")
            + "," + member("playback", "midi", "2", "str.c") + "," + member("capture", "midi", "3", "str.d")
            + "," + member("playback", "state", "4", "str.e") + "," + member("capture", "state", "5", "str.f") + "]"),
    .init(label: "ordinals 0 and Int.max", streams: [streamsV1("str.lo", 0), streamsV1("str.hi", Int.max)],
          json: "[" + member("capture", "midi", "0", "str.lo") + ","
            + member("capture", "midi", "\(Int.max)", "str.hi") + "]"),
    .init(label: "128-byte id", streams: [streamsV1(longID, 0)],
          json: "[" + member("capture", "midi", "0", longID) + "]"),
    .init(label: "non-dense descending ordinals in caller order",
          streams: [streamsV1("str.z", 9), streamsV1("str.m", 4), streamsV1("str.a", 7)],
          json: "[" + member("capture", "midi", "9", "str.z") + "," + member("capture", "midi", "4", "str.m") + ","
            + member("capture", "midi", "7", "str.a") + "]")
]

extension ControlContractTests {
    struct StreamsV1 {
        @Test func streamsV1EncodesEveryExampleHeaderExactly() throws {
            for golden in goldenStreams + handDerivedStreams {
                let record = try StreamsV1Record.make(golden.streams)
                #expect(try json(record) == golden.json, "\(golden.label)")
                #expect(record.streams == golden.streams, "\(golden.label)")
            }
        }

        @Test func streamsV1AcceptsExactlyTheBound() throws {
            let all = (0..<StreamsV1Record.maximumStreams).map { streamsV1("str.s\($0)", $0) }
            let record = try StreamsV1Record.make(all)
            #expect(record.streams.count == 4096)
            let decoded = try #require(try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [Any])
            #expect(decoded.count == 4096)
            let over = all + [streamsV1("str.over", 4096)]
            #expect(throws: StreamsV1RecordRefusal.tooManyStreams(count: 4097)) { try StreamsV1Record.make(over) }
        }

        @Test func streamsV1WritesExactlyTheSchemasFourFieldsAsAnArray() throws {
            let record = try StreamsV1Record.make(goldenStreams[1].streams + [streamsV1("str.x", 3, .audio, .playback)])
            let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON())
            let members = try #require(decoded as? [[String: Any]])
            #expect(members.count == 4)
            for object in members {
                #expect(Set(object.keys) == ["direction", "media", "ordinal", "streamId"])
            }
        }

        @Test func streamsV1IsDeterministic() throws {
            for golden in goldenStreams + handDerivedStreams {
                let first = try StreamsV1Record.make(golden.streams)
                let second = try StreamsV1Record.make(golden.streams)
                #expect(first == second, "\(golden.label)")
                #expect(try first.encodedJSON() == second.encodedJSON(), "\(golden.label)")
                #expect(try first.encodedJSON() == first.encodedJSON(), "\(golden.label)")
            }
        }

        /// Whether a stream's media and direction fit the records that name it is a property of the whole trace.
        @Test func streamsV1LeavesMediaAndDirectionFitToTheTrace() throws {
            // Example 09's two IDs declared as audio: the checker's `stream_is` refuses them once a `midiCapture`
            // record names them, but only the whole trace knows the use.
            let record = try StreamsV1Record.make([streamsV1("str.keys-a", 0, .audio, .playback),
                                                   streamsV1("str.keys-b", 1, .audio, .playback)])
            #expect(record.streams.count == 2)
        }
    }
}
