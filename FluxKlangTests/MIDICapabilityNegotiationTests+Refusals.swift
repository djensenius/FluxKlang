import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The refusals of the capability negotiation (#83, slice CAP1), each alone, and every adjacent order pair that can
/// hold both defects. Pairs (3, 4) and (4, 5) cannot: check 4 needs no endpoint, while checks 3 and 5 need one.
extension MIDICapabilityNegotiationTests {
    typealias Refusal = MIDICapabilityRefusal

    static func ump(declared: Int) -> UMPStreamEndpointInfo {
        endpoint(midi1: true, midi2: true, declared: declared)
    }

    static func facts(declared: Int, _ blocks: [Block], profiles: [MIDICapabilityProfileID] = []) throws -> Facts {
        facts(ump(declared: declared), blocks, try answer(profiles: profiles))
    }

    static func distinctProfiles(_ count: Int) throws -> [MIDICapabilityProfileID] {
        var profiles: [MIDICapabilityProfileID] = []
        for number in 0..<count {
            profiles.append(try profile(UInt8(number)))
        }
        return profiles
    }

    // MARK: - Each refusal alone

    @Test func thirtyThreeBlocksAreRefusedWithTheirCountAndThirtyTwoAreNot() throws {
        let thirtyThree = (0..<33).map { Self.block($0, first: 0) }
        let tooMany = Self.refusal(try Self.facts(declared: 33, thirtyThree))
        let expected: Refusal = .tooManyFunctionBlocks(count: 33)
        #expect(tooMany == expected)
        let thirtyTwo = (0..<32).map { Self.block($0, first: 0) }
        let overlap = Self.refusal(try Self.facts(declared: 32, thirtyTwo))
        let expectedOverlap: Refusal = .overlappingFunctionBlockGroups(first: 0, second: 1)
        #expect(overlap == expectedOverlap)
    }

    @Test func sixtyFiveProfilesAreRefusedWithTheirCount() throws {
        let sixtyFive = try Self.distinctProfiles(65)
        let result = Self.refusal(try Self.full(profiles: sixtyFive))
        let expected: Refusal = .tooManyProfiles(count: 65)
        #expect(result == expected)
    }

    @Test func anEndpointCountOutsideZeroToThirtyTwoIsRefusedAsInvalidWithTheValueGiven() throws {
        let high = Self.refusal(try Self.facts(declared: 33, []))
        let low = Self.refusal(try Self.facts(declared: -1, []))
        let expectedHigh: Refusal = .endpointInvalid(.invalidField(.functionBlockCount, value: 33))
        let expectedLow: Refusal = .endpointInvalid(.invalidField(.functionBlockCount, value: -1))
        #expect(high == expectedHigh)
        #expect(low == expectedLow)
        let atMaximum = Self.refusal(try Self.facts(declared: 32, []))
        let expectedMismatch: Refusal = .functionBlockCountMismatch(declared: 32, supplied: 0)
        #expect(atMaximum == expectedMismatch)
    }

    @Test func blocksWithoutAnEndpointAreRefusedWithTheirCountAndAnEmptyListIsAccepted() throws {
        let blocks = [Self.tile(0), Self.tile(1)]
        let result = Self.refusal(Self.facts(nil, blocks, try Self.answer()))
        let expected: Refusal = .functionBlocksWithoutEndpoint(count: 2)
        #expect(result == expected)
        let empty = Self.refusal(Self.facts(nil, [], try Self.answer()))
        #expect(empty == nil)
        let single = Self.refusal(Self.facts(nil, [Self.tile(0)], try Self.answer()))
        let one: Refusal = .functionBlocksWithoutEndpoint(count: 1)
        #expect(single == one)
    }

    @Test func aDeclaredCountThatDiffersFromTheSuppliedBlocksIsRefusedForStaticAndDynamicLists() throws {
        let blocks = [Self.tile(0), Self.tile(1)]
        var dynamic = Self.ump(declared: 3)
        dynamic.hasStaticFunctionBlocks = false
        let fewer = Self.refusal(Self.facts(dynamic, blocks, try Self.answer()))
        let expectedFewer: Refusal = .functionBlockCountMismatch(declared: 3, supplied: 2)
        #expect(fewer == expectedFewer)
        let more = Self.refusal(try Self.facts(declared: 1, blocks))
        let expectedMore: Refusal = .functionBlockCountMismatch(declared: 1, supplied: 2)
        #expect(more == expectedMore)
        let none = Self.refusal(try Self.facts(declared: 0, [Self.tile(5)]))
        let expectedNone: Refusal = .functionBlockCountMismatch(declared: 0, supplied: 1)
        #expect(none == expectedNone)
    }

    struct InvalidBlockCase {
        let block: Block
        let expected: UMPStreamRefusal
    }

    @Test func eachBlockUMPValidateRefusalIsWrappedWithTheBlocksOwnIndex() throws {
        let cases = [
            InvalidBlockCase(block: Self.block(4, first: 0, count: 0), expected: .invalidField(.groupCount, value: 0)),
            InvalidBlockCase(block: Self.block(32, first: 0), expected: .functionBlockOutOfRange(32)),
            InvalidBlockCase(block: Self.block(6, first: 16), expected: .invalidField(.firstGroup, value: 16)),
            InvalidBlockCase(block: Self.block(7, first: 15, count: 2), expected: .invalidField(.groupCount, value: 2)),
            InvalidBlockCase(block: Self.block(-1, first: 0), expected: .functionBlockOutOfRange(-1))
        ]
        for item in cases {
            let result = Self.refusal(try Self.facts(declared: 1, [item.block]))
            let expected: Refusal = .functionBlockInvalid(index: item.block.index, item.expected)
            #expect(result == expected, "\(item.block.index)")
        }
        var oldCI = Self.block(8, first: 0)
        oldCI.midiCIVersion = 3
        let ciResult = Self.refusal(try Self.facts(declared: 1, [oldCI]))
        let ciExpected: Refusal = .functionBlockInvalid(index: 8, .invalidField(.midiCIVersion, value: 3))
        #expect(ciResult == ciExpected)
    }

    @Test func theFirstInvalidBlockInIndexOrderIsTheOneReported() throws {
        let late = Self.block(9, first: 16)
        let early = Self.block(2, first: 0, count: 0)
        let result = Self.refusal(try Self.facts(declared: 2, [late, early]))
        let expected: Refusal = .functionBlockInvalid(index: 2, .invalidField(.groupCount, value: 0))
        #expect(result == expected)
    }

    @Test func theSmallestRepeatedBlockIndexIsReported() throws {
        let blocks = [
            Self.tile(6), Self.tile(4), Self.block(6, first: 9), Self.tile(1), Self.block(4, first: 8)
        ]
        let result = Self.refusal(try Self.facts(declared: 5, blocks))
        let expected: Refusal = .duplicateFunctionBlockIndex(4)
        #expect(result == expected)
    }

    @Test func theFirstOverlappingPairByAscendingFirstThenSecondIndexIsReported() throws {
        let blocks = [
            Self.block(2, first: 3, count: 2), Self.block(0, first: 0, count: 4), Self.block(1, first: 4, count: 4)
        ]
        let result = Self.refusal(try Self.facts(declared: 3, blocks))
        let expected: Refusal = .overlappingFunctionBlockGroups(first: 0, second: 2)
        #expect(result == expected)
        let later = [
            Self.block(0, first: 0, count: 2), Self.block(1, first: 4, count: 4), Self.block(2, first: 7, count: 2)
        ]
        let laterResult = Self.refusal(try Self.facts(declared: 3, later))
        let expectedLater: Refusal = .overlappingFunctionBlockGroups(first: 1, second: 2)
        #expect(laterResult == expectedLater)
    }

    @Test func touchingGroupRangesAreAcceptedAndOneSharedGroupIsRefused() throws {
        let touching = [Self.block(0, first: 0, count: 4), Self.block(1, first: 4, count: 4)]
        let accepted = Self.refusal(try Self.facts(declared: 2, touching))
        #expect(accepted == nil)
        let sharing = [Self.block(0, first: 0, count: 4), Self.block(1, first: 3, count: 4)]
        let refused = Self.refusal(try Self.facts(declared: 2, sharing))
        let expected: Refusal = .overlappingFunctionBlockGroups(first: 0, second: 1)
        #expect(refused == expected)
    }

    @Test func anInactiveBlockThatOverlapsAnActiveOneIsRefused() throws {
        let blocks = [Self.block(0, first: 0, count: 4), Self.block(1, first: 2, count: 4, active: false)]
        let result = Self.refusal(try Self.facts(declared: 2, blocks))
        let expected: Refusal = .overlappingFunctionBlockGroups(first: 0, second: 1)
        #expect(result == expected)
        let bothInactive = [
            Self.block(0, first: 0, count: 4, active: false), Self.block(1, first: 2, count: 4, active: false)
        ]
        let inactiveResult = Self.refusal(try Self.facts(declared: 2, bothInactive))
        #expect(inactiveResult == expected)
    }

    @Test func theSmallestRepeatedProfileIsReportedWhateverTheCategoryBit() throws {
        let advertised = [
            try Self.profile(5), try Self.profile(3), try Self.profile(1), try Self.profile(3), try Self.profile(5)
        ]
        let expected: Refusal = .duplicateProfile(try Self.profile(3))
        let announcing = Self.refusal(try Self.full(profiles: advertised))
        #expect(announcing == expected)
        let silent = Self.refusal(try Self.full(category: Self.silentCategory, profiles: advertised))
        #expect(silent == expected)
    }

    @Test func profilesThatDifferInOneByteAreNotDuplicates() throws {
        let advertised = [try Self.profile(1, 0), try Self.profile(1, 1), try Self.profile(0, 1)]
        let result = try Self.negotiated(try Self.full(profiles: advertised))
        #expect(result.profiles.count == 3)
    }

    // MARK: - Order: every pair that can hold both defects (the fixture holds both, the alone checks prove each)

    @Test func tooManyBlocksIsReportedBeforeTooManyProfiles() throws {
        let blocks = (0..<33).map { Self.block($0, first: 0) }
        let profiles = try Self.distinctProfiles(65)
        let both = Self.refusal(try Self.facts(declared: 33, blocks, profiles: profiles))
        let onlyProfiles = Self.refusal(try Self.full(profiles: profiles))
        let onlyBlocks = Self.refusal(try Self.facts(declared: 33, blocks))
        let first: Refusal = .tooManyFunctionBlocks(count: 33)
        let second: Refusal = .tooManyProfiles(count: 65)
        #expect(both == first)
        #expect(onlyBlocks == first)
        #expect(onlyProfiles == second)
    }

    @Test func tooManyProfilesIsReportedBeforeAnInvalidEndpoint() throws {
        let profiles = try Self.distinctProfiles(65)
        let both = Self.refusal(try Self.facts(declared: 33, [], profiles: profiles))
        let onlyEndpoint = Self.refusal(try Self.facts(declared: 33, []))
        let first: Refusal = .tooManyProfiles(count: 65)
        let second: Refusal = .endpointInvalid(.invalidField(.functionBlockCount, value: 33))
        #expect(both == first)
        #expect(onlyEndpoint == second)
    }

    @Test func anInvalidEndpointIsReportedBeforeACountMismatchHeldByTheSameFacts() throws {
        let invalid = Self.refusal(try Self.facts(declared: 33, []))
        let expected: Refusal = .endpointInvalid(.invalidField(.functionBlockCount, value: 33))
        #expect(invalid == expected)
        let mismatchOnly = Self.refusal(try Self.facts(declared: 32, []))
        let mismatch: Refusal = .functionBlockCountMismatch(declared: 32, supplied: 0)
        #expect(mismatchOnly == mismatch)
    }

    @Test func blocksWithoutAnEndpointAreReportedBeforeAnInvalidBlock() throws {
        let bad = Self.block(32, first: 0)
        let both = Self.refusal(Self.facts(nil, [bad], try Self.answer()))
        let onlyBlock = Self.refusal(try Self.facts(declared: 1, [bad]))
        let onlyMissingEndpoint = Self.refusal(Self.facts(nil, [Self.tile(0)], try Self.answer()))
        let first: Refusal = .functionBlocksWithoutEndpoint(count: 1)
        let second: Refusal = .functionBlockInvalid(index: 32, .functionBlockOutOfRange(32))
        #expect(both == first)
        #expect(onlyMissingEndpoint == first)
        #expect(onlyBlock == second)
    }

    @Test func aCountMismatchIsReportedBeforeAnInvalidBlock() throws {
        let bad = Self.block(32, first: 0)
        let both = Self.refusal(try Self.facts(declared: 2, [bad]))
        let onlyBlock = Self.refusal(try Self.facts(declared: 1, [bad]))
        let onlyMismatch = Self.refusal(try Self.facts(declared: 2, [Self.tile(0)]))
        let first: Refusal = .functionBlockCountMismatch(declared: 2, supplied: 1)
        let second: Refusal = .functionBlockInvalid(index: 32, .functionBlockOutOfRange(32))
        #expect(both == first)
        #expect(onlyMismatch == first)
        #expect(onlyBlock == second)
    }

    @Test func anInvalidBlockIsReportedBeforeADuplicateBlockIndex() throws {
        let bad = Self.block(3, first: 0, count: 0)
        let both = Self.refusal(try Self.facts(declared: 2, [bad, Self.block(3, first: 4)]))
        let repeated = [Self.block(3, first: 0), Self.block(3, first: 4)]
        let onlyDuplicate = Self.refusal(try Self.facts(declared: 2, repeated))
        let first: Refusal = .functionBlockInvalid(index: 3, .invalidField(.groupCount, value: 0))
        let second: Refusal = .duplicateFunctionBlockIndex(3)
        #expect(both == first)
        #expect(onlyDuplicate == second)
    }

    @Test func aDuplicateBlockIndexIsReportedBeforeOverlappingGroups() throws {
        let same = [Self.block(3, first: 0, count: 4), Self.block(3, first: 0, count: 4)]
        let both = Self.refusal(try Self.facts(declared: 2, same))
        let crossing = [Self.block(3, first: 0, count: 4), Self.block(4, first: 2)]
        let onlyOverlap = Self.refusal(try Self.facts(declared: 2, crossing))
        let first: Refusal = .duplicateFunctionBlockIndex(3)
        let second: Refusal = .overlappingFunctionBlockGroups(first: 3, second: 4)
        #expect(both == first)
        #expect(onlyOverlap == second)
    }

    @Test func overlappingGroupsAreReportedBeforeADuplicateProfile() throws {
        let overlapping = [Self.block(0, first: 0, count: 4), Self.block(1, first: 2, count: 4)]
        let duplicated = [try Self.profile(1), try Self.profile(1)]
        let both = Self.refusal(try Self.facts(declared: 2, overlapping, profiles: duplicated))
        let onlyProfile = Self.refusal(try Self.full(profiles: duplicated))
        let first: Refusal = .overlappingFunctionBlockGroups(first: 0, second: 1)
        let second: Refusal = .duplicateProfile(try Self.profile(1))
        #expect(both == first)
        #expect(onlyProfile == second)
    }

    // MARK: - Count checks come before any per-element work

    @Test func aHundredThousandBlocksAreRefusedByCountEvenWithoutAnEndpoint() throws {
        let many = Array(repeating: Self.tile(0), count: 100_000)
        let result = Self.refusal(Self.facts(nil, many, try Self.answer()))
        let expected: Refusal = .tooManyFunctionBlocks(count: 100_000)
        #expect(result == expected)
    }

    @Test func aHundredThousandIdenticalProfilesAreRefusedByCountAndNotAsDuplicates() throws {
        let many = Array(repeating: try Self.profile(1), count: 100_000)
        let result = Self.refusal(try Self.full(profiles: many))
        let expected: Refusal = .tooManyProfiles(count: 100_000)
        #expect(result == expected)
    }
}
