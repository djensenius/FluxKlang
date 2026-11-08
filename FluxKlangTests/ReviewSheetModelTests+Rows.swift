//
//  ReviewSheetModelTests+Rows.swift
//  FluxKlangTests
//
//  The rows of the review sheet (#99 RV1): one per diff change in the diff's order, hazards after them sorted by the
//  UTF-8 bytes of their ids, the row and hazard bounds with N and N+1, byte-counted text, and four of the refusal-order
//  pairs (each with a fixture that holds both defects).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ReviewSheetModelTests {
    static let precomposed = "\u{e9}"
    static let decomposed = "e\u{301}"

    static func repeated(_ text: String, _ count: Int) -> String { String(repeating: text, count: count) }

    static func kinds(of model: ReviewSheetModel) -> [ReviewRowKind] { model.rows.map(\.kind) }

    static func hazardIDs(of model: ReviewSheetModel) -> [String] {
        model.rows.compactMap { row -> String? in
            guard case .hazard(let hazard) = row else { return nil }
            return hazard.id
        }
    }

    // MARK: Changes

    @Test func oneRowPerChangeKindFollowsTheDiffOrderAndThenTheHazards() throws {
        var input = try Self.safeInput()
        input.diff = try Self.everyKindDiff()
        input.hazards = [Self.hazard("hz.one")]
        let built = try Self.model(input)
        #expect(Self.kinds(of: built) == [.addedNode, .movedNode, .removedNode, .addedEdge, .removedEdge, .hazard])
        #expect(built.rows.map(\.subject) == ["nod.z", "nod.a", "nod.c", "edg.ba", "edg.ab", "hz.one"])
        #expect(built.rows.dropLast() == input.diff.changes.map(ReviewRow.change)[...])
    }

    @Test func rowsOfOneKindKeepTheDiffsIdOrderNotTheEditOrder() throws {
        let edits = try ["nod.m", "nod.b2", "nod.k"].map { GraphEdit.addNode(try Self.stereo($0, at: 4)) }
        var input = try Self.safeInput()
        input.diff = try Self.diff(edits, on: try Self.graph())
        let built = try Self.model(input)
        #expect(built.rows.map(\.subject) == ["nod.b2", "nod.k", "nod.m"])
        #expect(built.rows == input.diff.changes.map(ReviewRow.change))
    }

    @Test func aRowNamesItsKindItsSubjectAndWhetherItBlocks() throws {
        var input = try Self.safeInput()
        input.hazards = [Self.hazard("hz.soft", blocks: false), Self.hazard("hz.hard", blocks: true)]
        let built = try Self.model(input)
        #expect(built.rows.map(\.subject) == ["nod.n0", "hz.hard", "hz.soft"])
        #expect(built.rows.map(\.blocksActivation) == [false, true, false])
        #expect(Self.kinds(of: built) == [.addedNode, .hazard, .hazard])
    }

    @Test func anEmptyDiffGivesAValidModelWithNoRowsAndTheSafeDefault() throws {
        var input = try Self.safeInput()
        input.diff = try Self.emptyDiff()
        let built = try Self.model(input)
        #expect(built.rows.isEmpty)
        #expect(!built.canActivate && built.creates == nil)
        #expect(built.defaultAction == .keepAsDraft)
        #expect(built.resolve(.returnKey) == .keepAsDraft && built.resolve(.escapeKey) == .keepAsDraft)
    }

    @Test func oneChangeGivesOneRowAndCreatesTheNextRevision() throws {
        let built = try Self.model(try Self.safeInput())
        #expect(built.rows.count == 1)
        let eight = try Self.revision(8)
        #expect(built.canActivate && built.creates == eight)
    }

    @Test func exactly512ChangesAreAcceptedAndOneMoreIsRefused() throws {
        var input = try Self.safeInput()
        input.diff = try Self.addedNodesDiff(count: 512)
        #expect(try Self.model(input).rows.count == 512)
        input.diff = try Self.addedNodesDiff(count: 513)
        #expect(Self.refusal(of: input) == .tooManyRows(count: 513, maximum: 512))
    }

    @Test func aFull512ChangesAnd64HazardsGiveTheChangeRowsThenTheHazardRows() throws {
        var input = try Self.safeInput()
        input.diff = try Self.addedNodesDiff(count: 512)
        input.hazards = (0..<64).map { Self.hazard("hz.\($0)") }
        let built = try Self.model(input)
        #expect(built.rows.count == 576)
        #expect(built.rows.filter { $0.kind == .hazard }.count == 64)
        #expect(built.rows.prefix(512).allSatisfy { $0.kind == .addedNode })
    }

    @Test func aSmallerRowLimitIsUsedInsteadOfTheStandardOne() throws {
        let limits = try ReviewSheetLimits.make(maximumRows: 2, maximumHazards: 64)
        var input = try Self.safeInput()
        input.diff = try Self.addedNodesDiff(count: 2)
        #expect(try Self.model(input, limits: limits).rows.count == 2)
        input.diff = try Self.addedNodesDiff(count: 3)
        #expect(Self.refusal(of: input, limits: limits) == .tooManyRows(count: 3, maximum: 2))
    }

    // MARK: Hazard count and order

    @Test func exactly64HazardsAreAcceptedAndOneMoreIsRefused() throws {
        var input = try Self.safeInput()
        input.hazards = (0..<64).map { Self.hazard("hz.\($0)") }
        #expect(try Self.model(input).rows.count == 65)
        input.hazards = (0..<65).map { Self.hazard("hz.\($0)") }
        #expect(Self.refusal(of: input) == .tooManyHazards(count: 65, maximum: 64))
    }

    @Test func aSmallerHazardLimitIsUsedInsteadOfTheStandardOne() throws {
        let limits = try ReviewSheetLimits.make(maximumRows: 512, maximumHazards: 3)
        var input = try Self.safeInput()
        input.hazards = (0..<3).map { Self.hazard("hz.\($0)") }
        #expect(try Self.model(input, limits: limits).rows.count == 4)
        input.hazards = (0..<4).map { Self.hazard("hz.\($0)") }
        #expect(Self.refusal(of: input, limits: limits) == .tooManyHazards(count: 4, maximum: 3))
    }

    @Test func noHazardsAreAcceptedAtTheLowestHazardCount() throws {
        let limits = try ReviewSheetLimits.make(maximumRows: 512, maximumHazards: 0)
        var input = try Self.safeInput()
        #expect(try Self.model(input, limits: limits).rows.count == 1)
        input.hazards = [Self.hazard("hz.one")]
        #expect(Self.refusal(of: input, limits: limits) == .tooManyHazards(count: 1, maximum: 0))
    }

    @Test func hazardRowsFollowTheChangesSortedByTheBytesOfTheirIDs() throws {
        let ids = ["f", Self.precomposed, "alpha", Self.decomposed, "Zed"]
        var input = try Self.safeInput()
        input.hazards = ids.map { Self.hazard($0) }
        let built = try Self.model(input)
        let expected = ["Zed", "alpha", Self.decomposed, "f", Self.precomposed]
        #expect(Self.hazardIDs(of: built).map { Array($0.utf8) } == expected.map { Array($0.utf8) })
        #expect(built.rows.first?.kind == .addedNode)
    }

    @Test func idsThatAreCanonicallyEquivalentButByteDifferentStayTwoHazards() throws {
        var input = try Self.safeInput()
        input.hazards = [Self.hazard(Self.precomposed, "one"), Self.hazard(Self.decomposed, "two")]
        let built = try Self.model(input)
        let hazards = built.rows.compactMap { row -> ReviewHazard? in
            guard case .hazard(let hazard) = row else { return nil }
            return hazard
        }
        #expect(hazards.count == 2)
        #expect(hazards.map(\.summary) == ["two", "one"])
    }

    @Test func everyCallerOrderOfFourHazardsGivesTheSameWholeModel() throws {
        let hazards = [
            Self.hazard("hz.b", "b", blocks: true), Self.hazard(Self.precomposed, "p"),
            Self.hazard("Hz.a", "a"), Self.hazard(Self.decomposed, "d", blocks: true)
        ]
        var input = try Self.safeInput()
        input.hazards = hazards
        let reference = try Self.model(input)
        let orders = Self.permutations(hazards)
        #expect(orders.count == 24)
        for order in orders {
            input.hazards = order
            #expect(try Self.model(input) == reference)
        }
    }

    // MARK: Hazard text

    @Test func aHazardIDIsAcceptedAt64BytesAndRefusedAt65BytesWithMultiByteCharacters() throws {
        var input = try Self.safeInput()
        let accepted = Self.repeated("\u{1F600}", 16)
        input.hazards = [Self.hazard(accepted)]
        #expect(accepted.utf8.count == 64 && accepted.count == 16)
        #expect(Self.hazardIDs(of: try Self.model(input)) == [accepted])
        let refused = accepted + "a"
        #expect(refused.utf8.count == 65 && refused.count == 17)
        input.hazards = [Self.hazard(refused)]
        #expect(Self.refusal(of: input) == .invalidHazardID(refused))
        let narrow = Self.repeated(Self.precomposed, 32) + "a"
        input.hazards = [Self.hazard(narrow)]
        #expect(narrow.utf8.count == 65 && narrow.count == 33)
        #expect(Self.refusal(of: input) == .invalidHazardID(narrow))
    }

    @Test func aHazardIDOfOneByteIsAcceptedAndAnEmptyOneIsRefused() throws {
        var input = try Self.safeInput()
        input.hazards = [Self.hazard("x")]
        #expect(Self.hazardIDs(of: try Self.model(input)) == ["x"])
        input.hazards = [Self.hazard("")]
        #expect(Self.refusal(of: input) == .invalidHazardID(""))
    }

    @Test func aHazardSummaryIsAcceptedAt160BytesAndRefusedAt161BytesWithMultiByteCharacters() throws {
        var input = try Self.safeInput()
        let accepted = Self.repeated("\u{1F600}", 40)
        input.hazards = [Self.hazard("hz.s", accepted)]
        #expect(accepted.utf8.count == 160 && accepted.count == 40)
        #expect(try Self.model(input).rows.count == 2)
        let refused = accepted + "a"
        input.hazards = [Self.hazard("hz.s", refused)]
        #expect(refused.utf8.count == 161 && refused.count == 41)
        #expect(Self.refusal(of: input) == .invalidHazardSummary(id: "hz.s"))
        let narrow = Self.repeated(Self.precomposed, 80) + "a"
        input.hazards = [Self.hazard("hz.t", narrow)]
        #expect(narrow.utf8.count == 161 && narrow.count == 81)
        #expect(Self.refusal(of: input) == .invalidHazardSummary(id: "hz.t"))
    }

    @Test func aHazardSummaryOfOneByteIsAcceptedAndAnEmptyOneIsRefused() throws {
        var input = try Self.safeInput()
        input.hazards = [Self.hazard("hz.s", "x")]
        #expect(try Self.model(input).rows.count == 2)
        input.hazards = [Self.hazard("hz.s", "")]
        #expect(Self.refusal(of: input) == .invalidHazardSummary(id: "hz.s"))
    }

    @Test func aSummaryIsStoredUnchangedWithoutTrimmingOrNormalising() throws {
        let summary = "  \u{200B}Cafe" + Self.decomposed + "\n "
        var input = try Self.safeInput()
        input.hazards = [Self.hazard("hz.s", summary)]
        let built = try Self.model(input)
        guard case .hazard(let kept)? = built.rows.last else {
            Issue.record("the last row is not a hazard")
            return
        }
        #expect(Array(kept.summary.unicodeScalars) == Array(summary.unicodeScalars))
        #expect(kept.summary.utf8.count == summary.utf8.count)
    }

    @Test func aRepeatedIDIsRefusedAndNamesTheSmallestRepeatInEveryCallerOrder() throws {
        let hazards = [
            Self.hazard("hz.b", "1"), Self.hazard("hz.a", "2"), Self.hazard("hz.b", "3"), Self.hazard("hz.a", "4")
        ]
        var input = try Self.safeInput()
        for order in Self.permutations(hazards) {
            input.hazards = order
            #expect(Self.refusal(of: input) == .duplicateHazardID("hz.a"))
        }
    }

    @Test func invalidIDsAndSummariesNameTheSmallestOffenderInEveryCallerOrder() throws {
        let longest = Self.repeated("z", 65)
        let earlier = Self.repeated("m", 65)
        let hazards = [Self.hazard(longest), Self.hazard(earlier), Self.hazard("hz.ok")]
        var input = try Self.safeInput()
        for order in Self.permutations(hazards) {
            input.hazards = order
            #expect(Self.refusal(of: input) == .invalidHazardID(earlier))
        }
        let summaries = [Self.hazard("hz.c", ""), Self.hazard("hz.a", ""), Self.hazard("hz.b", "ok")]
        for order in Self.permutations(summaries) {
            input.hazards = order
            #expect(Self.refusal(of: input) == .invalidHazardSummary(id: "hz.a"))
        }
    }

    // MARK: Refusal order, rows and hazards

    @Test func tooManyRowsAreRefusedBeforeTooManyHazards() throws {
        var input = try Self.safeInput()
        input.diff = try Self.addedNodesDiff(count: 513)
        input.hazards = (0..<65).map { Self.hazard("hz.\($0)") }
        #expect(Self.refusal(of: input) == .tooManyRows(count: 513, maximum: 512))
    }

    @Test func tooManyHazardsAreRefusedBeforeAnyHazardIsInspected() throws {
        var input = try Self.safeInput()
        input.hazards = (0..<65).map { _ in Self.hazard("", "") }
        #expect(Self.refusal(of: input) == .tooManyHazards(count: 65, maximum: 64))
    }

    @Test func anInvalidIDIsRefusedBeforeAnInvalidSummaryInBothCallerOrders() throws {
        let badSummary = Self.hazard("hz.a", "")
        let badID = Self.hazard("", "fine")
        var input = try Self.safeInput()
        for order in [[badSummary, badID], [badID, badSummary]] {
            input.hazards = order
            #expect(Self.refusal(of: input) == .invalidHazardID(""))
        }
    }

    @Test func anInvalidSummaryIsRefusedBeforeARepeatedIDInBothCallerOrders() throws {
        let repeatedOne = Self.hazard("hz.a", "one")
        let repeatedTwo = Self.hazard("hz.a", "two")
        let badSummary = Self.hazard("hz.b", "")
        var input = try Self.safeInput()
        for order in [[repeatedOne, repeatedTwo, badSummary], [badSummary, repeatedOne, repeatedTwo]] {
            input.hazards = order
            #expect(Self.refusal(of: input) == .invalidHazardSummary(id: "hz.b"))
        }
    }
}
