import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginCatalogCacheTests {
    static let describedLimit = PluginCatalogLimits.entries
    static let totalLimit = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom

    static func plainEntries(_ count: Int) throws -> [PluginCatalogEntry] {
        try (0..<count).map { try plainEntry($0) }
    }

    static func bareEntries(_ range: Range<Int>) throws -> [PluginCatalogEntry] {
        try range.map { try bareEntry($0) }
    }

    /// A well-formed frame of `count` smallest ordinary entries, ascending on the wire.
    static func plainFrame(count: Int) -> [UInt8] {
        let entries = (0..<count).map { index -> Raw.Entry in
            var entry = Raw.Entry("Aaaa")
            entry.subtype = subtypeCode(index)
            entry.presence = [1]
            entry.descriptor = nil
            return entry
        }
        return Raw.frame(entries: entries)
    }

    @Test func theByteLimitIsTheExactWorstCaseOfAFullCatalog() {
        #expect(Codec.maximumBytes == 546 + 4_096 * 686 + 256 * 35)
        #expect(Codec.maximumBytes == 2_819_362)
        #expect(PluginCatalogLimits.entries == 4_096 && PluginCatalogLimits.quarantineHeadroom == 256)
    }

    @Test func aFullCatalogOfLargestEntriesEncodesToExactlyTheByteLimitAndRoundTrips() throws {
        let described = try (0..<Self.describedLimit).map { try Self.largestDescribedEntry($0) }
        let bare = try (Self.describedLimit..<Self.totalLimit).map { try Self.largestBareEntry($0) }
        let longest = String(repeating: "s", count: 256)
        let snapshot = try Self.snapshot(bare + described, stamp: Self.stamp(os: longest, host: longest))
        let data = try snapshot.encoded()
        #expect(snapshot.entries.count == 4_352)
        #expect(data.count == Codec.maximumBytes)
        let decoded = try PluginCatalogSnapshot.decode(from: data)
        #expect(decoded == snapshot)
        #expect(try decoded.encoded() == data)
        let over = PluginCatalogCacheError.oversized(bytes: Codec.maximumBytes + 1, maximum: Codec.maximumBytes)
        #expect(Self.refusal([UInt8](data) + [0]) == over)
    }

    @Test func aSnapshotAcceptsTheEntryLimitAndRefusesOneMore() throws {
        let full = try Self.plainEntries(Self.describedLimit) + Self.bareEntries(Self.describedLimit..<Self.totalLimit)
        #expect(try Self.snapshot(full).entries.count == 4_352)
        let extra = try Self.bareEntry(Self.totalLimit)
        #expect(throws: PluginCatalogCacheError.tooManyEntries(count: 4_353, maximum: 4_352)) {
            try Self.snapshot(full + [extra])
        }
        #expect(throws: PluginCatalogCacheError.tooManyEntries(count: 4_353, maximum: 4_352)) {
            try Self.snapshot([extra] + full)
        }
    }

    @Test func aSnapshotAcceptsTheDescribedEntryLimitAndRefusesOneMore() throws {
        #expect(try Self.snapshot(Self.plainEntries(Self.describedLimit)).entries.count == 4_096)
        let over = try Self.plainEntries(Self.describedLimit + 1)
        #expect(throws: PluginCatalogCacheError.tooManyDescribedEntries(count: 4_097, maximum: 4_096)) {
            try Self.snapshot(over)
        }
        #expect(throws: PluginCatalogCacheError.tooManyDescribedEntries(count: 4_097, maximum: 4_096)) {
            try Self.snapshot(over.reversed())
        }
        let tooMany = try Self.plainEntries(Self.totalLimit + 1)
        #expect(throws: PluginCatalogCacheError.tooManyEntries(count: 4_353, maximum: 4_352)) {
            try Self.snapshot(tooMany)
        }
    }

    @Test func aBareQuarantinedEntryNeverCountsAgainstTheDescribedLimit() throws {
        let extra = Self.describedLimit..<(Self.describedLimit + 1)
        let entries = try Self.plainEntries(Self.describedLimit) + Self.bareEntries(extra)
        #expect(try Self.snapshot(entries).entries.count == 4_097)
    }

    @Test func theDecoderCountsEntriesBeforeReadingThemAtNAndNPlusOne() {
        let stamp = Raw.stamp()
        let total = UInt32(Self.totalLimit)
        #expect(Self.refusal(Raw.frame(stamp + Raw.big(total + 1)))
            == .tooManyEntries(count: 4_353, maximum: 4_352))
        #expect(Self.refusal(Raw.frame(stamp + Raw.big(UInt32.max)))
            == .tooManyEntries(count: Int(UInt32.max), maximum: 4_352))
        #expect(Self.refusal(Raw.frame(stamp + Raw.big(total))) == .truncated)
    }

    @Test func theDecoderAcceptsTheDescribedEntryLimitAndRefusesOneMore() throws {
        let accepted = try Self.decode(Self.plainFrame(count: Self.describedLimit))
        #expect(accepted.entries.count == 4_096)
        #expect(Self.refusal(Self.plainFrame(count: Self.describedLimit + 1))
            == .tooManyDescribedEntries(count: 4_097, maximum: 4_096))
    }

    @Test func nameLimitsAreCountedInUTF8BytesNotCharacters() throws {
        func refusalFor(_ name: String) -> PluginCatalogCacheError? {
            Self.refusal(Self.framed { $0.descriptor = Raw.descriptor(name: Raw.text(name)) })
        }
        let ascii256 = String(repeating: "n", count: 256)
        let twoByte128 = String(repeating: "\u{e9}", count: 128)
        let threeByte86 = String(repeating: "e\u{301}", count: 86)
        #expect(ascii256.utf8.count == 256 && twoByte128.utf8.count == 256 && threeByte86.utf8.count == 258)
        #expect(refusalFor(ascii256) == nil)
        #expect(refusalFor(twoByte128) == nil)
        #expect(refusalFor(ascii256 + "n") == .invalidDescriptor(index: 1, .invalidName))
        #expect(refusalFor(twoByte128 + "n") == .invalidDescriptor(index: 1, .invalidName))
        #expect(refusalFor(threeByte86) == .invalidDescriptor(index: 1, .invalidName))
        let decoded = try Self.decode(Self.framed { $0.descriptor = Raw.descriptor(name: Raw.text(twoByte128)) })
        #expect(decoded.entries[1].lastKnown?.name.utf8.count == 256)
    }

    @Test func manufacturerNameAndStampStringLimitsAreInclusiveAtTheLimit() throws {
        let ascii256 = String(repeating: "m", count: 256)
        let maker = Self.framed { $0.descriptor = Raw.descriptor(maker: Raw.text(ascii256)) }
        #expect(Self.refusal(maker) == nil)
        let makerOver = Self.framed { $0.descriptor = Raw.descriptor(maker: Raw.text(ascii256 + "m")) }
        #expect(Self.refusal(makerOver) == .invalidDescriptor(index: 1, .invalidManufacturerName))
        let stampAt = Raw.frame(Raw.payload(Raw.stamp(os: Raw.text(ascii256), host: Raw.text(ascii256)), entries: []))
        #expect(try Self.decode(stampAt).stamp.hostBuild.utf8.count == 256)
        #expect(try Self.stamp(os: ascii256, host: ascii256).osVersion.utf8.count == 256)
        #expect(throws: PluginCatalogCacheError.invalidStamp(.osVersion)) { try Self.stamp(os: ascii256 + "o") }
        #expect(throws: PluginCatalogCacheError.invalidStamp(.hostBuild)) { try Self.stamp(host: ascii256 + "h") }
    }

    @Test func busAndChannelLimitsAcceptTheLimitAndRefuseOneMoreInBothDirections() throws {
        func refusalFor(inputs: [UInt8], outputs: [UInt8]) -> PluginCatalogCacheError? {
            Self.refusal(Self.framed {
                $0.descriptor = Raw.descriptor(inputs: Raw.counted(inputs), outputs: Raw.counted(outputs))
            })
        }
        let sixtyFour = [UInt8](repeating: 1, count: 64)
        let sixtyFive = [UInt8](repeating: 1, count: 65)
        #expect(refusalFor(inputs: sixtyFour, outputs: sixtyFour) == nil)
        let tooManyIn = PluginCatalogCacheError.invalidDescriptor(index: 1, .tooManyBuses(.input, count: 65))
        let tooManyOut = PluginCatalogCacheError.invalidDescriptor(index: 1, .tooManyBuses(.output, count: 65))
        #expect(refusalFor(inputs: sixtyFive, outputs: [1]) == tooManyIn)
        #expect(refusalFor(inputs: [1], outputs: sixtyFive) == tooManyOut)
        for (channels, accepted) in [(UInt8(0), false), (1, true), (64, true), (65, false)] {
            let input = refusalFor(inputs: [2, channels], outputs: [2])
            let output = refusalFor(inputs: [2], outputs: [2, channels])
            if accepted {
                #expect(input == nil && output == nil, "\(channels)")
            } else {
                let count = Int(channels)
                #expect(input == .invalidDescriptor(index: 1, .invalidChannelCount(.input, bus: 1, count: count)))
                #expect(output == .invalidDescriptor(index: 1, .invalidChannelCount(.output, bus: 1, count: count)))
            }
        }
    }
}
