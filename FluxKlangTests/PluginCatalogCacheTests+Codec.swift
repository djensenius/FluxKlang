import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginCatalogCacheTests {
    @Test func anEmptySnapshotEncodesToTheDocumentedBytesAndRoundTrips() throws {
        let snapshot = try Self.snapshot([])
        let bytes = [UInt8](try snapshot.encoded())
        #expect(bytes == Raw.frame(entries: []))
        #expect(bytes.count == 4 + 2 + 4 + (2 + 4) + (2 + 3) + 8 + 4 + 8)
        #expect(try Self.decode(bytes) == snapshot)
        #expect(try Self.decode(bytes).entries.isEmpty)
    }

    @Test func aOneEntrySnapshotEncodesToTheHandBuiltLayoutAndRoundTrips() throws {
        let snapshot = try Self.snapshot([Self.entry(Self.identity("Verb"))])
        let bytes = [UInt8](try snapshot.encoded())
        #expect(bytes == Raw.frame(entries: [Raw.Entry("Verb")]))
        let decoded = try Self.decode(bytes)
        #expect(decoded == snapshot)
        #expect(decoded.entries.first?.lastKnown?.name == "Plugin")
        #expect(decoded.stamp == (try Self.stamp()))
    }

    @Test func midiFlagsAndBusShapesAreWrittenAsTheirOwnBits() throws {
        let cases: [(UInt8, [Bool])] = [(0, [false, false]), (1, [true, false]), (2, [false, true]), (3, [true, true])]
        for (flags, midi) in cases {
            let identity = try Self.identity("Verb")
            let buses = try Self.layout(inputs: [1, 2, 64], outputs: [], midiIn: midi[0], midiOut: midi[1])
            let entry = try PluginCatalogEntry(
                identity: identity, presence: .installed, lastKnown: Self.descriptor(identity, buses: buses)
            )
            var expected = Raw.Entry("Verb")
            expected.descriptor = Raw.descriptor(
                inputs: Raw.counted([1, 2, 64]), outputs: Raw.counted([]), flags: flags
            )
            let bytes = [UInt8](try Self.snapshot([entry]).encoded())
            #expect(bytes == Raw.frame(entries: [expected]))
            #expect(try Self.decode(bytes).entries == [entry])
        }
    }

    @Test func everyFailurePresenceIsWrittenAndReadBackExactly() throws {
        let failures: [(PluginPresence, [UInt8])] = [
            (.missing, [1]), (.needsRescan, [3]),
            (.failed(.metadataUnavailable), [2, 0]), (.failed(.validationFailed), [2, 2]),
            (.failed(.invalidMetadata(.invalidName)), [2, 1, 0]),
            (.failed(.invalidMetadata(.invalidManufacturerName)), [2, 1, 1]),
            (.failed(.invalidMetadata(.tooManyBuses(.input, count: 65))), [2, 1, 2, 0] + Raw.big(Int64(65))),
            (.failed(.invalidMetadata(.tooManyBuses(.output, count: Int.max))), [2, 1, 2, 1] + Raw.big(Int64.max)),
            (.failed(.invalidMetadata(.invalidChannelCount(.input, bus: 3, count: 0))),
             [2, 1, 3, 0] + Raw.big(Int64(3)) + Raw.big(Int64(0))),
            (.failed(.invalidMetadata(.invalidChannelCount(.output, bus: -1, count: Int.min))),
             [2, 1, 3, 1] + Raw.big(Int64(-1)) + Raw.big(Int64.min))
        ]
        for (presence, bytes) in failures {
            let entry = try Self.entry(Self.identity("Verb"), presence, described: false)
            var expected = Raw.Entry("Verb")
            expected.presence = bytes
            expected.descriptor = nil
            let encoded = [UInt8](try Self.snapshot([entry]).encoded())
            #expect(encoded == Raw.frame(entries: [expected]), "\(presence)")
            #expect(try Self.decode(encoded).entries == [entry], "\(presence)")
        }
    }

    @Test func quarantineReasonsAndTheSecondFormatRoundTrip() throws {
        let crashed = try Self.entry(Self.identity("Aaaa"), .needsRescan, described: false, quarantine: .probeCrashed)
        let timedOut = try Self.entry(Self.identity("Bbbb"), .installed, quarantine: .probeTimedOut)
        let third = try Self.entry(Self.identity("Cccc", format: .audioUnitV3))
        let bytes = [UInt8](try Self.snapshot([third, timedOut, crashed]).encoded())
        var first = Raw.Entry("Aaaa")
        first.presence = [3]
        first.quarantine = 1
        first.descriptor = nil
        var second = Raw.Entry("Bbbb")
        second.quarantine = 2
        var last = Raw.Entry("Cccc")
        last.format = 1
        #expect(bytes == Raw.frame(entries: [first, second, last]))
        #expect(try Self.decode(bytes).entries == [crashed, timedOut, third])
    }

    @Test func entriesAreOrderedByFormatTypeSubtypeThenManufacturerWhateverTheInputOrder() throws {
        let ordered = try [
            Self.identity("Zzzz"), Self.identity("Aaaa", manufacturer: "Abcd"), Self.identity("Aaaa"),
            Self.identity("Aaaa", type: "aumu"), Self.identity("Aaaa", format: .audioUnitV3),
            Self.identity("Bbbb", manufacturer: "Aaaa")
        ]
        let expected = try ordered.map { try Self.entry($0) }
        let arrangements = [
            expected, expected.reversed(),
            [expected[2], expected[5], expected[4], expected[0], expected[3], expected[1]]
        ]
        for arrangement in arrangements {
            let snapshot = try Self.snapshot(arrangement)
            #expect(snapshot.entries.map(\.identity)
                == [ordered[1], ordered[2], ordered[5], ordered[0], ordered[3], ordered[4]])
            #expect(try snapshot.encoded() == Self.snapshot(expected).encoded())
        }
    }

    @Test func reEncodingADecodedSnapshotGivesTheSameBytes() throws {
        let snapshot = try Self.snapshot([
            Self.entry(Self.identity("Verb")), Self.entry(Self.identity("Echo"), .missing),
            Self.entry(Self.identity("Gone"), .failed(.validationFailed), described: false, quarantine: .probeCrashed)
        ])
        let first = try snapshot.encoded()
        let decoded = try PluginCatalogSnapshot.decode(from: first)
        #expect(try decoded.encoded() == first)
        #expect(try snapshot.encoded() == first)
        #expect(decoded == snapshot)
    }

    @Test func captureReadsEveryEntryAndStampsTheCatalogGeneration() throws {
        let catalog = try Self.busyCatalog()
        let before = catalog
        let snapshot = try PluginCatalogSnapshot.capture(from: catalog, osVersion: "27.0", hostBuild: "1A1")
        #expect(catalog == before)
        #expect(snapshot.stamp.generation == catalog.generation)
        #expect(snapshot.stamp.generation.value == 2)
        #expect(snapshot.stamp.formatVersion == 1)
        let subtypes = snapshot.entries.map(\.identity.subtype.description)
        #expect(subtypes == ["Boom", "Echo", "Fail", "Verb"])
        #expect(snapshot.entries.map(\.presence) == [.needsRescan, .installed, .failed(.validationFailed), .installed])
        #expect(snapshot.entries.map(\.quarantine) == [.probeCrashed, nil, nil, nil])
        #expect(snapshot.entries.map { $0.lastKnown == nil } == [true, false, true, false])
        for entry in snapshot.entries { #expect(catalog.entries[entry.identity.id] == entry) }
        #expect(snapshot.entries.count == catalog.entries.count)
    }

    @Test func captureIsTheSameWhateverOrderTheScanReportedComponentsIn() throws {
        let forward = try Self.busyCatalog()
        var reversed = PluginCatalog()
        let report = try PluginScanReport(entries: Array(Self.entriesOfBusyReport().reversed()))
        _ = try reversed.apply(report, for: reversed.request(depth: .instantiatingProbe))
        let one = try PluginCatalogSnapshot.capture(from: forward, osVersion: "27.0", hostBuild: "1A1")
        let two = try PluginCatalogSnapshot.capture(from: reversed, osVersion: "27.0", hostBuild: "1A1")
        #expect(one == two)
        #expect(try one.encoded() == two.encoded())
    }

    @Test func aCaptureThatIsRefusedLeavesTheCatalogUnchanged() throws {
        let catalog = try Self.busyCatalog()
        let before = catalog
        #expect(throws: PluginCatalogCacheError.invalidStamp(.osVersion)) {
            try PluginCatalogSnapshot.capture(from: catalog, osVersion: "", hostBuild: "1A1")
        }
        #expect(throws: PluginCatalogCacheError.invalidStamp(.hostBuild)) {
            try PluginCatalogSnapshot.capture(from: catalog, osVersion: "27.0", hostBuild: "bad\u{0}")
        }
        #expect(catalog == before)
    }

    @Test func theChecksumIsFNV1a64WithThePublishedTestVectors() {
        #expect(Codec.checksum([UInt8]()) == 0xcbf2_9ce4_8422_2325)
        #expect(Codec.checksum(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
        #expect(Codec.checksum(Array("foobar".utf8)) == 0x8594_4171_f739_67e8)
        #expect(Codec.checksum(Array("foobar".utf8)) == Raw.fnv(Array("foobar".utf8)))
    }

    @Test func theStampKeepsItsStringsByteForByteAndItsGenerationAtTheExtremes() throws {
        for generation in [1, Generation.maximumValue] {
            let stamp = try Self.stamp(os: "e\u{301} 27", host: "Büild", generation: generation)
            let decoded = try Self.decode([UInt8](try Self.snapshot([], stamp: stamp).encoded()))
            #expect(decoded.stamp == stamp)
            #expect(Array(decoded.stamp.osVersion.utf8) == Array("e\u{301} 27".utf8))
            #expect(decoded.stamp.hostBuild.utf8.count == "Büild".utf8.count)
            #expect(decoded.stamp.generation.value == generation)
        }
    }

    @Test func stampsComparedByBytesDifferWhereCanonicalEquivalenceWouldMergeThem() throws {
        #expect("\u{e9}" == "e\u{301}")
        let composed = try Self.stamp(os: "\u{e9}")
        let decomposed = try Self.stamp(os: "e\u{301}")
        #expect(composed != decomposed)
        #expect(composed == (try Self.stamp(os: "\u{e9}")))
        #expect(try Self.stamp(host: "\u{e9}") != Self.stamp(host: "e\u{301}"))
        #expect(try Self.stamp(host: "1A1") != Self.stamp(host: "1A2"))
        #expect(try Self.stamp(format: 1) != Self.stamp(format: 2))
        #expect(try Self.stamp(generation: 5) != Self.stamp(generation: 6))
    }

    @Test func dataSlicesWithANonZeroStartDecodeLikeTheirContents() throws {
        let snapshot = try Self.snapshot([Self.entry(Self.identity("Verb"))])
        let padded = Data([9, 9, 9] + [UInt8](try snapshot.encoded()))
        #expect(try PluginCatalogSnapshot.decode(from: padded.dropFirst(3)) == snapshot)
    }

    static func entriesOfBusyReport() throws -> [PluginScanEntry] {
        let described = try [identity("Verb"), identity("Echo")]
        return try described.map { PluginScanEntry(identity: $0, outcome: .described(try descriptor($0))) }
            + [PluginScanEntry(identity: identity("Fail"), outcome: .failed(.validationFailed)),
               PluginScanEntry(identity: identity("Boom"), outcome: .probeCrashed)]
    }
}
