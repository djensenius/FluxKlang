import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct UndoSessionRebindTests {
    // MARK: - Shared fixtures (every extension file uses these)

    static let digestBytes = 32

    static func revision(_ value: Int) throws -> ContractRevision {
        try ContractRevision(value)
    }

    static func fingerprint(_ seed: UInt8 = 1, bytes: Int = 100) throws -> UndoContentFingerprint {
        try UndoContentFingerprint.make(digest: Array(repeating: seed, count: digestBytes), byteCount: bytes)
    }

    static func binding(
        draft: String = "draft.a",
        graph: String = "graph.a",
        revision: Int = 5,
        seed: UInt8 = 1,
        bytes: Int = 100
    ) throws -> UndoSessionBinding {
        UndoSessionBinding(
            draft: try DraftID(draft),
            graph: try GraphID(graph),
            revision: try ContractRevision(revision),
            content: try fingerprint(seed, bytes: bytes)
        )
    }

    static func session(
        _ binding: UndoSessionBinding? = nil,
        undo: Int = 3,
        redo: Int = 2,
        unsaved: Bool = true,
        depth: Int = 10
    ) throws -> UndoSessionSnapshot {
        let bound = try binding ?? Self.binding()
        return try UndoSessionSnapshot.make(
            binding: bound,
            depth: try DraftHistoryDepth.make(depth),
            undoCount: undo,
            redoCount: redo,
            hasUnsavedEdits: unsaved,
            mutationGeneration: 0
        )
    }

    static func reissued(_ snapshot: UndoSessionSnapshot, generation: UInt64) throws -> UndoSessionSnapshot {
        try UndoSessionSnapshot.make(
            binding: snapshot.binding,
            depth: snapshot.depth,
            undoCount: snapshot.undoCount,
            redoCount: snapshot.redoCount,
            hasUnsavedEdits: snapshot.hasUnsavedEdits,
            mutationGeneration: generation
        )
    }

    static func target(
        graph: String = "graph.a",
        revision: Int = 6,
        seed: UInt8 = 2,
        bytes: Int = 200
    ) throws -> UndoRebindTarget {
        UndoRebindTarget(
            graph: try GraphID(graph),
            revision: try ContractRevision(revision),
            content: try fingerprint(seed, bytes: bytes)
        )
    }

    static func record(
        _ reason: CheckpointReason = .preRestore,
        revision: Int = 5,
        seed: UInt8 = 1,
        bytes: Int = 100
    ) throws -> CheckpointRecord {
        try CheckpointRecord.make(
            id: CheckpointID(77),
            ordinal: 9,
            revision: try ContractRevision(revision),
            reason: reason,
            digest: Array(repeating: seed, count: digestBytes),
            byteCount: bytes,
            label: ""
        )
    }

    static func request(
        _ trigger: UndoRebindTrigger,
        claimed: UndoSessionBinding? = nil,
        record: CheckpointRecord? = nil,
        reason: String = "rebind"
    ) throws -> UndoRebindRequest {
        let claim = try claimed ?? Self.binding()
        return UndoRebindRequest(claimed: claim, trigger: trigger, preRestore: record, reason: reason)
    }

    static func refusal(_ session: UndoSessionSnapshot, _ request: UndoRebindRequest) -> UndoRebindRefusal? {
        do {
            _ = try UndoSessionRebindPolicy.plan(session, request)
            return nil
        } catch {
            return error
        }
    }

    static func confirmRefusal(_ ticket: UndoRebindTicket, _ session: UndoSessionSnapshot) -> UndoRebindRefusal? {
        do {
            _ = try UndoSessionRebindPolicy.confirm(ticket, against: session)
            return nil
        } catch {
            return error
        }
    }

    static func fingerprintRefusal(_ digest: [UInt8], _ byteCount: Int) -> UndoRebindRefusal? {
        do {
            _ = try UndoContentFingerprint.make(digest: digest, byteCount: byteCount)
            return nil
        } catch {
            return error
        }
    }

    static func snapshotRefusal(undo: Int, redo: Int, depth: Int = 10) throws -> UndoRebindRefusal? {
        do {
            _ = try session(undo: undo, redo: redo, depth: depth)
            return nil
        } catch let refusal as UndoRebindRefusal {
            return refusal
        }
    }

    static func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    static func allTriggers() throws -> [UndoRebindTrigger] {
        let moved = try target()
        return [.restore(moved), .replace(moved), .clear]
    }

    // MARK: - Fingerprint

    @Test func fingerprintAcceptsThirtyTwoDigestBytesAndRefusesThirtyOneAndThirtyThreeNamingTheLength() throws {
        let accepted = try Self.fingerprint(7, bytes: 0)
        #expect(accepted.digest.count == 32)
        #expect(accepted.byteCount == 0)
        for length in [0, 31, 33] {
            let outcome = Self.fingerprintRefusal([UInt8](repeating: 1, count: length), 10)
            let expected: UndoRebindRefusal = .invalidDigestLength(length)
            #expect(outcome == expected)
        }
    }

    @Test func fingerprintAcceptsZeroAndTheHardMaximumByteCountAndRefusesOutsideNamingTheValue() throws {
        let maximum = CheckpointLimits.hardMaximumRecordBytes
        let digest = [UInt8](repeating: 1, count: 32)
        #expect(Self.fingerprintRefusal(digest, 0) == nil)
        #expect(Self.fingerprintRefusal(digest, maximum) == nil)
        let above = maximum + 1
        let aboveExpected: UndoRebindRefusal = .invalidByteCount(above)
        let belowExpected: UndoRebindRefusal = .invalidByteCount(-1)
        #expect(Self.fingerprintRefusal(digest, above) == aboveExpected)
        #expect(Self.fingerprintRefusal(digest, -1) == belowExpected)
    }

    @Test func fingerprintRefusesABadDigestLengthBeforeABadByteCountAndNotTheOtherWayAround() throws {
        let both = Self.fingerprintRefusal([UInt8](repeating: 1, count: 31), -1)
        let digestExpected: UndoRebindRefusal = .invalidDigestLength(31)
        #expect(both == digestExpected)
        let countOnly = Self.fingerprintRefusal([UInt8](repeating: 1, count: 32), -1)
        let countExpected: UndoRebindRefusal = .invalidByteCount(-1)
        #expect(countOnly == countExpected)
    }

    @Test func fingerprintContentComparisonSeesTheLastDigestByteAndTheByteCountButNotRecordIdentity() throws {
        let base = try Self.fingerprint(1, bytes: 100)
        var lastByte = [UInt8](repeating: 1, count: 32)
        lastByte[31] = 2
        let lastDiffers = try UndoContentFingerprint.make(digest: lastByte, byteCount: 100)
        #expect(base.isSameContent(as: try Self.fingerprint(1, bytes: 100)))
        #expect(!base.isSameContent(as: lastDiffers))
        #expect(!base.isSameContent(as: try Self.fingerprint(1, bytes: 101)))
        let otherRecord = try Self.record(.manual, revision: 99, seed: 1, bytes: 100)
        #expect(base.isSameContent(as: otherRecord))
        #expect(!base.isSameContent(as: try Self.record(.preRestore, seed: 3, bytes: 100)))
        #expect(!base.isSameContent(as: try Self.record(.preRestore, seed: 1, bytes: 99)))
    }

    // MARK: - Snapshot

    @Test func snapshotAcceptsCountsUpToTheDepthIncludingEmptyAndRefusesOneOverNegativeAndHugeCounts() throws {
        let accepted: [(Int, Int)] = [(0, 0), (10, 0), (0, 10), (5, 5), (9, 1)]
        for (undo, redo) in accepted {
            let outcome = try Self.snapshotRefusal(undo: undo, redo: redo)
            #expect(outcome == nil)
        }
        let refused: [(Int, Int)] = [
            (11, 0), (0, 11), (6, 5), (5, 6), (-1, 0), (0, -1), (-1, 11), (Int.max, 0), (0, Int.max), (Int.max, Int.max)
        ]
        for (undo, redo) in refused {
            let outcome = try Self.snapshotRefusal(undo: undo, redo: redo)
            let expected: UndoRebindRefusal = .sessionInvalid
            #expect(outcome == expected)
        }
    }

    @Test func snapshotDepthOfOneHoldsExactlyOneEntryInTotal() throws {
        let one = try Self.snapshotRefusal(undo: 1, redo: 0, depth: 1)
        let two = try Self.snapshotRefusal(undo: 1, redo: 1, depth: 1)
        let expected: UndoRebindRefusal = .sessionInvalid
        #expect(one == nil)
        #expect(two == expected)
    }

    // MARK: - Plans

    @Test func restorePlanTakesTheTargetRevisionAndContentWithTheSessionsDraftAndGraph() throws {
        let session = try Self.session(unsaved: false)
        let moved = try Self.target(revision: 8, seed: 4, bytes: 321)
        let request = try Self.request(.restore(moved), record: try Self.record(), reason: "caf\u{E9} \u{2713}")
        let plan = try UndoSessionRebindPolicy.plan(session, request)
        let expected = UndoSessionBinding(
            draft: session.binding.draft,
            graph: session.binding.graph,
            revision: try Self.revision(8),
            content: try Self.fingerprint(4, bytes: 321)
        )
        #expect(plan.kind == .restore)
        #expect(plan.newBinding == expected)
        #expect(plan.undo == .discarded(count: 3))
        #expect(plan.redo == .discarded(count: 2))
        #expect(!plan.redoable)
        #expect(Self.scalars(plan.reason) == [0x63, 0x61, 0x66, 0xE9, 0x20, 0x2713])
        #expect(plan.ticket.session == session)
        #expect(plan.ticket.request.claimed == session.binding)
    }

    @Test func replacePlanOfASessionWithUnsavedEditsTakesTheTargetAndKeepsTheSessionsDraftAndGraph() throws {
        let session = try Self.session(undo: 6, redo: 1, unsaved: true)
        let moved = try Self.target(revision: 7, seed: 5, bytes: 55)
        let request = try Self.request(.replace(moved), record: try Self.record(), reason: "replace")
        let plan = try UndoSessionRebindPolicy.plan(session, request)
        let expected = UndoSessionBinding(
            draft: session.binding.draft,
            graph: session.binding.graph,
            revision: try Self.revision(7),
            content: try Self.fingerprint(5, bytes: 55)
        )
        #expect(plan.kind == .replace)
        #expect(plan.newBinding == expected)
        #expect(plan.undo == .discarded(count: 6))
        #expect(plan.redo == .discarded(count: 1))
        #expect(Self.scalars(plan.reason) == Self.scalars("replace"))
    }

    @Test func clearPlanKeepsTheBindingNeedsNoCheckpointAndIgnoresAGarbageOne() throws {
        let session = try Self.session(unsaved: true)
        let bare = try UndoSessionRebindPolicy.plan(session, try Self.request(.clear))
        #expect(bare.kind == .clear)
        #expect(bare.newBinding == session.binding)
        #expect(bare.undo == .discarded(count: 3))
        #expect(bare.redo == .discarded(count: 2))
        let garbage = try Self.record(.manual, revision: 99, seed: 9, bytes: 1)
        let withGarbage = try UndoSessionRebindPolicy.plan(session, try Self.request(.clear, record: garbage))
        #expect(withGarbage.kind == .clear)
        #expect(withGarbage.newBinding == session.binding)
        #expect(withGarbage.undo == bare.undo)
        #expect(withGarbage.redo == bare.redo)
    }

    @Test func everyTriggerDiscardsBothStacksWithTheirCountsIncludingZeroNeverKeepsAndIsNeverRedoable() throws {
        let sizes: [(Int, Int)] = [(0, 0), (4, 0), (0, 6), (7, 3)]
        for (undo, redo) in sizes {
            let session = try Self.session(undo: undo, redo: redo, unsaved: true)
            for trigger in try Self.allTriggers() {
                let request = try Self.request(trigger, record: try Self.record())
                let plan = try UndoSessionRebindPolicy.plan(session, request)
                let undone: UndoStackDisposition = .discarded(count: undo)
                let redone: UndoStackDisposition = .discarded(count: redo)
                #expect(plan.undo == undone)
                #expect(plan.redo == redone)
                #expect(plan.undo != .kept)
                #expect(plan.redo != .kept)
                #expect(!plan.redoable)
            }
        }
    }

    @Test func stackDispositionsReportTheirDiscardedCountAndKeptReportsZero() throws {
        let kept: UndoStackDisposition = .kept
        let four: UndoStackDisposition = .discarded(count: 4)
        let none: UndoStackDisposition = .discarded(count: 0)
        #expect(kept.discardedCount == 0)
        #expect(four.discardedCount == 4)
        #expect(none.discardedCount == 0)
    }
}
