import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginCatalogCacheTests {
    static func validBytes() throws -> [UInt8] {
        [UInt8](try snapshot([entry(identity("Verb"))]).encoded())
    }

    /// A frame whose second entry (index 1) is built by `edit`; the first entry is valid.
    static func framed(editingSecond edit: (inout Raw.Entry) -> Void) -> [UInt8] {
        var second = Raw.Entry("Bbbb")
        edit(&second)
        return Raw.frame(entries: [Raw.Entry("Aaaa"), second])
    }

    @Test func anInputOverTheByteLimitIsRefusedBeforeAnyParsing() throws {
        let limit = Codec.maximumBytes
        #expect(Self.refusal([UInt8](repeating: 0, count: limit + 1)) == .oversized(bytes: limit + 1, maximum: limit))
        #expect(Self.refusal([UInt8](repeating: 0, count: limit)) == .badMagic)
        let header = Raw.magic + Raw.big(UInt16(1))
        #expect(Self.refusal(header + Raw.big(UInt32(limit - 18))) == .truncated)
        #expect(Self.refusal(header + Raw.big(UInt32(limit - 17))) == .oversized(bytes: limit + 1, maximum: limit))
        #expect(Self.refusal(header + Raw.big(UInt32.max)) == .oversized(bytes: Int(UInt32.max) + 18, maximum: limit))
    }

    @Test func everyProperPrefixOfAnEncodingIsTruncated() throws {
        let snapshot = try Self.snapshot([
            Self.entry(Self.identity("Verb")), Self.entry(Self.identity("Echo"), .missing)
        ])
        let bytes = [UInt8](try snapshot.encoded())
        for length in 0..<bytes.count {
            #expect(Self.refusal(Array(bytes.prefix(length))) == .truncated, "prefix \(length)")
        }
        #expect(try Self.decode(bytes) == snapshot)
    }

    @Test func aWrongMagicByteIsRefusedBeforeTheVersionIsLookedAt() throws {
        let valid = try Self.validBytes()
        for position in 0..<4 {
            var bytes = valid
            bytes[position] ^= 0x01
            #expect(Self.refusal(bytes) == .badMagic, "byte \(position)")
        }
        var wrongBoth = valid
        wrongBoth[0] ^= 0x01
        wrongBoth[5] = 2
        #expect(Self.refusal(wrongBoth) == .badMagic)
    }

    @Test func olderAndNewerFormatVersionsAreRefusedNeverPartiallyRead() throws {
        for version: UInt16 in [0, 2, 3, 256, 0xFFFF] {
            #expect(Self.refusal(Raw.frame(Raw.payload(entries: []), version: version))
                == .unsupportedFormatVersion(found: version))
        }
        #expect(Self.refusal(Raw.magic + Raw.big(UInt16(2))) == .unsupportedFormatVersion(found: 2))
        #expect(Self.refusal(Raw.frame(entries: [])) == nil)
    }

    @Test func bytesAfterTheFrameAreRefusedWithTheirCount() throws {
        let valid = try Self.validBytes()
        #expect(Self.refusal(valid + [0]) == .trailingBytes(count: 1))
        #expect(Self.refusal(valid + [UInt8](repeating: 7, count: 5)) == .trailingBytes(count: 5))
        var corrupted = valid
        corrupted[12] ^= 0xFF
        #expect(Self.refusal(corrupted + [0]) == .trailingBytes(count: 1))
        #expect(Self.refusal(Raw.frame(Raw.payload(entries: [Raw.Entry("Verb")]) + [0])) == .trailingBytes(count: 1))
    }

    @Test func anyFlippedPayloadOrChecksumByteIsAnIntegrityFailure() throws {
        let valid = try Self.validBytes()
        for position in 10..<valid.count {
            var bytes = valid
            bytes[position] ^= 0x01
            #expect(Self.refusal(bytes) == .integrityFailure, "byte \(position)")
        }
        #expect(Self.refusal(Array(valid.dropLast(8)) + [UInt8](repeating: 0, count: 8)) == .integrityFailure)
        #expect(Self.refusal(Raw.resealed(valid)) == nil)
    }

    @Test func aBadStampStringIsNamedByFieldAndTheOperatingSystemComesFirst() throws {
        let long = Raw.text(String(repeating: "a", count: 257))
        let badBytes = Raw.big(UInt16(1)) + [0xFF]
        let cases: [(PluginCacheField, [[UInt8]])] = [
            (.osVersion, [Raw.text(""), Raw.text("1A1")]), (.osVersion, [long, Raw.text("1A1")]),
            (.osVersion, [badBytes, Raw.text("1A1")]), (.osVersion, [Raw.text("a\u{0}b"), Raw.text("1A1")]),
            (.hostBuild, [Raw.text("27.0"), Raw.text("  ")]), (.hostBuild, [Raw.text("27.0"), long]),
            (.hostBuild, [Raw.text("27.0"), badBytes]), (.hostBuild, [Raw.text("27.0"), Raw.text("a\u{202E}b")]),
            (.osVersion, [Raw.text(""), Raw.text("")]), (.osVersion, [long, long])
        ]
        for (field, strings) in cases {
            let frame = Raw.frame(Raw.payload(Raw.stamp(os: strings[0], host: strings[1]), entries: []))
            #expect(Self.refusal(frame) == .invalidStamp(field))
        }
    }

    @Test func aGenerationOutsideOneToTheJSONSafeMaximumIsRefused() throws {
        let maximum = UInt64(Generation.maximumValue)
        for generation in [0, maximum + 1, UInt64(Int.max), UInt64.max] {
            let frame = Raw.frame(Raw.payload(Raw.stamp(generation: generation), entries: []))
            #expect(Self.refusal(frame) == .generationOutOfRange(generation))
        }
        for generation in [1, maximum] {
            #expect(Self.refusal(Raw.frame(Raw.payload(Raw.stamp(generation: generation), entries: []))) == nil)
        }
        let both = Raw.stamp(os: Raw.text(""), generation: 0)
        #expect(Self.refusal(Raw.frame(Raw.payload(both, entries: []))) == .invalidStamp(.osVersion))
    }

    @Test func everyEnumByteWithoutACaseIsAnInvalidTagNamingItsFieldAndEntryIndex() throws {
        let cases: [(PluginCatalogCacheError, (inout Raw.Entry) -> Void)] = [
            (.invalidTag(.format, value: 2, index: 1), { $0.format = 2 }),
            (.invalidTag(.presence, value: 4, index: 1), { $0.presence = [4] }),
            (.invalidTag(.failure, value: 3, index: 1), { $0.presence = [2, 3] }),
            (.invalidTag(.failureDetail, value: 4, index: 1), { $0.presence = [2, 1, 4] }),
            (.invalidTag(.direction, value: 2, index: 1), { $0.presence = [2, 1, 2, 2] + Raw.big(Int64(1)) }),
            (.invalidTag(.direction, value: 9, index: 1),
             { $0.presence = [2, 1, 3, 9] + Raw.big(Int64(1)) + Raw.big(Int64(1)) }),
            (.invalidTag(.quarantine, value: 3, index: 1), { $0.quarantine = 3 }),
            (.invalidTag(.descriptorFlag, value: 2, index: 1), { $0.descriptorFlag = 2 }),
            (.invalidTag(.midiFlags, value: 4, index: 1), { $0.descriptor = Raw.descriptor(flags: 4) })
        ]
        for (expected, edit) in cases {
            #expect(Self.refusal(Self.framed(editingSecond: edit)) == expected)
        }
    }

    @Test func aCodeWithoutFourPrintableBytesOrAnUnsupportedTypeIsAnInvalidIdentity() throws {
        let edits: [(inout Raw.Entry) -> Void] = [
            { $0.type = 0x6175_6600 }, { $0.type = Raw.code("auou") }, { $0.type = 0x1F61_7566 },
            { $0.subtype = 0x7F41_4141 }, { $0.subtype = 0x4141_4100 },
            { $0.manufacturer = 0x4600_6B6C }, { $0.manufacturer = 0x4678_6B7F }
        ]
        for edit in edits {
            #expect(Self.refusal(Self.framed(editingSecond: edit)) == .invalidIdentity(index: 1))
        }
        #expect(Self.refusal(Self.framed { $0.subtype = 0x2020_2020 }) == .entriesOutOfOrder(index: 1))
        #expect(Self.refusal(Self.framed { $0.subtype = 0x7E7E_7E7E }) == nil)
    }

    @Test func nameBytesThatAreNotWellFormedUTF8AreRefusedPerEntry() throws {
        let bad = Raw.big(UInt16(1)) + [0xFF]
        let overlong = Raw.big(UInt16(2)) + [0xC0, 0x80]
        for name in [bad, overlong] {
            #expect(Self.refusal(Self.framed { $0.descriptor = Raw.descriptor(name: name) }) == .invalidUTF8(index: 1))
            #expect(Self.refusal(Self.framed { $0.descriptor = Raw.descriptor(maker: name) }) == .invalidUTF8(index: 1))
        }
    }

    @Test func aDescriptorThatTheExistingInitializersRefuseIsRefusedWithTheirError() throws {
        let long = Raw.text(String(repeating: "n", count: 257))
        let cases: [([UInt8], PluginDescriptorError)] = [
            (Raw.descriptor(name: long), .invalidName),
            (Raw.descriptor(name: Raw.text("   ")), .invalidName),
            (Raw.descriptor(name: Raw.text("a\u{0}b")), .invalidName),
            (Raw.descriptor(name: Raw.text("a\u{202E}b")), .invalidName),
            (Raw.descriptor(maker: long), .invalidManufacturerName),
            (Raw.descriptor(maker: Raw.text("\n")), .invalidManufacturerName),
            (Raw.descriptor(name: long, maker: long), .invalidName),
            (Raw.descriptor(inputs: Raw.counted([UInt8](repeating: 1, count: 65))), .tooManyBuses(.input, count: 65)),
            (Raw.descriptor(outputs: Raw.counted([UInt8](repeating: 1, count: 65))), .tooManyBuses(.output, count: 65)),
            (Raw.descriptor(inputs: Raw.counted([1, 0])), .invalidChannelCount(.input, bus: 1, count: 0)),
            (Raw.descriptor(outputs: Raw.counted([65])), .invalidChannelCount(.output, bus: 0, count: 65)),
            (Raw.descriptor(inputs: Raw.counted([0]), outputs: Raw.counted([0])),
             .invalidChannelCount(.input, bus: 0, count: 0)),
            (Raw.descriptor(inputs: Raw.counted([0]), outputs: Raw.counted([UInt8](repeating: 1, count: 65))),
             .invalidChannelCount(.input, bus: 0, count: 0))
        ]
        for (descriptor, error) in cases {
            #expect(Self.refusal(Self.framed { $0.descriptor = descriptor }) == .invalidDescriptor(index: 1, error))
        }
    }

    @Test func aRepeatedOrOutOfOrderIdentityIsRefusedByItsPositionOnTheWire() throws {
        let verb = try Self.identity("Verb")
        #expect(Self.refusal(Raw.frame(entries: [Raw.Entry("Verb"), Raw.Entry("Verb")])) == .duplicateIdentity(verb.id))
        let descending = Raw.frame(entries: [Raw.Entry("Verb"), Raw.Entry("Echo")])
        #expect(Self.refusal(descending) == .entriesOutOfOrder(index: 1))
        #expect(Self.refusal(Raw.frame(entries: [Raw.Entry("Aaaa"), Raw.Entry("Bbbb"), Raw.Entry("Aaaa")]))
            == .entriesOutOfOrder(index: 2))
        var later = Raw.Entry("Aaaa")
        later.format = 1
        #expect(Self.refusal(Raw.frame(entries: [later, Raw.Entry("Zzzz")])) == .entriesOutOfOrder(index: 1))
        #expect(Self.refusal(Raw.frame(entries: [Raw.Entry("Zzzz"), later])) == nil)
    }

    @Test func theFirstDefectOnTheWireWinsInBothOrders() throws {
        var badTag = Raw.Entry("Cccc")
        badTag.quarantine = 3
        let duplicate = [Raw.Entry("Aaaa"), Raw.Entry("Aaaa")]
        let aaaa = try Self.identity("Aaaa")
        #expect(Self.refusal(Raw.frame(entries: duplicate + [badTag])) == .duplicateIdentity(aaaa.id))
        #expect(Self.refusal(Raw.frame(entries: [Raw.Entry("Aaaa"), badTag, Raw.Entry("Aaaa")]))
            == .invalidTag(.quarantine, value: 3, index: 1))
        var incoherent = Raw.Entry("Aaaa")
        incoherent.descriptor = nil
        #expect(Self.refusal(Raw.frame(entries: [incoherent, Raw.Entry("Bbbb"), badTag]))
            == .invalidTag(.quarantine, value: 3, index: 2))
        let pair = Raw.frame(entries: [incoherent, Raw.Entry("Bbbb")])
        #expect(Self.refusal(pair) == .installedWithoutDescriptor(aaaa.id))
    }

    @Test func anIncoherentEntryIsRefusedInCanonicalOrderWhateverTheInputOrder() throws {
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        let noDescriptor = try Self.entry(echo, .installed, described: false)
        let mismatch = try PluginCatalogEntry(
            identity: verb, presence: .missing, lastKnown: Self.descriptor(Self.identity("Gone"))
        )
        for entries in [[noDescriptor, mismatch], [mismatch, noDescriptor]] {
            #expect(throws: PluginCatalogCacheError.installedWithoutDescriptor(echo.id)) { try Self.snapshot(entries) }
        }
        #expect(throws: PluginCatalogCacheError.descriptorIdentityMismatch(verb.id)) { try Self.snapshot([mismatch]) }
        let twin = try Self.entry(verb)
        for entries in [[mismatch, twin, noDescriptor], [noDescriptor, twin, mismatch]] {
            #expect(throws: PluginCatalogCacheError.duplicateIdentity(verb.id)) { try Self.snapshot(entries) }
        }
        #expect(throws: PluginCatalogCacheError.duplicateIdentity(verb.id)) { try Self.snapshot([twin, twin]) }
    }

    /// A frame whose payload is the stamp, a count of one and the first `keeping` bytes of `entry`.
    static func resealedCut(_ entry: Raw.Entry, keeping: Int) -> [UInt8] {
        Raw.frame(Raw.payload(count: 1, entries: []) + entry.bytes.prefix(keeping))
    }

    @Test func aStampStringLongerThanTheRemainingBytesIsTruncatedInAResealedFrame() throws {
        let declared = Raw.big(UInt16(10)) + Array("abc".utf8)
        #expect(Self.refusal(Raw.frame(declared)) == .truncated)
        #expect(Self.refusal(Raw.frame(Raw.text("27.0") + declared)) == .truncated)
    }

    @Test func aGenerationCutShortIsTruncatedInAResealedFrame() throws {
        let partial = Raw.text("27.0") + Raw.text("1A1")
        for kept in 0..<8 {
            #expect(Self.refusal(Raw.frame(partial + Raw.big(UInt64(5)).prefix(kept))) == .truncated, "kept \(kept)")
        }
    }

    @Test func anIdentityCutShortIsTruncatedInAResealedFrame() throws {
        for kept in [0, 1, 4, 7, 12] {
            #expect(Self.refusal(Self.resealedCut(Raw.Entry("Verb"), keeping: kept)) == .truncated, "kept \(kept)")
        }
    }

    @Test func aNameLengthOfFFFFPastTheEndIsTruncatedInAResealedFrame() throws {
        var entry = Raw.Entry("Verb")
        entry.descriptor = Raw.descriptor(name: Raw.big(UInt16(0xFFFF)) + Array("ab".utf8))
        #expect(Self.refusal(Raw.frame(entries: [entry])) == .truncated)
    }

    @Test func aChannelCountOf255PastTheEndIsTruncatedInAResealedFrame() throws {
        var entry = Raw.Entry("Verb")
        entry.descriptor = Raw.descriptor(inputs: [255, 2, 2])
        #expect(Self.refusal(Raw.frame(entries: [entry])) == .truncated)
    }

    @Test func aUInt32AndAUInt64FieldCutShortAreTruncatedInAResealedFrame() throws {
        let described = Raw.Entry("Verb")
        let versionStart = 16 + 8 + 7
        for kept in versionStart + 1...versionStart + 3 {
            #expect(Self.refusal(Self.resealedCut(described, keeping: kept)) == .truncated, "version \(kept)")
        }
        var failed = Raw.Entry("Verb")
        failed.presence = [2, 1, 2, 0] + Raw.big(UInt64(7))
        failed.descriptor = nil
        for kept in 18...24 {
            #expect(Self.refusal(Self.resealedCut(failed, keeping: kept)) == .truncated, "count \(kept)")
        }
    }

    @Test func aDeclaredPayloadLengthThatDisagreesWithThePayloadIsRefused() throws {
        let payload = Raw.payload(entries: [])
        #expect(Self.refusal(Raw.frame(payload, length: UInt32(payload.count + 1))) == .truncated)
        #expect(Self.refusal(Raw.frame(payload, length: UInt32(payload.count - 1))) == .trailingBytes(count: 1))
        #expect(Self.refusal(Raw.frame(payload, length: UInt32(payload.count))) == nil)
    }

    @Test func aRefusedDecodeReturnsOnlyTheErrorAndLeavesItsInputUnchanged() throws {
        var corrupted = try Self.validBytes()
        corrupted[corrupted.count - 1] ^= 0x01
        let data = Data(corrupted)
        let copy = data
        #expect(throws: PluginCatalogCacheError.integrityFailure) { try PluginCatalogSnapshot.decode(from: data) }
        #expect(throws: PluginCatalogCacheError.integrityFailure) { try PluginCatalogSnapshot.decode(from: data) }
        #expect(data == copy)
        #expect(try Self.decode(Self.validBytes()).entries.count == 1)
    }

    @Test func aSnapshotWhoseStampIsNotTheCodecVersionCannotBeEncoded() throws {
        for version: UInt16 in [2, 0xFFFF] {
            let snapshot = try Self.snapshot([Self.entry(Self.identity("Verb"))], stamp: Self.stamp(format: version))
            #expect(throws: PluginCatalogCacheError.unsupportedFormatVersion(found: version)) { try snapshot.encoded() }
        }
        #expect(throws: PluginCatalogCacheError.invalidStamp(.formatVersion)) { try Self.stamp(format: 0) }
    }
}
