import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension UndoSessionRebindTests {
    static func expectSamePlanFields(_ lhs: UndoRebindPlan, _ rhs: UndoRebindPlan) {
        #expect(lhs.kind == rhs.kind)
        #expect(lhs.newBinding == rhs.newBinding)
        #expect(lhs.undo == rhs.undo)
        #expect(lhs.redo == rhs.redo)
        #expect(lhs.redoable == rhs.redoable)
        #expect(Self.scalars(lhs.reason) == Self.scalars(rhs.reason))
        #expect(lhs.ticket.session == rhs.ticket.session)
        #expect(lhs.ticket.request.claimed == rhs.ticket.request.claimed)
        #expect(lhs.ticket.request.trigger == rhs.ticket.request.trigger)
    }

    static func issuedTicket(_ session: UndoSessionSnapshot) throws -> UndoRebindTicket {
        let request = try Self.request(.restore(try Self.target()), record: try Self.record())
        return try UndoSessionRebindPolicy.plan(session, request).ticket
    }

    // MARK: - Confirm

    @Test func confirmReturnsAPlanWithTheFieldsOfTheOriginalPlanForEachTrigger() throws {
        let session = try Self.session(undo: 4, redo: 1, unsaved: true)
        for trigger in try Self.allTriggers() {
            let request = try Self.request(trigger, record: try Self.record(), reason: "caf\u{E9}")
            let original = try UndoSessionRebindPolicy.plan(session, request)
            let confirmed = try UndoSessionRebindPolicy.confirm(original.ticket, against: session)
            Self.expectSamePlanFields(original, confirmed)
        }
    }

    @Test func confirmRefusesAsStaleWhenOnlyTheDepthAStackCountOrTheUnsavedFlagMoved() throws {
        let issued = try Self.session(undo: 3, redo: 2, unsaved: true, depth: 10)
        let ticket = try Self.issuedTicket(issued)
        let stale: UndoRebindRefusal = .staleTicket
        let moved: [UndoSessionSnapshot] = [
            try Self.session(undo: 4, redo: 2, unsaved: true, depth: 10),
            try Self.session(undo: 2, redo: 2, unsaved: true, depth: 10),
            try Self.session(undo: 3, redo: 3, unsaved: true, depth: 10),
            try Self.session(undo: 3, redo: 1, unsaved: true, depth: 10),
            try Self.session(undo: 3, redo: 2, unsaved: false, depth: 10),
            try Self.session(undo: 3, redo: 2, unsaved: true, depth: 11)
        ]
        for current in moved {
            #expect(Self.confirmRefusal(ticket, current) == stale)
        }
        #expect(Self.confirmRefusal(ticket, issued) == nil)
    }

    @Test func confirmRefusesEachChangedBindingFieldNamingTheStoredValueAsExpectedAndTheCurrentOneAsFound() throws {
        let ticket = try Self.issuedTicket(try Self.session())
        let draftOutcome = Self.confirmRefusal(ticket, try Self.session(try Self.binding(draft: "draft.b")))
        let draftExpected: UndoRebindRefusal = .draftMismatch(
            expected: try Self.draftID("draft.a"),
            found: try Self.draftID("draft.b")
        )
        #expect(draftOutcome == draftExpected)
        let graphOutcome = Self.confirmRefusal(ticket, try Self.session(try Self.binding(graph: "graph.b")))
        let graphExpected: UndoRebindRefusal = .graphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        #expect(graphOutcome == graphExpected)
        let revisionOutcome = Self.confirmRefusal(ticket, try Self.session(try Self.binding(revision: 6)))
        let revisionExpected: UndoRebindRefusal = .revisionMismatch(
            expected: try Self.revision(5),
            found: try Self.revision(6)
        )
        #expect(revisionOutcome == revisionExpected)
        let contentExpected: UndoRebindRefusal = .contentMismatch(try Self.revision(5))
        for changed in [try Self.binding(seed: 3), try Self.binding(bytes: 101)] {
            #expect(Self.confirmRefusal(ticket, try Self.session(changed)) == contentExpected)
        }
    }

    @Test func confirmChecksTheDraftBeforeTheGraphWhenBothDiffer() throws {
        let ticket = try Self.issuedTicket(try Self.session())
        let bothWrong = try Self.session(try Self.binding(draft: "draft.b", graph: "graph.b"))
        let graphWrong = try Self.session(try Self.binding(graph: "graph.b"))
        let draftExpected: UndoRebindRefusal = .draftMismatch(
            expected: try Self.draftID("draft.a"),
            found: try Self.draftID("draft.b")
        )
        let graphExpected: UndoRebindRefusal = .graphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        #expect(Self.confirmRefusal(ticket, bothWrong) == draftExpected)
        #expect(Self.confirmRefusal(ticket, graphWrong) == graphExpected)
    }

    @Test func confirmChecksTheGraphBeforeTheRevisionWhenBothDiffer() throws {
        let ticket = try Self.issuedTicket(try Self.session())
        let bothWrong = try Self.session(try Self.binding(graph: "graph.b", revision: 6))
        let graphExpected: UndoRebindRefusal = .graphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        #expect(Self.confirmRefusal(ticket, bothWrong) == graphExpected)
    }

    @Test func confirmChecksTheRevisionBeforeTheContentWhenBothDiffer() throws {
        let ticket = try Self.issuedTicket(try Self.session())
        let bothWrong = try Self.session(try Self.binding(revision: 6, seed: 3))
        let revisionExpected: UndoRebindRefusal = .revisionMismatch(
            expected: try Self.revision(5),
            found: try Self.revision(6)
        )
        #expect(Self.confirmRefusal(ticket, bothWrong) == revisionExpected)
    }

    @Test func confirmChecksTheBindingBeforeTheStackCountsWhenBothDiffer() throws {
        let ticket = try Self.issuedTicket(try Self.session(undo: 3, redo: 2))
        let bothWrong = try Self.session(try Self.binding(seed: 3), undo: 4, redo: 2)
        let countsOnly = try Self.session(undo: 4, redo: 2)
        let contentExpected: UndoRebindRefusal = .contentMismatch(try Self.revision(5))
        let staleExpected: UndoRebindRefusal = .staleTicket
        #expect(Self.confirmRefusal(ticket, bothWrong) == contentExpected)
        #expect(Self.confirmRefusal(ticket, countsOnly) == staleExpected)
    }

    @Test func aTicketIssuedForAnotherSessionFailsWithTheFirstDifferingCheckNotAGenericRefusal() throws {
        let ticket = try Self.issuedTicket(try Self.session(try Self.binding(draft: "draft.a"), undo: 1, redo: 1))
        let other = try Self.session(try Self.binding(draft: "draft.z"), undo: 5, redo: 0, unsaved: false)
        let expected: UndoRebindRefusal = .draftMismatch(
            expected: try Self.draftID("draft.a"),
            found: try Self.draftID("draft.z")
        )
        #expect(Self.confirmRefusal(ticket, other) == expected)
    }

    @Test func confirmRecomputesThePlanSoAForgedTicketWithARefusedRequestIsRefused() throws {
        let session = try Self.session(unsaved: true)
        let badReason = try Self.request(.clear, reason: "")
        let noRecord = try Self.request(.restore(try Self.target()))
        let reasonExpected: UndoRebindRefusal = .reasonBytes(0)
        let missingExpected: UndoRebindRefusal = .preRestoreMissing
        let forgedReason = UndoRebindTicket(session: session, request: badReason)
        let forgedMissing = UndoRebindTicket(session: session, request: noRecord)
        #expect(Self.confirmRefusal(forgedReason, session) == reasonExpected)
        #expect(Self.confirmRefusal(forgedMissing, session) == missingExpected)
    }

    @Test func repeatedPlansAndConfirmationsOfOneInputGiveTheSameFieldsDeterminismOnly() throws {
        let session = try Self.session()
        let request = try Self.request(.replace(try Self.target()), record: try Self.record())
        let first = try UndoSessionRebindPolicy.plan(session, request)
        let second = try UndoSessionRebindPolicy.plan(session, request)
        Self.expectSamePlanFields(first, second)
        let third = try UndoSessionRebindPolicy.confirm(first.ticket, against: session)
        let fourth = try UndoSessionRebindPolicy.confirm(first.ticket, against: session)
        Self.expectSamePlanFields(third, fourth)
    }

    // MARK: - Production sources

    static let productionFiles = [
        "UndoSessionSnapshot.swift", "UndoRebindRequest.swift", "UndoRebindRefusal.swift",
        "UndoRebindPlan.swift", "UndoSessionRebindPolicy.swift"
    ]

    static func productionTexts() -> [String]? {
        let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let inRepository = parts.dropLast(2).joined(separator: "/") + "/Shared/Persistence/Undo/"
        let inMirror = parts.dropLast(3).joined(separator: "/") + "/Sources/FluxKlang/Shared/Persistence/Undo/"
        for root in [inRepository, inMirror] {
            let texts = productionFiles.compactMap { try? String(contentsOfFile: root + $0, encoding: .utf8) }
            if texts.count == productionFiles.count { return texts }
        }
        return nil
    }

    static var productionSourcesAreReadable: Bool {
        productionTexts() != nil
    }

    @Test(.enabled(if: UndoSessionRebindTests.productionSourcesAreReadable))
    func theFiveProductionFilesContainNoneOfTheBannedWordsImportsOrOperatorDefinitions() throws {
        let texts = try #require(Self.productionTexts())
        let banned = [
            "import SwiftUI", "import Foundation", "Date(", "Clock", "Task", "DispatchQueue", "FileManager",
            "default:", "static func ==", "static func <", "static func >", "static func +", "static func -"
        ]
        #expect(texts.count == 5)
        for text in texts {
            for word in banned {
                #expect(!text.contains(word))
            }
        }
    }
}
