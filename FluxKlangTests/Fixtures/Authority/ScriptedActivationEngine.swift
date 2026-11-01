//
//  ScriptedActivationEngine.swift
//  FluxKlangTests
//
//  A scripted activation engine for the HostAuthority tests: it drains the
//  actor's command queue, records every command, answers prepares from a
//  fixed ID sequence and fault script, and reports commits consistently with
//  each plan's nodes. No audio, MIDI, hardware or I/O.
//

@testable import FluxKlang

/// Why the scripted engine could not be created.
enum ScriptedEngineError: Error, Equatable, Sendable {
    case faults(FaultScriptError)
    case recorder(BoundedRecorderError)
    case ids(FixtureIDSequenceError)
}

/// One delivered prepare answer and what the actor made of it.
struct ScriptedPrepareAnswer: Sendable {
    let attempt: PrepareAttemptID
    let answer: Result<PreparedActivationID, PrepareFailure>
    let verdict: Result<PrepareAnswerOutcome, HostAuthorityRefusal>
}

/// One `.commit` the engine took and has not reported.
struct ScriptedCommit: Hashable, Sendable {
    let prepared: PreparedActivationID
    let attempt: CommitAttemptID
    let token: EngineLeaseToken
}

/// One delivered commit report and what the actor made of it.
struct ScriptedCommitReport: Sendable {
    let report: ActivationCommitReport
    let verdict: Result<CommitReportOutcome, HostAuthorityRefusal>
}

struct ScriptedActivationEngine: Sendable {
    /// Fails exactly the scripted prepare answers (1-based, in answer order).
    private(set) var faults: FaultScript
    /// Every command taken from the actor, in order.
    private(set) var recorder: BoundedRecorder<EngineCommand>
    /// Prepared plan IDs `fx.prep.1`, `fx.prep.2`, … in answer order.
    private(set) var ids: FixtureIDSequence<PreparedActivationTag>
    /// Prepares taken and not yet answered, oldest first.
    private(set) var pending: [PrepareAttemptID] = []
    /// Commits taken and not yet reported, oldest first.
    private(set) var pendingCommits: [ScriptedCommit] = []
    /// The node IDs of each prepare taken, until it is answered.
    private var preparingNodes: [PrepareAttemptID: Set<NodeID>] = [:]
    /// The node IDs of each plan this engine prepared (answered with success).
    private(set) var plannedNodes: [PreparedActivationID: Set<NodeID>] = [:]

    init(failing: [Int: FixtureFault] = [:], answerLimit: Int = 512,
         recordCapacity: Int = 1_024) throws(ScriptedEngineError) {
        do { faults = try FaultScript(failing: failing, callLimit: answerLimit) } catch { throw .faults(error) }
        do { recorder = try BoundedRecorder(capacity: recordCapacity) } catch { throw .recorder(error) }
        do { ids = try FixtureIDSequence(prefix: "prep", limit: answerLimit) } catch { throw .ids(error) }
    }

    var commands: [EngineCommand] { recorder.entries }

    /// The discards taken so far, in order.
    var discarded: [PreparedActivationID] {
        commands.compactMap { command in
            if case .discard(let id) = command { return id }
            return nil
        }
    }

    /// Takes every queued command, recording each and remembering each prepare and commit.
    /// Returns the commands taken by this call.
    @discardableResult
    mutating func drain(_ authority: HostAuthority) async -> [EngineCommand] {
        var taken: [EngineCommand] = []
        while let command = await authority.nextEngineCommand() {
            _ = recorder.record(command)
            switch command {
            case .prepare(let graph, let attempt):
                pending.append(attempt)
                preparingNodes[attempt] = Set(graph.nodes.map(\.id))
            case .commit(let prepared, let attempt, let token):
                pendingCommits.append(ScriptedCommit(prepared: prepared, attempt: attempt, token: token))
            default: break
            }
            taken.append(command)
        }
        return taken
    }

    /// The scripted answer to the next prepare, without delivering it: the next
    /// fixture ID, or `.engineRefused` for a scripted fault. A call past the
    /// limit or the ID sequence's end also fails closed as `.engineRefused`.
    mutating func scriptedAnswer() -> Result<PreparedActivationID, PrepareFailure> {
        do { try faults.nextCall() } catch { return .failure(.engineRefused) }
        do { return .success(try ids.next()) } catch { return .failure(.engineRefused) }
    }

    /// Answers the oldest pending prepare with the scripted answer; nil when nothing is pending.
    mutating func answerNext(_ authority: HostAuthority) async -> ScriptedPrepareAnswer? {
        guard let attempt = withholdNext() else { return nil }
        let answer = scriptedAnswer()
        if case .success(let id) = answer, let nodes = preparingNodes[attempt] { plannedNodes[id] = nodes }
        preparingNodes[attempt] = nil
        let verdict = await authority.prepareAnswered(answer, attempt: attempt)
        return ScriptedPrepareAnswer(attempt: attempt, answer: answer, verdict: verdict)
    }

    /// Takes the oldest pending prepare without answering it (the answer is lost
    /// or late); the test delivers it later, for example with `scriptedAnswer()`.
    mutating func withholdNext() -> PrepareAttemptID? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Takes the oldest pending commit without reporting it (the report is lost or
    /// late); the test may deliver it later, for example with `report(on:_:)`.
    mutating func withholdCommit() -> ScriptedCommit? {
        pendingCommits.isEmpty ? nil : pendingCommits.removeFirst()
    }

    /// A report on `commit` consistent with its plan's nodes: `.succeeded` applies
    /// every node, `.failed` none and `.partial` only the lowest node ID (so a
    /// consistent partial needs a plan of two or more nodes).
    func report(on commit: ScriptedCommit, _ outcome: ActivationCommitOutcome) -> ActivationCommitReport {
        let nodes = plannedNodes[commit.prepared] ?? []
        let applied: Set<NodeID>
        switch outcome {
        case .succeeded: applied = nodes
        case .failed: applied = []
        case .partial: applied = nodes.min().map { [$0] } ?? []
        }
        return ActivationCommitReport(prepared: commit.prepared, attempt: commit.attempt, outcome: outcome,
                                      applied: applied, unapplied: nodes.subtracting(applied))
    }

    /// Reports the oldest pending commit with `outcome`; nil when none is pending.
    mutating func report(_ authority: HostAuthority, _ outcome: ActivationCommitOutcome) async
    -> ScriptedCommitReport? {
        guard let commit = withholdCommit() else { return nil }
        let report = report(on: commit, outcome)
        return ScriptedCommitReport(report: report, verdict: await authority.commitReported(report))
    }
}
