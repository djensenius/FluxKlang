//
//  PreferencePrivacyTests+Allowlist.swift
//  FluxKlangTests
//
//  Key validity, the file-name mapping, the byte order, the shipped allowlist, and what a built allowlist
//  refuses (#124 PR1). Keys are `store.` plus lowercase ASCII, at most 64 UTF-8 bytes; the allowlist is finite,
//  exact and holds only classes that key-value storage permits.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PreferencePrivacyTests {
    private static func fault(_ raw: String) -> KeyValueKeyFault? {
        guard case let .invalidKey(fault)? = refusal({ try KeyValueKey(raw) }) else { return nil }
        return fault
    }

    /// The shipped file names in allowlist (key byte) order, with the class each is mirrored as.
    private struct ShippedFile {
        let file: String
        let key: String
        let storageClass: StorageClass
    }

    private static let shippedFiles = [
        ShippedFile(file: "environments.json", key: "store.environments_json", storageClass: .environment),
        ShippedFile(file: "equipment.json", key: "store.equipment_json", storageClass: .catalog),
        ShippedFile(file: "fader-layout.json", key: "store.fader-layout_json", storageClass: .catalog),
        ShippedFile(file: "presets.json", key: "store.presets_json", storageClass: .catalog),
        ShippedFile(file: "routing_snapshots.json", key: "store.routing_snapshots_json", storageClass: .catalog),
        ShippedFile(file: "spatial.json", key: "store.spatial_json", storageClass: .catalog),
        ShippedFile(file: "studio-connections.json", key: "store.studio-connections_json", storageClass: .homeWiring)
    ]

    // MARK: Key validity

    @Test func aKeyOfExactly64BytesIsAcceptedAnd65IsRefused() throws {
        let sixtyFour = "store." + String(repeating: "a", count: 58)
        #expect(sixtyFour.utf8.count == 64)
        #expect(try KeyValueKey(sixtyFour).rawValue == sixtyFour)
        #expect(Self.fault(sixtyFour + "a") == .tooLong(bytes: 65))
        #expect(Self.fault(sixtyFour + String(repeating: "a", count: 100)) == .tooLong(bytes: 164))
    }

    @Test func theKeyLengthIsCountedInUTF8BytesNotCharacters() {
        let thirtyCharacters = "store." + String(repeating: "é", count: 30)
        #expect(thirtyCharacters.count == 36)
        #expect(thirtyCharacters.utf8.count == 66)
        #expect(Self.fault(thirtyCharacters) == .tooLong(bytes: 66))
    }

    @Test func anEmptyKeyAndAKeyWithoutTheNamespaceAreRefused() {
        #expect(Self.fault("") == .empty)
        for raw in ["environments_json", "store", "store_a", "Store.a", "stor.e", "fluxklang.appIcon", ".store.a"] {
            #expect(Self.fault(raw) == .missingNamespace, "\(raw)")
        }
    }

    @Test func aKeyWithNothingAfterThePrefixIsRefused() {
        #expect(Self.fault("store.") == .emptyName)
    }

    @Test func theNameCharactersAreLowercaseAsciiDigitsUnderscoreAndDashOnly() throws {
        #expect(try KeyValueKey("store.abcxyz-0189_9").rawValue == "store.abcxyz-0189_9")
        #expect(try KeyValueKey("store.a").rawValue == "store.a")
        #expect(try KeyValueKey("store.z").rawValue == "store.z")
        #expect(try KeyValueKey("store.0").rawValue == "store.0")
        #expect(try KeyValueKey("store.9").rawValue == "store.9")
        let refused = ["A", "Z", " ", "é", ".", "/", ":", "@", "[", "`", "{", "~", "+", "\u{7F}", "\n"]
        for character in refused {
            #expect(Self.fault("store.a" + character) == .invalidCharacter(offset: 7), "\(character.unicodeScalars)")
        }
        #expect(Self.fault("store." + "A") == .invalidCharacter(offset: 6))
    }

    @Test func aSecondDotIsRefusedBecauseThePrefixDotIsTheOnlyDot() {
        #expect(Self.fault("store.a.b") == .invalidCharacter(offset: 7))
        #expect(Self.fault("store.environments.json") == .invalidCharacter(offset: 18))
        #expect(Self.fault("store..") == .invalidCharacter(offset: 6))
    }

    @Test func theFaultOffsetIsAUTF8ByteOffset() {
        #expect(Self.fault("store.aé") == .invalidCharacter(offset: 7))
        #expect(Self.fault("store.éa") == .invalidCharacter(offset: 6))
        #expect(Self.fault("store.ab-é") == .invalidCharacter(offset: 9))
    }

    @Test func storeFileMapsEveryDotToAnUnderscoreLikeTheFileMirror() throws {
        #expect(try KeyValueKey.storeFile(named: "studio-connections.json").rawValue == "store.studio-connections_json")
        #expect(try KeyValueKey.storeFile(named: "routing_snapshots.json").rawValue == "store.routing_snapshots_json")
        #expect(try KeyValueKey.storeFile(named: "a.b.c").rawValue == "store.a_b_c")
        #expect(try KeyValueKey.storeFile(named: "plain").rawValue == "store.plain")
    }

    @Test func storeFileRefusesNamesThatMapToAnInvalidKey() {
        #expect(Self.refusal { try KeyValueKey.storeFile(named: "") } == .invalidKey(.emptyName))
        let fault = Self.refusal { try KeyValueKey.storeFile(named: "Env.json") }
        #expect(fault == .invalidKey(.invalidCharacter(offset: 6)))
        let fiftyEight = String(repeating: "a", count: 58)
        #expect(Self.refusal { try KeyValueKey.storeFile(named: fiftyEight) } == nil)
        #expect(Self.refusal { try KeyValueKey.storeFile(named: fiftyEight + "a") } == .invalidKey(.tooLong(bytes: 65)))
    }

    @Test func keysSortByUTF8BytesNotByCharacters() throws {
        let raws = ["store.b", "store.a_b", "store.a-b", "store.a", "store.9", "store.a0"]
        let sorted = try raws.map { try KeyValueKey($0) }.sorted().map(\.rawValue)
        #expect(sorted == ["store.9", "store.a", "store.a-b", "store.a0", "store.a_b", "store.b"])
        #expect(try KeyValueKey("store.a-b") < KeyValueKey("store.a_b"))
        #expect(!(try KeyValueKey("store.a_b") < KeyValueKey("store.a-b")))
        #expect(!(try KeyValueKey("store.a") < KeyValueKey("store.a")))
    }

    // MARK: The shipped allowlist

    @Test func theShippedAllowlistHoldsExactlyTheSevenMirroredFilesSortedByBytes() {
        let entries = KeyValueAllowlist.shipped.entries
        #expect(entries.map(\.key.rawValue) == Self.shippedFiles.map(\.key))
        #expect(entries.map(\.storageClass) == Self.shippedFiles.map(\.storageClass))
        #expect(entries.map(\.maxValueBytes) == Array(repeating: 131_072, count: 7))
        #expect(entries.reduce(0) { $0 + $1.maxValueBytes } == 917_504)
    }

    @Test func theShippedAllowlistEqualsTheOneTheThrowingInitBuilds() throws {
        let rebuilt = try KeyValueAllowlist(entries: KeyValueAllowlist.shipped.entries.reversed())
        #expect(rebuilt == KeyValueAllowlist.shipped)
        #expect(!KeyValueAllowlist.shipped.entries.isEmpty)
    }

    @Test func everyShippedKeyIsTheStoreFileKeyOfItsFileName() throws {
        for row in Self.shippedFiles {
            #expect(try KeyValueKey.storeFile(named: row.file) == (try KeyValueKey(row.key)))
            #expect(KeyValueAllowlist.shipped.contains(rawKey: row.key))
        }
    }

    @Test func unshippedFilesAndEveryUserDefaultsKeyAreRefusedByTheShippedAllowlist() throws {
        let unshipped = [
            "store.launch-control-xl_json", "store.effects_json", "store.chain_json",
            "store.assistant-pending-studio-draft_json"
        ]
        for raw in unshipped {
            let key = try KeyValueKey(raw)
            #expect(!KeyValueAllowlist.shipped.contains(rawKey: raw))
            let outcome = Self.admit([try Self.request(raw, .catalog, bytes: 1)], .shipped)
            #expect(outcome == .refused(.keyNotAllowlisted(key)))
        }
        let defaultsKeys = [
            "assistant.provider", "assistant.copilot.model", "assistant.spokenReplies", "fluxklang.appIcon",
            "fluxklang.reconnectAtLaunch", "fluxklang.lastHost",
            "org.davidjensenius.FluxKlang.spotlightProtectionClass"
        ]
        for raw in defaultsKeys {
            #expect(!KeyValueAllowlist.shipped.contains(rawKey: raw))
            #expect(Self.fault(raw) == .missingNamespace, "\(raw)")
        }
    }

    @Test func theAllowlistHasNoWildcardOrPrefixEntries() throws {
        for raw in ["store.", "store.env", "store.environments_jso", "store.environments_jsonx", "store.*", "store.e"] {
            #expect(!KeyValueAllowlist.shipped.contains(rawKey: raw), "\(raw)")
        }
        let prefix = try Self.request("store.environments_jso", .environment, bytes: 1)
        #expect(Self.admit([prefix], .shipped) == .refused(.keyNotAllowlisted(prefix.key)))
        #expect(KeyValueAllowlist.shipped.entry(for: try KeyValueKey("store.environments_jsonx")) == nil)
    }

    @Test func aShippedKeyIsAdmittedWithItsOwnClassAndRefusedAsEveryOtherClass() throws {
        let key = try KeyValueKey("store.studio-connections_json")
        let own = try Self.request(key.rawValue, .homeWiring, bytes: 131_072)
        let plan = try #require(Self.plan(Self.admit([own], .shipped)))
        #expect(plan.writes == [own])
        #expect(plan.totalBytes == 131_072)
        #expect(plan.keyCount == 1)
        let oneMore = try Self.request(key.rawValue, .homeWiring, bytes: 131_073)
        #expect(Self.admit([oneMore], .shipped) == .refused(.valueTooLarge(key: key, limit: 131_072)))
        for storageClass in StorageClass.allCases where storageClass != .homeWiring {
            let wrong = try Self.request(key.rawValue, storageClass, bytes: 1)
            #expect(Self.admit([wrong], .shipped)
                == .refused(.classMismatch(key: key, expected: .homeWiring, got: storageClass)))
        }
    }

    // MARK: Building an allowlist

    @Test func anAllowlistNeedsAtLeastOneEntry() throws {
        #expect(Self.refusal { try KeyValueAllowlist(entries: []) } == .emptyAllowlist)
        #expect(try KeyValueAllowlist(entries: [Self.entry("store.a")]).entries.count == 1)
    }

    @Test func anAllowlistAcceptsMaximumEntriesAndRefusesOneMore() throws {
        #expect(try KeyValueAllowlist(entries: Self.numberedEntries(64)).entries.count == 64)
        #expect(Self.refusal { try KeyValueAllowlist(entries: Self.numberedEntries(65)) }
            == .tooManyEntries(count: 65, limit: 64))
        let three = try Self.limits(entries: 3)
        #expect(try KeyValueAllowlist(entries: Self.numberedEntries(3), limits: three).entries.count == 3)
        #expect(Self.refusal { try KeyValueAllowlist(entries: Self.numberedEntries(4), limits: three) }
            == .tooManyEntries(count: 4, limit: 3))
        let hard = try Self.limits(entries: 1_024, value: 1, total: 1_048_576)
        #expect(try KeyValueAllowlist(entries: Self.numberedEntries(1_024), limits: hard).entries.count == 1_024)
        #expect(Self.refusal { try KeyValueAllowlist(entries: Self.numberedEntries(1_025), limits: hard) }
            == .tooManyEntries(count: 1_025, limit: 1_024))
    }

    @Test func tooManyEntriesIsReportedBeforeAnyEntryFault() throws {
        let bad = try (0..<65).map { try Self.entry("store.k\($0)", .media, bytes: 0) }
        #expect(Self.refusal { try KeyValueAllowlist(entries: bad) } == .tooManyEntries(count: 65, limit: 64))
    }

    @Test func aDuplicateKeyIsRefusedWhateverTheOrderOrTheOtherFields() throws {
        let first = try Self.entry("store.a", .catalog, bytes: 10)
        let second = try Self.entry("store.a", .environment, bytes: 20)
        let other = try Self.entry("store.b")
        for order in Self.permutations([first, second, other]) {
            #expect(Self.refusal { try KeyValueAllowlist(entries: order) } == .duplicateEntry(first.key))
        }
        #expect(Self.refusal { try KeyValueAllowlist(entries: [first, first]) } == .duplicateEntry(first.key))
    }

    @Test func equalKeysAreCheckedSmallestSizeThenClassNameFirstWhateverTheInputOrder() throws {
        let key = try KeyValueKey("store.a")
        let sizes = [
            try Self.entry("store.a", bytes: 200_000),
            try Self.entry("store.a", bytes: -5),
            try Self.entry("store.a", bytes: 0)
        ]
        for order in Self.permutations(sizes) {
            #expect(Self.refusal { try KeyValueAllowlist(entries: order) } == .invalidEntrySize(key: key, bytes: -5))
        }
        let classes = [try Self.entry("store.a", .trust, bytes: 5), try Self.entry("store.a", .media, bytes: 5)]
        for order in Self.permutations(classes) {
            #expect(Self.refusal { try KeyValueAllowlist(entries: order) } == .classNotKeyValueEligible(.media))
        }
    }

    @Test func anEntrySizeFromOneToTheValueLimitIsAcceptedAndOthersAreRefused() throws {
        let capped = try Self.limits(value: 1_000, total: 10_000)
        for bytes in [1, 1_000] {
            let single = [try Self.entry("store.a", bytes: bytes)]
            #expect(try KeyValueAllowlist(entries: single, limits: capped).entries.count == 1)
        }
        let key = try KeyValueKey("store.a")
        for bytes in [0, -1, 1_001, Int.max, Int.min] {
            let single = [try Self.entry("store.a", bytes: bytes)]
            #expect(Self.refusal { try KeyValueAllowlist(entries: single, limits: capped) }
                == .invalidEntrySize(key: key, bytes: bytes), "\(bytes)")
        }
    }

    @Test func theEntryTotalMayEqualTheLimitButNotExceedIt() throws {
        let tight = try Self.limits(value: 600, total: 1_000)
        let exact = [try Self.entry("store.a", bytes: 500), try Self.entry("store.b", bytes: 500)]
        #expect(try KeyValueAllowlist(entries: exact, limits: tight).entries.count == 2)
        let over = [try Self.entry("store.a", bytes: 500), try Self.entry("store.b", bytes: 501)]
        #expect(Self.refusal { try KeyValueAllowlist(entries: over, limits: tight) }
            == .allowlistExceedsTotal(bytes: 1_001, limit: 1_000))
    }

    @Test func eightFullSizedEntriesFillTheStandardTotalAndANinthIsRefused() throws {
        let eight = try Self.numberedEntries(8, bytes: 131_072)
        #expect(try KeyValueAllowlist(entries: eight).entries.count == 8)
        #expect(Self.refusal { try KeyValueAllowlist(entries: Self.numberedEntries(9, bytes: 131_072)) }
            == .allowlistExceedsTotal(bytes: 1_179_648, limit: 1_048_576))
    }

    @Test func overflowSizedEntriesAreRefusedWithoutTrapping() throws {
        let key = try KeyValueKey("store.a")
        let both = [try Self.entry("store.a", bytes: Int.max), try Self.entry("store.b", bytes: Int.max)]
        #expect(Self.refusal { try KeyValueAllowlist(entries: both) } == .invalidEntrySize(key: key, bytes: Int.max))
    }

    @Test func everyClassOutsideKeyValueStorageIsRefusedAsAnEntry() throws {
        for storageClass in Self.ineligibleClasses {
            #expect(Self.refusal { try KeyValueAllowlist(entries: [Self.entry("store.a", storageClass)]) }
                == .classNotKeyValueEligible(storageClass), "\(storageClass)")
        }
        for storageClass in Self.eligibleClasses {
            #expect(try KeyValueAllowlist(entries: [Self.entry("store.a", storageClass)]).entries.count == 1)
        }
    }

    @Test func anEntryChecksItsKeyThenItsClassThenItsSize() throws {
        let narrow = try Self.limits(keyBytes: 7)
        let longKey = try Self.entry("store.abc", .media, bytes: 0)
        let longFault = Self.refusal { try KeyValueAllowlist(entries: [longKey], limits: narrow) }
        #expect(longFault == .invalidKey(.tooLong(bytes: 9)))
        let badClass = try Self.entry("store.a", .media, bytes: 0)
        let classFault = Self.refusal { try KeyValueAllowlist(entries: [badClass], limits: narrow) }
        #expect(classFault == .classNotKeyValueEligible(.media))
        #expect(try KeyValueAllowlist(entries: [Self.entry("store.a")], limits: narrow).entries.count == 1)
    }

    @Test func theEntryKeyMayBeExactlyTheConfiguredKeyLimit() throws {
        let narrow = try Self.limits(keyBytes: 20)
        let twenty = "store." + String(repeating: "a", count: 14)
        #expect(try KeyValueAllowlist(entries: [Self.entry(twenty)], limits: narrow).entries.count == 1)
        #expect(Self.refusal { try KeyValueAllowlist(entries: [Self.entry(twenty + "a")], limits: narrow) }
            == .invalidKey(.tooLong(bytes: 21)))
    }

    @Test func entriesAreSortedAndTheRefusalDoesNotDependOnTheInputOrder() throws {
        let entries = try ["store.d", "store.a_b", "store.a-b", "store.c"].map { try Self.entry($0) }
        let expected = ["store.a-b", "store.a_b", "store.c", "store.d"]
        for order in Self.permutations(entries) {
            #expect(try KeyValueAllowlist(entries: order).entries.map(\.key.rawValue) == expected)
        }
        let faulty = [try Self.entry("store.b", .media), try Self.entry("store.a", bytes: 0)]
        let key = try KeyValueKey("store.a")
        for order in Self.permutations(faulty) {
            #expect(Self.refusal { try KeyValueAllowlist(entries: order) } == .invalidEntrySize(key: key, bytes: 0))
        }
    }
}
