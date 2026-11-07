//
//  PreferencePrivacyTests+Limits.swift
//  FluxKlangTests
//
//  The validated key-value limits (#124 PR1): each number at its lower bound, its hard ceiling and one beyond,
//  the rule that one value must fit in the total, and the order in which a bad field is named. The numbers are
//  conservative defaults that are unverified against Apple's documentation.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PreferencePrivacyTests {
    private static func build(
        _ keyBytes: Int, _ entries: Int, _ value: Int, _ total: Int
    ) -> KeyValueRefusal? {
        refusal {
            try KeyValueLimits(
                maximumKeyBytes: keyBytes, maximumEntries: entries, maximumValueBytes: value,
                maximumTotalBytes: total)
        }
    }

    /// `store.a` (7 bytes) and `store.abc` (9 bytes), both catalog with a 100-byte cap, built with `.standard`.
    private static func keyLimitList() throws -> KeyValueAllowlist {
        try KeyValueAllowlist(
            entries: [try entry("store.a", bytes: 100), try entry("store.abc", bytes: 100)], limits: .standard)
    }

    private static let keyLimitNine = "store.abc"

    @Test func evaluationRefusesAKeyLongerThanTheEvaluationLimitEvenWhenTheAllowlistAdmitsIt() throws {
        let list = try Self.keyLimitList()
        let seven = try Self.limits(keyBytes: 7)
        let write = try Self.request(Self.keyLimitNine, bytes: 10)
        let writes = [write]
        let resident = [try Self.request("store.a", bytes: 5)]
        #expect(Self.admit(writes, list, seven, resident: resident) == .refused(.invalidKey(.tooLong(bytes: 9))))
        #expect(writes == [write])
        #expect(resident == [try Self.request("store.a", bytes: 5)])
        #expect(Self.plan(Self.admit(writes, list, .standard, resident: resident)) != nil)
    }

    @Test func aWriteKeyAtTheEvaluationKeyLimitIsAdmittedAndOneByteOverIsRefused() throws {
        let list = try Self.keyLimitList()
        let keyBytes = Self.keyLimitNine.utf8.count
        let write = try Self.request(Self.keyLimitNine, bytes: 10)
        let atLimit = try #require(Self.plan(Self.admit([write], list, try Self.limits(keyBytes: keyBytes))))
        #expect(atLimit.keyCount == 1)
        #expect(atLimit.totalBytes == 10)
        let over = Self.admit([write], list, try Self.limits(keyBytes: keyBytes - 1))
        #expect(over == .refused(.invalidKey(.tooLong(bytes: keyBytes))))
    }

    @Test func aRetainedResidentKeyAtTheEvaluationKeyLimitIsKeptAndOneByteOverIsResidentInvalid() throws {
        let list = try Self.keyLimitList()
        let keyBytes = Self.keyLimitNine.utf8.count
        let resident = [try Self.request(Self.keyLimitNine, bytes: 20)]
        let other = [try Self.request("store.a", bytes: 5)]
        let exact = try Self.limits(keyBytes: keyBytes)
        let kept = try #require(Self.plan(Self.admit(other, list, exact, resident: resident)))
        #expect(kept.keyCount == 2)
        #expect(kept.totalBytes == 25)
        let narrow = try Self.limits(keyBytes: keyBytes - 1)
        #expect(Self.admit(other, list, narrow, resident: resident) == .refused(.residentInvalid(resident[0].key)))
        #expect(resident == [try Self.request(Self.keyLimitNine, bytes: 20)])
    }

    @Test func aTooLongResidentKeyThatAWriteReplacesIsJudgedOnlyThroughTheWrite() throws {
        let list = try Self.keyLimitList()
        let keyBytes = Self.keyLimitNine.utf8.count
        let resident = [try Self.request(Self.keyLimitNine, bytes: 20)]
        let write = try Self.request(Self.keyLimitNine, bytes: 10)
        let narrow = try Self.limits(keyBytes: keyBytes - 1)
        let refused = Self.admit([write], list, narrow, resident: resident)
        #expect(refused == .refused(.invalidKey(.tooLong(bytes: keyBytes))))
        let wide = try Self.limits(keyBytes: keyBytes)
        let plan = try #require(Self.plan(Self.admit([write], list, wide, resident: resident)))
        #expect(plan.keyCount == 1)
        #expect(plan.totalBytes == 10)
    }

    @Test func theKeyLengthRefusalSitsInStageBAfterNotAllowlistedAndBeforeTheClassAndSizeChecks() throws {
        let list = try Self.keyLimitList()
        let seven = try Self.limits(keyBytes: 7)
        let negative = try Self.request("store.a", bytes: -1)
        let longKey = try Self.request(Self.keyLimitNine, bytes: 10)
        let unlisted = try Self.request("store.zzzzzzz", bytes: 1)
        let wrongClass = try Self.request(Self.keyLimitNine, .environment, bytes: 10)
        let oversize = try Self.request(Self.keyLimitNine, bytes: 101)
        let earlyUnlisted = try Self.request("store.abb", bytes: 1)
        let cases: [([KeyValueRequest], KeyValueRefusal)] = [
            ([longKey, negative], .negativeSize(negative.key)),
            ([longKey, unlisted], .invalidKey(.tooLong(bytes: 9))),
            ([unlisted], .keyNotAllowlisted(unlisted.key)),
            ([wrongClass], .invalidKey(.tooLong(bytes: 9))),
            ([oversize], .invalidKey(.tooLong(bytes: 9))),
            ([longKey, earlyUnlisted], .keyNotAllowlisted(earlyUnlisted.key))
        ]
        for (writes, expected) in cases {
            for order in Self.permutations(writes) {
                #expect(Self.admit(order, list, seven) == .refused(expected), "\(expected)")
            }
        }
    }

    @Test func aWriteKeyLengthRefusalWinsOverAnInvalidResidentAndAShortWriteLeavesItToTheResident() throws {
        let list = try Self.keyLimitList()
        let seven = try Self.limits(keyBytes: 7)
        let longWrite = try Self.request(Self.keyLimitNine, bytes: 10)
        let shortWrite = try Self.request("store.a", bytes: 10)
        let longResident = try Self.request(Self.keyLimitNine, bytes: 20)
        #expect(Self.admit([longWrite], list, seven, resident: [longResident])
            == .refused(.invalidKey(.tooLong(bytes: 9))))
        let otherResident = try Self.request("store.a", .environment, bytes: 1)
        #expect(Self.admit([longWrite], list, seven, resident: [otherResident])
            == .refused(.invalidKey(.tooLong(bytes: 9))))
        #expect(Self.admit([shortWrite], list, seven, resident: [longResident])
            == .refused(.residentInvalid(longResident.key)))
    }

    @Test func theStandardEvaluationLimitsStillAdmitEveryShippedKeyAtItsOwnLength() throws {
        let shipped = KeyValueAllowlist.shipped
        try #require(!shipped.entries.isEmpty)
        for entry in shipped.entries {
            #expect(entry.key.rawValue.utf8.count <= KeyValueLimits.standard.maximumKeyBytes)
            let write = KeyValueRequest(key: entry.key, storageClass: entry.storageClass, valueBytes: 1)
            let plan = try #require(Self.plan(Self.admit([write], shipped)))
            #expect(plan.keyCount == 1)
        }
    }

    @Test func theStandardLimitsAreTheDocumentedValues() throws {
        let standard = KeyValueLimits.standard
        #expect(standard.maximumKeyBytes == 64)
        #expect(standard.maximumEntries == 64)
        #expect(standard.maximumValueBytes == 131_072)
        #expect(standard.maximumTotalBytes == 1_048_576)
        #expect(standard == (try Self.limits(keyBytes: 64, entries: 64, value: 131_072, total: 1_048_576)))
    }

    @Test func theKeyByteLimitAcceptsOneAndSixtyFourAndRefusesZeroNegativeAndSixtyFive() {
        #expect(Self.build(1, 64, 1_000, 10_000) == nil)
        #expect(Self.build(64, 64, 1_000, 10_000) == nil)
        for bad in [0, -1, 65, Int.max, Int.min] {
            #expect(Self.build(bad, 64, 1_000, 10_000) == .invalidLimits(.maximumKeyBytes), "\(bad)")
        }
    }

    @Test func theEntryLimitAcceptsOneAnd1024AndRefusesZeroNegativeAnd1025() {
        #expect(Self.build(64, 1, 1_000, 10_000) == nil)
        #expect(Self.build(64, 1_024, 1_000, 10_000) == nil)
        for bad in [0, -1, 1_025, Int.max, Int.min] {
            #expect(Self.build(64, bad, 1_000, 10_000) == .invalidLimits(.maximumEntries), "\(bad)")
        }
    }

    @Test func theValueLimitAcceptsOneAndTheCeilingAndRefusesZeroNegativeAndOneMore() {
        #expect(Self.build(64, 64, 1, 1_048_576) == nil)
        #expect(Self.build(64, 64, 1_048_576, 1_048_576) == nil)
        for bad in [0, -1, 1_048_577, Int.max, Int.min] {
            #expect(Self.build(64, 64, bad, 1_048_576) == .invalidLimits(.maximumValueBytes), "\(bad)")
        }
    }

    @Test func theTotalLimitAcceptsOneAndTheCeilingAndRefusesZeroNegativeAndOneMore() {
        #expect(Self.build(64, 64, 1, 1) == nil)
        #expect(Self.build(64, 64, 1, 1_048_576) == nil)
        for bad in [0, -1, 1_048_577, Int.max, Int.min] {
            #expect(Self.build(64, 64, 1, bad) == .invalidLimits(.maximumTotalBytes), "\(bad)")
        }
    }

    @Test func oneValueMustFitInTheTotalAtNAndNPlusOne() {
        #expect(Self.build(64, 64, 1_000, 1_000) == nil)
        #expect(Self.build(64, 64, 1_001, 1_000) == .invalidLimits(.valueExceedsTotal))
        #expect(Self.build(64, 64, 1_048_576, 1_048_576) == nil)
        #expect(Self.build(64, 64, 2, 1) == .invalidLimits(.valueExceedsTotal))
    }

    @Test func aBadFieldIsNamedInTheOrderKeyEntriesValueTotalThenFit() {
        #expect(Self.build(0, 0, 0, 0) == .invalidLimits(.maximumKeyBytes))
        #expect(Self.build(64, 0, 0, 0) == .invalidLimits(.maximumEntries))
        #expect(Self.build(64, 64, 0, 0) == .invalidLimits(.maximumValueBytes))
        #expect(Self.build(64, 64, 1, 0) == .invalidLimits(.maximumTotalBytes))
        #expect(Self.build(64, 64, 5, 4) == .invalidLimits(.valueExceedsTotal))
    }
}
