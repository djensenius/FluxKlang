//
//  PreferencePrivacyTests+Refusals.swift
//  FluxKlangTests
//
//  Admission of key-value writes (#124 PR1): every size and count boundary at N and N+1, the order of the
//  checks, the accounting of resident entries, a plan or one refusal whatever the input order, and the rule that
//  a refusal changes nothing and returns no partial plan.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PreferencePrivacyTests {
    /// One refusal case: inputs, limits and the single refusal they must give.
    struct RefusalCase {
        let name: String
        let writes: [KeyValueRequest]
        let resident: [KeyValueRequest]
        let limits: KeyValueLimits
        let expected: KeyValueRefusal
    }

    private static func abcRequest(_ name: String, _ bytes: Int, _ storageClass: StorageClass? = nil) throws
        -> KeyValueRequest {
        let classes: [String: StorageClass] = ["a": .catalog, "b": .environment, "c": .homeWiring]
        return try request("store." + name, storageClass ?? classes[name] ?? .catalog, bytes: bytes)
    }

    private static func abcLimits(entries: Int = 64, value: Int = 1_000, total: Int = 10_000) throws -> KeyValueLimits {
        try limits(entries: entries, value: value, total: total)
    }

    static func refusalCases() throws -> [RefusalCase] {
        let wide = try abcLimits()
        let unlisted = try request("store.z", bytes: 1)
        return [
            RefusalCase(name: "negative", writes: [try abcRequest("a", -1)], resident: [], limits: wide,
                        expected: .negativeSize(try key("store.a"))),
            RefusalCase(name: "min", writes: [try abcRequest("a", Int.min)], resident: [], limits: wide,
                        expected: .negativeSize(try key("store.a"))),
            RefusalCase(name: "unlisted", writes: [unlisted], resident: [], limits: wide,
                        expected: .keyNotAllowlisted(unlisted.key)),
            RefusalCase(name: "mismatch", writes: [try abcRequest("a", 1, .media)], resident: [], limits: wide,
                        expected: .classMismatch(key: try key("store.a"), expected: .catalog, got: .media)),
            RefusalCase(name: "duplicate", writes: [try abcRequest("a", 1), try abcRequest("a", 1)], resident: [],
                        limits: wide, expected: .duplicateRequest(try key("store.a"))),
            RefusalCase(name: "cap", writes: [try abcRequest("a", 101)], resident: [], limits: wide,
                        expected: .valueTooLarge(key: try key("store.a"), limit: 100)),
            RefusalCase(name: "max", writes: [try abcRequest("c", Int.max)], resident: [], limits: wide,
                        expected: .valueTooLarge(key: try key("store.c"), limit: 300)),
            RefusalCase(name: "global", writes: [try abcRequest("c", 151)], resident: [],
                        limits: try abcLimits(value: 150),
                        expected: .valueTooLarge(key: try key("store.c"), limit: 150)),
            RefusalCase(name: "resident", writes: [try abcRequest("a", 1)], resident: [unlisted], limits: wide,
                        expected: .residentInvalid(unlisted.key)),
            RefusalCase(name: "keys", writes: [try abcRequest("a", 1), try abcRequest("b", 1), try abcRequest("c", 1)],
                        resident: [], limits: try abcLimits(entries: 2), expected: .tooManyKeys(count: 3, limit: 2)),
            RefusalCase(name: "total", writes: [try abcRequest("a", 100), try abcRequest("c", 201)], resident: [],
                        limits: try abcLimits(value: 300, total: 300),
                        expected: .totalTooLarge(bytes: 301, limit: 300)),
            RefusalCase(name: "batch",
                        writes: [try abcRequest("a", 1), try abcRequest("b", 1), try abcRequest("c", 301)],
                        resident: [], limits: wide, expected: .valueTooLarge(key: try key("store.c"), limit: 300))
        ]
    }

    // MARK: Boundaries

    @Test func aWriteAtTheEntryCapIsAcceptedAndOneMoreIsTooLarge() throws {
        let list = try Self.listABC()
        let wide = try Self.abcLimits()
        let key = try Self.key("store.a")
        for bytes in [0, 1, 100] {
            let plan = try #require(Self.plan(Self.admit([try Self.abcRequest("a", bytes)], list, wide)))
            #expect(plan.totalBytes == bytes)
            #expect(plan.keyCount == 1)
        }
        for bytes in [101, 1_000, Int.max] {
            let outcome = Self.admit([try Self.abcRequest("a", bytes)], list, wide)
            #expect(outcome == .refused(.valueTooLarge(key: key, limit: 100)))
        }
    }

    @Test func aNegativeSizeIsRefusedAndZeroIsAccepted() throws {
        let list = try Self.listABC()
        let wide = try Self.abcLimits()
        let key = try Self.key("store.a")
        for bytes in [-1, -100, Int.min] {
            #expect(Self.admit([try Self.abcRequest("a", bytes)], list, wide) == .refused(.negativeSize(key)))
        }
        #expect(Self.plan(Self.admit([try Self.abcRequest("a", 0)], list, wide)) != nil)
    }

    @Test func theGlobalValueLimitCapsAnEntryAndTheSmallerCapWins() throws {
        let list = try Self.listABC()
        let tight = try Self.abcLimits(value: 150)
        #expect(Self.plan(Self.admit([try Self.abcRequest("c", 150)], list, tight)) != nil)
        #expect(Self.admit([try Self.abcRequest("c", 151)], list, tight)
            == .refused(.valueTooLarge(key: try Self.key("store.c"), limit: 150)))
        #expect(Self.admit([try Self.abcRequest("a", 101)], list, tight)
            == .refused(.valueTooLarge(key: try Self.key("store.a"), limit: 100)))
    }

    @Test func distinctKeysAtTheLimitAreAcceptedAndOneMoreIsTooManyKeys() throws {
        let list = try Self.listABC()
        let two = try Self.abcLimits(entries: 2)
        let both = [try Self.abcRequest("a", 1), try Self.abcRequest("b", 1)]
        let plan = try #require(Self.plan(Self.admit(both, list, two)))
        #expect(plan.keyCount == 2)
        let three = both + [try Self.abcRequest("c", 1)]
        #expect(Self.admit(three, list, two) == .refused(.tooManyKeys(count: 3, limit: 2)))
        let one = try Self.abcLimits(entries: 1)
        #expect(Self.plan(Self.admit([try Self.abcRequest("a", 1)], list, one)) != nil)
        #expect(Self.admit(both, list, one) == .refused(.tooManyKeys(count: 2, limit: 1)))
    }

    @Test func anEmptyBatchOfWritesIsAnEmptyPlanOverTheResident() throws {
        let list = try Self.listABC()
        let wide = try Self.abcLimits()
        let empty = try #require(Self.plan(Self.admit([], list, wide)))
        #expect(empty.writes.isEmpty)
        #expect(empty.totalBytes == 0)
        #expect(empty.keyCount == 0)
        let resident = [try Self.abcRequest("b", 150)]
        let kept = try #require(Self.plan(Self.admit([], list, wide, resident: resident)))
        #expect(kept.writes.isEmpty)
        #expect(kept.totalBytes == 150)
        #expect(kept.keyCount == 1)
    }

    @Test func totalBytesAtTheLimitAreAcceptedAndOneMoreIsTotalTooLarge() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits(value: 300, total: 300)
        let exact = [try Self.abcRequest("a", 100), try Self.abcRequest("c", 200)]
        #expect(try #require(Self.plan(Self.admit(exact, list, limits))).totalBytes == 300)
        let over = [try Self.abcRequest("a", 100), try Self.abcRequest("c", 201)]
        #expect(Self.admit(over, list, limits) == .refused(.totalTooLarge(bytes: 301, limit: 300)))
    }

    @Test func residentBytesCountTowardsTheTotalAtNAndNPlusOne() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits(value: 300, total: 400)
        let resident = [try Self.abcRequest("c", 300)]
        let exactWrites = [try Self.abcRequest("a", 100)]
        let exact = try #require(Self.plan(Self.admit(exactWrites, list, limits, resident: resident)))
        #expect(exact.totalBytes == 400)
        #expect(exact.keyCount == 2)
        #expect(Self.admit([try Self.abcRequest("b", 101)], list, limits, resident: resident)
            == .refused(.totalTooLarge(bytes: 401, limit: 400)))
    }

    @Test func aRewrittenResidentKeyCountsOnceForTheKeysAndTheBytes() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits(entries: 2, value: 300, total: 300)
        let resident = [try Self.abcRequest("b", 200), try Self.abcRequest("a", 100)]
        let sameWrites = [try Self.abcRequest("a", 100)]
        let same = try #require(Self.plan(Self.admit(sameWrites, list, limits, resident: resident)))
        #expect(same.totalBytes == 300)
        #expect(same.keyCount == 2)
        let shrunkWrites = [try Self.abcRequest("b", 100)]
        let shrunk = try #require(Self.plan(Self.admit(shrunkWrites, list, limits, resident: resident)))
        #expect(shrunk.totalBytes == 200)
        #expect(shrunk.keyCount == 2)
        let extra = [try Self.abcRequest("a", 100), try Self.abcRequest("c", 1)]
        #expect(Self.admit(extra, list, limits, resident: resident) == .refused(.tooManyKeys(count: 3, limit: 2)))
    }

    @Test func anAcceptedPlanListsTheWritesByKeyBytesWithTheResultingTotals() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits(entries: 3, value: 300, total: 600)
        let writes = [try Self.abcRequest("c", 300), try Self.abcRequest("a", 100)]
        let plan = try #require(Self.plan(Self.admit(writes, list, limits, resident: [try Self.abcRequest("b", 200)])))
        #expect(plan.writes.map(\.key.rawValue) == ["store.a", "store.c"])
        #expect(plan.writes.map(\.valueBytes) == [100, 300])
        #expect(plan.totalBytes == 600)
        #expect(plan.keyCount == 3)
    }

    @Test func aCleanBatchIsAcceptedAgainstTheShippedAllowlistAtItsLimits() throws {
        let names = KeyValueAllowlist.shipped.entries
        let writes = try names.map { try Self.request($0.key.rawValue, $0.storageClass, bytes: 131_072) }
        let plan = try #require(Self.plan(Self.admit(writes, .shipped)))
        #expect(plan.totalBytes == 917_504)
        #expect(plan.keyCount == 7)
        #expect(plan.writes.map(\.key.rawValue) == names.map(\.key.rawValue))
    }

    // MARK: Order of the checks

    @Test func aNegativeSizeIsCheckedBeforeEveryOtherRefusal() throws {
        let list = try Self.listABC()
        let unlisted = try Self.request("store.0", bytes: 5)
        let writes = [unlisted, try Self.abcRequest("a", -1), try Self.abcRequest("b", 1, .media)]
        #expect(Self.admit(writes, list, try Self.abcLimits()) == .refused(.negativeSize(try Self.key("store.a"))))
    }

    @Test func anUnlistedKeyIsCheckedBeforeAClassMismatch() throws {
        let list = try Self.listABC()
        let writes = [try Self.abcRequest("a", 1, .media), try Self.request("store.zz", bytes: 1)]
        let outcome = Self.admit(writes, list, try Self.abcLimits())
        #expect(outcome == .refused(.keyNotAllowlisted(try Self.key("store.zz"))))
    }

    @Test func unlistedKeysOfTrustPluginAndMediaClassesAreRefusedAsNotAllowlisted() throws {
        let list = try Self.listABC()
        for storageClass in [StorageClass.trust, .pluginState, .media, .credential, .draft, .cache] {
            let write = try Self.request("store.plugin-state", storageClass, bytes: 1)
            #expect(Self.admit([write], list) == .refused(.keyNotAllowlisted(write.key)), "\(storageClass)")
        }
    }

    @Test func aClassMismatchIsCheckedBeforeADuplicateRequest() throws {
        let list = try Self.listABC()
        let writes = [try Self.abcRequest("a", 1), try Self.abcRequest("a", 1), try Self.abcRequest("b", 1, .media)]
        #expect(Self.admit(writes, list, try Self.abcLimits())
            == .refused(.classMismatch(key: try Self.key("store.b"), expected: .environment, got: .media)))
    }

    @Test func anAllowlistedKeyRequestedAsAnyOtherClassIsAMismatchNotAnAdmission() throws {
        let list = try Self.listABC()
        let key = try Self.key("store.a")
        for storageClass in StorageClass.allCases where storageClass != .catalog {
            let write = try Self.request("store.a", storageClass, bytes: 1)
            #expect(Self.admit([write], list)
                == .refused(.classMismatch(key: key, expected: .catalog, got: storageClass)), "\(storageClass)")
        }
    }

    @Test func aDuplicateRequestIsCheckedBeforeAValueThatIsTooLarge() throws {
        let list = try Self.listABC()
        let writes = [try Self.abcRequest("a", 101), try Self.abcRequest("c", 1), try Self.abcRequest("c", 1)]
        #expect(Self.admit(writes, list, try Self.abcLimits()) == .refused(.duplicateRequest(try Self.key("store.c"))))
    }

    @Test func aDuplicateIsRefusedWhateverTheOrderAndTheSizes() throws {
        let list = try Self.listABC()
        let pair = [try Self.abcRequest("b", 5), try Self.abcRequest("b", 7), try Self.abcRequest("a", 1)]
        for order in Self.permutations(pair) {
            let outcome = Self.admit(order, list, try Self.abcLimits())
            #expect(outcome == .refused(.duplicateRequest(try Self.key("store.b"))))
        }
    }

    @Test func aValueTooLargeIsCheckedBeforeTheResidentEntries() throws {
        let list = try Self.listABC()
        let unlisted = try Self.request("store.z", bytes: 1)
        #expect(Self.admit([try Self.abcRequest("a", 101)], list, try Self.abcLimits(), resident: [unlisted])
            == .refused(.valueTooLarge(key: try Self.key("store.a"), limit: 100)))
    }

    @Test func aResidentEntryIsCheckedBeforeTheKeyAndByteCounts() throws {
        let list = try Self.listABC()
        let unlisted = try Self.request("store.z", bytes: 1)
        let writes = [try Self.abcRequest("a", 100), try Self.abcRequest("b", 200)]
        let limits = try Self.abcLimits(entries: 1, value: 200, total: 200)
        #expect(Self.admit(writes, list, limits, resident: [unlisted]) == .refused(.residentInvalid(unlisted.key)))
    }

    @Test func theKeyCountIsCheckedBeforeTheByteTotal() throws {
        let list = try Self.listABC()
        let writes = [try Self.abcRequest("a", 100), try Self.abcRequest("b", 200), try Self.abcRequest("c", 300)]
        let limits = try Self.abcLimits(entries: 2, value: 300, total: 300)
        #expect(Self.admit(writes, list, limits) == .refused(.tooManyKeys(count: 3, limit: 2)))
    }

    // MARK: Resident entries

    @Test func aResidentEntryIsValidatedByTheSameRules() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits()
        let write = [try Self.abcRequest("c", 1)]
        let key = try Self.key("store.a")
        let bad: [[KeyValueRequest]] = [
            [try Self.abcRequest("a", -1)],
            [try Self.abcRequest("a", 101)],
            [try Self.abcRequest("a", 1, .media)],
            [try Self.abcRequest("a", 1, .environment)],
            [try Self.abcRequest("a", 1), try Self.abcRequest("a", 1)]
        ]
        for resident in bad {
            #expect(Self.admit(write, list, limits, resident: resident) == .refused(.residentInvalid(key)))
        }
        let good = [try Self.abcRequest("a", 100), try Self.abcRequest("b", 200)]
        #expect(Self.plan(Self.admit(write, list, limits, resident: good)) != nil)
        let narrow = try Self.abcLimits(value: 50)
        let overGlobal = [try Self.abcRequest("a", 51)]
        #expect(Self.admit(write, list, narrow, resident: overGlobal) == .refused(.residentInvalid(key)))
    }

    @Test func anOverCapResidentReplacedByASmallerWriteIsAcceptedAndCountsOnce() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits(value: 200, total: 400)
        let resident = [try Self.abcRequest("a", 101), try Self.abcRequest("b", 200)]
        let writes = [try Self.abcRequest("a", 50)]
        let plan = try #require(Self.plan(Self.admit(writes, list, limits, resident: resident)))
        #expect(plan.writes == writes)
        #expect(plan.totalBytes == 250)
        #expect(plan.keyCount == 2)
        let tight = try Self.abcLimits(value: 200, total: 249)
        #expect(Self.admit(writes, list, tight, resident: resident) == .refused(.totalTooLarge(bytes: 250, limit: 249)))
    }

    @Test func anOverCapResidentNoWriteReplacesIsRefusedAndTheInputsStayUnchanged() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits()
        let resident = [try Self.abcRequest("a", 101)]
        let writes = [try Self.abcRequest("b", 5)]
        let listBefore = list
        let residentBefore = resident
        let writesBefore = writes
        let outcome = Self.admit(writes, list, limits, resident: resident)
        #expect(outcome == .refused(.residentInvalid(try Self.key("store.a"))))
        #expect(list == listBefore)
        #expect(resident == residentBefore)
        #expect(writes == writesBefore)
    }

    @Test func duplicateResidentRowsOfAReplacedKeyAreDroppedAndTheOtherResidentsStayValidated() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits()
        let writes = [try Self.abcRequest("a", 10)]
        let other = try Self.abcRequest("b", 200)
        let single = try #require(Self.plan(Self.admit(writes, list, limits, resident: [
            try Self.abcRequest("a", 50), other
        ])))
        let doubled = try #require(Self.plan(Self.admit(writes, list, limits, resident: [
            try Self.abcRequest("a", 50), other, try Self.abcRequest("a", 60)
        ])))
        #expect(doubled == single)
        #expect(doubled.writes == writes)
        #expect(doubled.totalBytes == 210)
        #expect(doubled.keyCount == 2)
        let bad = try Self.abcRequest("b", 1_001)
        let outcome = Self.admit(writes, list, limits, resident: [
            try Self.abcRequest("a", 50), try Self.abcRequest("a", 60), bad
        ])
        #expect(outcome == .refused(.residentInvalid(bad.key)))
    }

    @Test func anUnlistedResidentKeyReplacedByAWriteIsRefusedByTheWriteCheck() throws {
        let list = try Self.listABC()
        let unlisted = try Self.request("store.z", bytes: 1)
        let outcome = Self.admit([unlisted], list, try Self.abcLimits(), resident: [unlisted])
        #expect(outcome == .refused(.keyNotAllowlisted(unlisted.key)))
    }

    @Test func aResidentWithAMismatchedClassReplacedByAValidWriteIsJudgedByTheWrite() throws {
        let list = try Self.listABC()
        let limits = try Self.abcLimits()
        let resident = [try Self.abcRequest("a", 10, .media)]
        let good = [try Self.abcRequest("a", 10)]
        let plan = try #require(Self.plan(Self.admit(good, list, limits, resident: resident)))
        #expect(plan.totalBytes == 10)
        #expect(plan.keyCount == 1)
        let mismatched = [try Self.abcRequest("a", 10, .media)]
        #expect(Self.admit(mismatched, list, limits, resident: resident) == .refused(.classMismatch(
            key: try Self.key("store.a"), expected: .catalog, got: .media)))
    }

    @Test func residentSizesOfIntMaxAndMinAreRefusedWithoutOverflow() throws {
        let list = try Self.listABC()
        let key = try Self.key("store.a")
        for bytes in [Int.max, Int.min] {
            #expect(Self.admit([], list, try Self.abcLimits(), resident: [try Self.abcRequest("a", bytes)])
                == .refused(.residentInvalid(key)))
        }
    }

    // MARK: Determinism

    @Test func everyOrderOfFiveRequestsGivesTheSamePlan() throws {
        let list = try KeyValueAllowlist(entries: Self.numberedEntries(5, bytes: 50))
        let requests = try (0..<5).map { try Self.request("store.k\($0)", bytes: $0 * 10) }
        let orders = Self.permutations(requests)
        #expect(orders.count == 120)
        #expect(Set(orders.map { $0.map(\.valueBytes) }).count == 120)
        let expected = try #require(Self.plan(Self.admit(requests, list)))
        #expect(expected.writes == requests)
        #expect(expected.totalBytes == 100)
        #expect(expected.keyCount == 5)
        for order in orders { #expect(Self.admit(order, list) == .plan(expected)) }
    }

    @Test func everyOrderOfFaultyRequestsGivesTheSameRefusal() throws {
        let list = try KeyValueAllowlist(entries: Self.numberedEntries(5, bytes: 50))
        func at(_ index: Int, _ bytes: Int, _ storageClass: StorageClass = .catalog) throws -> KeyValueRequest {
            try Self.request("store.k\(index)", storageClass, bytes: bytes)
        }
        let unlisted = try Self.request("store.zz", bytes: 1)
        let sets: [(writes: [KeyValueRequest], expected: KeyValueRefusal)] = [
            ([try at(0, 5), try at(1, -1), unlisted, try at(2, 5, .media)], .negativeSize(try Self.key("store.k1"))),
            ([try at(0, 5), try at(2, 5, .media), unlisted, try at(3, 5), try at(3, 5)],
             .keyNotAllowlisted(unlisted.key)),
            ([try at(0, 5), try at(2, 5, .media), try at(3, 5), try at(3, 5), try at(4, 5)],
             .classMismatch(key: try Self.key("store.k2"), expected: .catalog, got: .media)),
            ([try at(0, 5), try at(2, 7, .trust), try at(2, 5, .media)],
             .classMismatch(key: try Self.key("store.k2"), expected: .catalog, got: .media)),
            ([try at(0, 5), try at(2, 5, .trust), try at(2, 5, .media)],
             .classMismatch(key: try Self.key("store.k2"), expected: .catalog, got: .media)),
            ([try at(0, 5), try at(3, 5), try at(3, 5), try at(4, 999), try at(1, 5)],
             .duplicateRequest(try Self.key("store.k3"))),
            ([try at(0, 5), try at(4, 999), try at(1, 5), try at(2, 5), try at(3, 5)],
             .valueTooLarge(key: try Self.key("store.k4"), limit: 50))
        ]
        for set in sets {
            for order in Self.permutations(set.writes) { #expect(Self.admit(order, list) == .refused(set.expected)) }
        }
    }

    @Test func aFixedShuffleTableGivesTheSameOutcomeAndTwoRunsAreEqual() throws {
        let list = try KeyValueAllowlist(entries: Self.numberedEntries(8, bytes: 40))
        let requests = try (0..<8).map { try Self.request("store.k\($0)", bytes: $0 == 5 ? 41 : 10) }
        let expected = Outcome.refused(.valueTooLarge(key: try Self.key("store.k5"), limit: 40))
        #expect(Self.admit(requests, list) == expected)
        for seed in UInt64(1)...16 { #expect(Self.admit(Self.shuffled(requests, seed: seed), list) == expected) }
        let good = requests.map { KeyValueRequest(key: $0.key, storageClass: $0.storageClass, valueBytes: 10) }
        let plan = try #require(Self.plan(Self.admit(good, list)))
        #expect(plan.writes == good)
        for seed in UInt64(1)...16 { #expect(Self.admit(Self.shuffled(good, seed: seed), list) == .plan(plan)) }
        #expect(Self.admit(good, list) == Self.admit(good, list))
    }

    // MARK: Atomicity

    @Test func everyRefusalLeavesTheInputsUnchangedAndProducesNoPlan() throws {
        let list = try Self.listABC()
        let before = list
        let cases = try Self.refusalCases()
        #expect(cases.count == 12)
        for refusalCase in cases {
            let writes = refusalCase.writes
            let resident = refusalCase.resident
            let limits = refusalCase.limits
            let outcome = Self.admit(writes, list, limits, resident: resident)
            #expect(outcome == .refused(refusalCase.expected), "\(refusalCase.name)")
            #expect(Self.plan(outcome) == nil, "\(refusalCase.name)")
            #expect(writes == refusalCase.writes && resident == refusalCase.resident, "\(refusalCase.name)")
            #expect(limits == refusalCase.limits && list == before, "\(refusalCase.name)")
        }
    }

    @Test func aBatchWithOneBadRequestReturnsOnlyTheRefusal() throws {
        let list = try Self.listABC()
        let writes = [try Self.abcRequest("a", 1), try Self.abcRequest("b", 1), try Self.abcRequest("c", 301)]
        let outcome = Self.admit(writes, list, try Self.abcLimits())
        #expect(outcome == .refused(.valueTooLarge(key: try Self.key("store.c"), limit: 300)))
        #expect(Self.plan(outcome) == nil)
        let good = Array(writes.prefix(2))
        #expect(try #require(Self.plan(Self.admit(good, list, try Self.abcLimits()))).keyCount == 2)
    }
}
