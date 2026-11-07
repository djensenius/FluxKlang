import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginEditorStateTests {
    @Test func aBlobOfExactlyTheLimitIsAcceptedAndOneMoreByteIsRefused() throws {
        let limit = 4_194_304
        let atLimit = try Self.snapshot(blob: [UInt8](repeating: 7, count: limit))
        #expect(atLimit.byteCount == limit)
        #expect(throws: PluginStateError.blobTooLarge(count: limit + 1, limit: limit)) {
            try Self.snapshot(blob: [UInt8](repeating: 7, count: limit + 1))
        }
        let oneByte = try Self.snapshot(blob: [9])
        #expect(oneByte.byteCount == 1)
    }

    @Test func anEmptyBlobIsRefused() {
        #expect(throws: PluginStateError.emptyBlob) { try Self.snapshot(blob: []) }
    }

    @Test func captureKeepsEveryFieldExactlyAndNeverInterpretsTheBytes() throws {
        let bytes: [UInt8] = [0x7B, 0x00, 0xFF, 0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x00, 0x7D]
        let identity = try Self.identity("Echo", format: .audioUnitV3)
        let snapshot = try PluginStateSnapshot.capture(
            blob: bytes, storageClass: .fullState, identity: identity,
            version: PluginVersion(rawValue: 0x0003_0201), vendorTag: Self.tag("vendor-x")
        )
        #expect(snapshot.blob == bytes)
        #expect(snapshot.byteCount == 11)
        #expect(snapshot.storageClass == .fullState)
        #expect(snapshot.identity == identity)
        #expect(snapshot.version.rawValue == 0x0003_0201)
        #expect(snapshot.vendorTag.text == "vendor-x")
        #expect(snapshot.digest == StateDigest.of(bytes))
    }

    @Test func aVendorTagOfExactly64BytesIsAcceptedAndAnyOtherLengthIsRefused() throws {
        let sixtyFour = String(repeating: "v", count: 64)
        #expect(try PluginVendorTag(sixtyFour).text == sixtyFour)
        #expect(try PluginVendorTag("v").text == "v")
        #expect(throws: PluginStateError.invalidVendorTag) { try PluginVendorTag(sixtyFour + "v") }
        #expect(throws: PluginStateError.invalidVendorTag) { try PluginVendorTag("") }
    }

    @Test func theVendorTagLengthIsCountedInUTF8BytesNotCharacters() throws {
        let sixtyFourBytes = String(repeating: "\u{E9}", count: 32)
        #expect(sixtyFourBytes.utf8.count == 64)
        #expect(try PluginVendorTag(sixtyFourBytes).text == sixtyFourBytes)
        let sixtySixBytes = String(repeating: "\u{E9}", count: 33)
        #expect(throws: PluginStateError.invalidVendorTag) { try PluginVendorTag(sixtySixBytes) }
    }

    @Test func blankAndControlAndFormatVendorTagsAreRefused() throws {
        for bad in [" ", " \t\n", "\u{3000}", "ab\u{0}c", "ab\nc", "ab\u{202E}c", "\u{200B}x"] {
            #expect(throws: PluginStateError.invalidVendorTag) { try PluginVendorTag(bad) }
        }
        #expect(try PluginVendorTag("a b").text == "a b")
        #expect(try PluginVendorTag(" x ").text == " x ")
    }

    @Test func vendorTagsThatDifferOnlyByACombiningMarkAreDifferentTags() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let first = try PluginVendorTag(composed)
        let second = try PluginVendorTag(decomposed)
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
        #expect(try PluginVendorTag(composed) == first)
    }

    @Test func theDigestMatchesTheFNV1aReferenceVectors() {
        #expect(StateDigest.of([]).value == 0xCBF2_9CE4_8422_2325)
        #expect(StateDigest.of(Array("a".utf8)).value == 0xAF63_DC4C_8601_EC8C)
        #expect(StateDigest.of(Array("foobar".utf8)).value == 0x8594_4171_F739_67E8)
        #expect(StateDigest.of([1, 2, 3]).value == 0xD0AA_6218_672C_F5AB)
    }

    @Test func theDigestHexIsSixteenLowercaseDigitsWithLeadingZeros() {
        #expect(StateDigest.of([0, 0]).hexString == "08328807b4eb6fed")
        #expect(StateDigest.of(Array("a".utf8)).hexString == "af63dc4c8601ec8c")
        #expect(StateDigest.of(Array("a".utf8)).description == "af63dc4c8601ec8c")
    }

    @Test func aSnapshotDigestFollowsTheBlobAndOneChangedByteChangesIt() throws {
        let base = try Self.snapshot(blob: [1, 2, 3])
        let again = try Self.snapshot(blob: [1, 2, 3])
        let changed = try Self.snapshot(blob: [1, 2, 2])
        let reordered = try Self.snapshot(blob: [3, 2, 1])
        #expect(base.digest.value == 0xD0AA_6218_672C_F5AB)
        #expect(base.digest == again.digest)
        #expect(changed.digest.value == 0xD0AA_6118_672C_F3F8)
        #expect(reordered.digest != base.digest)
    }

    @Test func snapshotsWithEqualBytesButADifferentClassAreNotEqual() throws {
        let document = try Self.snapshot(storageClass: .fullStateForDocument)
        let full = try Self.snapshot(storageClass: .fullState)
        #expect(document.blob == full.blob && document.digest == full.digest)
        #expect(document != full)
        #expect(try Self.snapshot(storageClass: .fullState) == full)
    }

    @Test func snapshotsWithEqualBytesButADifferentIdentityVersionOrVendorAreNotEqual() throws {
        let base = try Self.snapshot()
        #expect(try Self.snapshot() == base)
        #expect(try Self.snapshot().hashValue == base.hashValue)
        #expect(try Self.snapshot(identity: Self.identity("Echo")) != base)
        #expect(try Self.snapshot(identity: Self.identity("Verb", format: .audioUnitV3)) != base)
        #expect(try Self.snapshot(version: Self.baseVersion + 1) != base)
        #expect(try Self.snapshot(vendor: "acme.state.v2") != base)
        #expect(try Self.snapshot(blob: [1, 2, 4]) != base)
    }

    @Test func theStorageClassSuitsExactlyTheDocumentedPurposes() {
        #expect(StateStorageClass.fullStateForDocument.suits(.document))
        #expect(StateStorageClass.fullStateForDocument.suits(.presetRecall))
        #expect(StateStorageClass.fullState.suits(.presetRecall))
        #expect(!StateStorageClass.fullState.suits(.document))
        #expect(StateStorageClass.allCases.count == 2 && StatePurpose.allCases.count == 2)
    }
}
