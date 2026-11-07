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
