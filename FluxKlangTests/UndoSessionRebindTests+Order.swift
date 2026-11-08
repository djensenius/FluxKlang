import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension UndoSessionRebindTests {
    static func checkpointTriggers(_ moved: UndoRebindTarget) -> [UndoRebindTrigger] {
        [.restore(moved), .replace(moved)]
    }

    static func draftID(_ raw: String) throws -> DraftID {
        try DraftID(raw)
    }

    static func graphID(_ raw: String) throws -> GraphID {
        try GraphID(raw)
    }

    // MARK: - Reason bytes

    @Test func reasonOfSixtyFourBytesIsAcceptedAndSixtyFiveOrSixtySixOrZeroBytesAreRefusedNamingTheByteCount() throws {
        let session = try Self.session()
        let sixtyFour = String(repeating: "\u{E9}", count: 32)
        let sixtyFive = sixtyFour + "a"
        let sixtySix = String(repeating: "\u{E9}", count: 33)
        #expect(sixtyFour.utf8.count == 64)
        #expect(sixtySix.count == 33)
        #expect(Self.refusal(session, try Self.request(.clear, reason: sixtyFour)) == nil)
        #expect(Self.refusal(session, try Self.request(.clear, reason: "a")) == nil)
        let cases: [(String, Int)] = [("", 0), (sixtyFive, 65), (sixtySix, 66)]
        for (reason, bytes) in cases {
            let outcome = Self.refusal(session, try Self.request(.clear, reason: reason))
            let expected: UndoRebindRefusal = .reasonBytes(bytes)
            #expect(outcome == expected)
        }
    }

    // MARK: - Refusal order: each fixture carries both defects of the adjacent pair

    @Test func anInvalidReasonIsRefusedBeforeAMismatchedDraft() throws {
        let session = try Self.session()
        let wrongDraft = try Self.binding(draft: "draft.b")
        let both = Self.refusal(session, try Self.request(.clear, claimed: wrongDraft, reason: ""))
        let reasonOnly = Self.refusal(session, try Self.request(.clear, reason: ""))
        let draftOnly = Self.refusal(session, try Self.request(.clear, claimed: wrongDraft))
        let reasonExpected: UndoRebindRefusal = .reasonBytes(0)
        let draftExpected: UndoRebindRefusal = .draftMismatch(
            expected: try Self.draftID("draft.a"),
            found: try Self.draftID("draft.b")
        )
        #expect(both == reasonExpected)
        #expect(reasonOnly == reasonExpected)
        #expect(draftOnly == draftExpected)
    }

    @Test func aMismatchedDraftIsRefusedBeforeAMismatchedGraph() throws {
        let session = try Self.session()
        let bothWrong = try Self.binding(draft: "draft.b", graph: "graph.b")
        let graphWrong = try Self.binding(graph: "graph.b")
        let both = Self.refusal(session, try Self.request(.clear, claimed: bothWrong))
        let graphOnly = Self.refusal(session, try Self.request(.clear, claimed: graphWrong))
        let draftExpected: UndoRebindRefusal = .draftMismatch(
            expected: try Self.draftID("draft.a"),
            found: try Self.draftID("draft.b")
        )
        let graphExpected: UndoRebindRefusal = .graphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        #expect(both == draftExpected)
        #expect(graphOnly == graphExpected)
    }

    @Test func aMismatchedGraphIsRefusedBeforeAMismatchedRevision() throws {
        let session = try Self.session()
        let bothWrong = try Self.binding(graph: "graph.b", revision: 6)
        let revisionWrong = try Self.binding(revision: 6)
        let both = Self.refusal(session, try Self.request(.clear, claimed: bothWrong))
        let revisionOnly = Self.refusal(session, try Self.request(.clear, claimed: revisionWrong))
        let graphExpected: UndoRebindRefusal = .graphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        let revisionExpected: UndoRebindRefusal = .revisionMismatch(
            expected: try Self.revision(5),
            found: try Self.revision(6)
        )
        #expect(both == graphExpected)
        #expect(revisionOnly == revisionExpected)
    }

    @Test func aMismatchedRevisionIsRefusedBeforeMismatchedContentAndContentNamesTheSessionRevision() throws {
        let session = try Self.session()
        let bothWrong = try Self.binding(revision: 6, seed: 3)
        let contentWrong = try Self.binding(seed: 3)
        let byteCountWrong = try Self.binding(bytes: 101)
        let both = Self.refusal(session, try Self.request(.clear, claimed: bothWrong))
        let contentOnly = Self.refusal(session, try Self.request(.clear, claimed: contentWrong))
        let bytesOnly = Self.refusal(session, try Self.request(.clear, claimed: byteCountWrong))
        let revisionExpected: UndoRebindRefusal = .revisionMismatch(
            expected: try Self.revision(5),
            found: try Self.revision(6)
        )
        let contentExpected: UndoRebindRefusal = .contentMismatch(try Self.revision(5))
        #expect(both == revisionExpected)
        #expect(contentOnly == contentExpected)
        #expect(bytesOnly == contentExpected)
    }

    @Test func mismatchedContentIsRefusedBeforeAMissingCheckpointForRestoreAndReplace() throws {
        let session = try Self.session(unsaved: true)
        let contentWrong = try Self.binding(seed: 3)
        let contentExpected: UndoRebindRefusal = .contentMismatch(try Self.revision(5))
        let missingExpected: UndoRebindRefusal = .preRestoreMissing
        for trigger in Self.checkpointTriggers(try Self.target()) {
            let both = Self.refusal(session, try Self.request(trigger, claimed: contentWrong))
            let missingOnly = Self.refusal(session, try Self.request(trigger))
            #expect(both == contentExpected)
            #expect(missingOnly == missingExpected)
        }
    }

    @Test func aRecordOfAnotherReasonIsRefusedBeforeAStaleRecordForRestoreAndReplace() throws {
        let session = try Self.session(unsaved: true)
        let staleManual = try Self.record(.manual, revision: 4, seed: 3)
        let staleRestore = try Self.record(.preRestore, revision: 4, seed: 3)
        let reasonExpected: UndoRebindRefusal = .preRestoreWrongReason(.manual)
        let staleExpected: UndoRebindRefusal = .preRestoreRevisionStale(
            expected: try Self.revision(5),
            found: try Self.revision(4)
        )
        for trigger in Self.checkpointTriggers(try Self.target()) {
            let both = Self.refusal(session, try Self.request(trigger, record: staleManual))
            let staleOnly = Self.refusal(session, try Self.request(trigger, record: staleRestore))
            #expect(both == reasonExpected)
            #expect(staleOnly == staleExpected)
        }
    }

    @Test func aStaleRecordRevisionIsRefusedBeforeStaleRecordContentForRestoreAndReplace() throws {
        let session = try Self.session(unsaved: true)
        let bothStale = try Self.record(.preRestore, revision: 4, seed: 3)
        let contentStale = try Self.record(.preRestore, revision: 5, seed: 3)
        let revisionExpected: UndoRebindRefusal = .preRestoreRevisionStale(
            expected: try Self.revision(5),
            found: try Self.revision(4)
        )
        let contentExpected: UndoRebindRefusal = .preRestoreContentStale
        for trigger in Self.checkpointTriggers(try Self.target()) {
            let both = Self.refusal(session, try Self.request(trigger, record: bothStale))
            let contentOnly = Self.refusal(session, try Self.request(trigger, record: contentStale))
            #expect(both == revisionExpected)
            #expect(contentOnly == contentExpected)
        }
    }

    @Test func aMissingOrStaleCheckpointIsRefusedBeforeATargetOnAnotherGraphForRestoreAndReplace() throws {
        let session = try Self.session(unsaved: true)
        let elsewhere = try Self.target(graph: "graph.b")
        let missingExpected: UndoRebindRefusal = .preRestoreMissing
        let staleExpected: UndoRebindRefusal = .preRestoreRevisionStale(
            expected: try Self.revision(5),
            found: try Self.revision(4)
        )
        let contentExpected: UndoRebindRefusal = .preRestoreContentStale
        let targetExpected: UndoRebindRefusal = .targetGraphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        for trigger in Self.checkpointTriggers(elsewhere) {
            let missing = Self.refusal(session, try Self.request(trigger))
            let stale = Self.refusal(session, try Self.request(trigger, record: try Self.record(revision: 4)))
            let contentStale = Self.refusal(session, try Self.request(trigger, record: try Self.record(seed: 3)))
            let targetOnly = Self.refusal(session, try Self.request(trigger, record: try Self.record()))
            #expect(missing == missingExpected)
            #expect(stale == staleExpected)
            #expect(contentStale == contentExpected)
            #expect(targetOnly == targetExpected)
        }
    }

    @Test func aTargetOnAnotherGraphIsRefusedBeforeATargetThatIsNotNewer() throws {
        let session = try Self.session(unsaved: true)
        let bothWrong = try Self.target(graph: "graph.b", revision: 5)
        let notNewer = try Self.target(graph: "graph.a", revision: 5)
        let graphExpected: UndoRebindRefusal = .targetGraphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.b")
        )
        let newerExpected: UndoRebindRefusal = .targetNotNewer(
            session: try Self.revision(5),
            target: try Self.revision(5)
        )
        for trigger in [UndoRebindTrigger.restore(bothWrong), .replace(bothWrong)] {
            let both = Self.refusal(session, try Self.request(trigger, record: try Self.record()))
            #expect(both == graphExpected)
        }
        for trigger in [UndoRebindTrigger.restore(notNewer), .replace(notNewer)] {
            let newerOnly = Self.refusal(session, try Self.request(trigger, record: try Self.record()))
            #expect(newerOnly == newerExpected)
        }
    }
}
