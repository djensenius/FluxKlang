import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension UndoSessionRebindTests {
    // MARK: - Which rebinds need a preRestore checkpoint

    @Test func restoreWithoutACheckpointIsRefusedEvenWhenTheSessionHasNoUnsavedEdits() throws {
        let missing: UndoRebindRefusal = .preRestoreMissing
        let moved = try Self.target()
        for unsaved in [false, true] {
            let session = try Self.session(unsaved: unsaved)
            let outcome = Self.refusal(session, try Self.request(.restore(moved)))
            #expect(outcome == missing)
            let withRecord = try Self.request(.restore(moved), record: try Self.record())
            #expect(Self.refusal(session, withRecord) == nil)
        }
    }

    @Test func replaceNeedsACheckpointExactlyWhenTheSessionHasUnsavedEdits() throws {
        let moved = try Self.target()
        let dirty = try Self.session(unsaved: true)
        let clean = try Self.session(unsaved: false)
        let missing: UndoRebindRefusal = .preRestoreMissing
        #expect(Self.refusal(dirty, try Self.request(.replace(moved))) == missing)
        #expect(Self.refusal(dirty, try Self.request(.replace(moved), record: try Self.record())) == nil)
        #expect(Self.refusal(clean, try Self.request(.replace(moved))) == nil)
    }

    @Test func aCheckpointSuppliedToAReplaceWithoutUnsavedEditsIsIgnoredEvenWhenItIsGarbage() throws {
        let clean = try Self.session(unsaved: false)
        let garbage = try Self.record(.manual, revision: 99, seed: 9, bytes: 1)
        let request = try Self.request(.replace(try Self.target()), record: garbage)
        let plan = try UndoSessionRebindPolicy.plan(clean, request)
        let sixth = try Self.revision(6)
        #expect(plan.kind == .replace)
        #expect(plan.newBinding.revision == sixth)
    }

    // MARK: - What the checkpoint must say

    @Test func aCheckpointOfAnyReasonButPreRestoreIsRefusedNamingThatReasonForRestoreAndReplace() throws {
        let session = try Self.session(unsaved: true)
        for reason in [CheckpointReason.manual, .autosave, .preMigration] {
            for trigger in Self.checkpointTriggers(try Self.target()) {
                let outcome = Self.refusal(session, try Self.request(trigger, record: try Self.record(reason)))
                let expected: UndoRebindRefusal = .preRestoreWrongReason(reason)
                #expect(outcome == expected)
            }
        }
    }

    @Test func aCheckpointOfAnotherRevisionIsRefusedStaleNamingBothRevisions() throws {
        let session = try Self.session(unsaved: true)
        let moved = try Self.target()
        for revision in [4, 6, 0] {
            let request = try Self.request(.restore(moved), record: try Self.record(revision: revision))
            let expected: UndoRebindRefusal = .preRestoreRevisionStale(
                expected: try Self.revision(5),
                found: try Self.revision(revision)
            )
            #expect(Self.refusal(session, request) == expected)
        }
    }

    @Test func aCheckpointWithAnotherDigestByteOrByteCountIsRefusedStaleContent() throws {
        let session = try Self.session(unsaved: true)
        let moved = try Self.target()
        var lastByte = [UInt8](repeating: 1, count: 32)
        lastByte[31] = 2
        let digestOnly = try CheckpointRecord.make(
            id: CheckpointID(1), ordinal: 1, revision: try Self.revision(5), reason: .preRestore,
            digest: lastByte, byteCount: 100, label: ""
        )
        let stale: UndoRebindRefusal = .preRestoreContentStale
        let records = [digestOnly, try Self.record(bytes: 99), try Self.record(seed: 2)]
        for record in records {
            let outcome = Self.refusal(session, try Self.request(.restore(moved), record: record))
            #expect(outcome == stale)
        }
    }

    @Test func aMatchingCheckpointIsAcceptedWhateverItsIdentifierOrdinalAndLabelAre() throws {
        let session = try Self.session(unsaved: true)
        let other = try CheckpointRecord.make(
            id: CheckpointID(4_000), ordinal: 123, revision: try Self.revision(5), reason: .preRestore,
            digest: [UInt8](repeating: 1, count: 32), byteCount: 100, label: "another label"
        )
        let request = try Self.request(.restore(try Self.target()), record: other)
        #expect(Self.refusal(session, request) == nil)
    }

    // MARK: - The target

    @Test func aTargetOnAnotherGraphIsRefusedNamingBothGraphsForRestoreAndReplace() throws {
        let session = try Self.session(unsaved: true)
        let elsewhere = try Self.target(graph: "graph.other")
        let expected: UndoRebindRefusal = .targetGraphMismatch(
            expected: try Self.graphID("graph.a"),
            found: try Self.graphID("graph.other")
        )
        for trigger in Self.checkpointTriggers(elsewhere) {
            let outcome = Self.refusal(session, try Self.request(trigger, record: try Self.record()))
            #expect(outcome == expected)
        }
    }

    @Test func aTargetRevisionMustBeStrictlyGreaterThanTheSessionRevision() throws {
        let session = try Self.session(unsaved: true)
        for (revision, accepted) in [(4, false), (5, false), (6, true), (7, true)] {
            let moved = try Self.target(revision: revision)
            for trigger in Self.checkpointTriggers(moved) {
                let outcome = Self.refusal(session, try Self.request(trigger, record: try Self.record()))
                if accepted {
                    #expect(outcome == nil)
                } else {
                    let expected: UndoRebindRefusal = .targetNotNewer(
                        session: try Self.revision(5),
                        target: try Self.revision(revision)
                    )
                    #expect(outcome == expected)
                }
            }
        }
    }

    @Test func aTargetAtTheMaximumRevisionIsLegalAndASessionAtTheMaximumCanOnlyBeCleared() throws {
        let maximum = ContractRevision.maximumValue
        let belowTop = maximum - 1
        let top = try Self.revision(maximum)
        let nearBinding = try Self.binding(revision: belowTop)
        let nearTop = try Self.session(nearBinding, unsaved: true)
        let toMaximum = try Self.target(revision: maximum)
        let nearRecord = try Self.record(revision: belowTop)
        let nearRequest = try Self.request(.restore(toMaximum), claimed: nearBinding, record: nearRecord)
        let plan = try UndoSessionRebindPolicy.plan(nearTop, nearRequest)
        #expect(plan.newBinding.revision == top)

        let topBinding = try Self.binding(revision: maximum)
        let atTop = try Self.session(topBinding, unsaved: true)
        let topRecord = try Self.record(revision: maximum)
        let notNewer: UndoRebindRefusal = .targetNotNewer(session: top, target: top)
        for trigger in Self.checkpointTriggers(toMaximum) {
            let request = try Self.request(trigger, claimed: topBinding, record: topRecord)
            #expect(Self.refusal(atTop, request) == notNewer)
        }
        let cleared = try UndoSessionRebindPolicy.plan(atTop, try Self.request(.clear, claimed: topBinding))
        #expect(cleared.newBinding.revision == top)
    }
}
