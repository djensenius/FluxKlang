//
//  ScriptedActivationEngine.swift
//  FluxKlangTests
//
//  Qualified, bounded contract double. No audio, hardware or executor safety proof.
//

import Testing
@testable import FluxKlang

enum ScriptedEngineError: Error, Equatable, Sendable {
    case faults(FaultScriptError)
    case recorder(BoundedRecorderError)
    case ids(FixtureIDSequenceError)
    case invalidTrackedLimit
}

struct ScriptedPrepareAnswer: Sendable {
    let preparation: HostPrepare
    let answer: Result<PreparedActivationID, PrepareFailure>
    let verdict: Result<PrepareAnswerOutcome, HostAuthorityRefusal>
    var attempt: PrepareAttemptID { preparation.attempt }
}

struct ScriptedCommit: Hashable, Sendable {
    let binding: PlanBinding
    let attempt: CommitAttemptID
    let token: EngineLeaseToken
    var prepared: PreparedActivationID { binding.prepared }
}

struct ScriptedCommitReport: Sendable {
    let report: ActivationCommitReport
    let verdict: Result<CommitReportOutcome, HostAuthorityRefusal>
}

/// One delivered restore that the engine has not acknowledged.
struct ScriptedRestore: Hashable, Sendable {
    let attempt: RestoreAttemptID
    let revision: ContractRevision
    let target: RestoreTarget
    let token: EngineLeaseToken
}

struct ScriptedHeldPlan: Hashable, Sendable {
    let preparation: HostPrepare
    let id: PreparedActivationID

    func matches(_ binding: PlanBinding) -> Bool {
        preparation.instance == binding.instance && preparation.attempt == binding.attempt && id == binding.prepared
    }
}

struct ScriptedActivationEngine: Sendable {
    private(set) var faults: FaultScript
    private(set) var recorder: BoundedRecorder<EngineCommand>
    private(set) var ids: FixtureIDSequence<PreparedActivationTag>
    let trackedLimit: Int
    private(set) var pending: [HostPrepare] = []
    private(set) var pendingCommits: [ScriptedCommit] = []
    /// Restores taken and not yet acknowledged, oldest first.
    private(set) var pendingRestores: [ScriptedRestore] = []
    /// Kept for lost answers too. Both chosen and generated answers use this exact key.
    private(set) var plannedNodes: [HostPrepare: Set<NodeID>] = [:]
    private(set) var held: [ScriptedHeldPlan] = []
    private(set) var disposed: [ScriptedHeldPlan] = []
    private(set) var anomalies: [String] = []

    init(failing: [Int: FixtureFault] = [:], answerLimit: Int = 512,
         recordCapacity: Int = 1_024, trackedLimit: Int = 256) throws(ScriptedEngineError) {
        guard trackedLimit > 0 else { throw .invalidTrackedLimit }
        self.trackedLimit = trackedLimit
        do { faults = try FaultScript(failing: failing, callLimit: answerLimit) } catch { throw .faults(error) }
        do { recorder = try BoundedRecorder(capacity: recordCapacity) } catch { throw .recorder(error) }
        do { ids = try FixtureIDSequence(prefix: "prep", limit: answerLimit) } catch { throw .ids(error) }
    }

    var commands: [EngineCommand] { recorder.entries }
    var discarded: [PlanBinding] {
        commands.compactMap { if case .discard(let binding) = $0 { binding } else { nil } }
    }

    @discardableResult
    mutating func drain(_ authority: HostAuthority) async -> [EngineCommand] {
        var taken: [EngineCommand] = []
        while let command = await authority.nextEngineCommand() {
            if !recorder.record(command) { anomaly("command history capacity") }
            await handle(command, by: authority)
            if room(taken.count, "drain history") { taken.append(command) }
        }
        return taken
    }

    private mutating func handle(_ command: EngineCommand, by authority: HostAuthority) async {
        switch command {
        case .prepare(let graph, let instance, let attempt):
            takePreparation(graph, key: HostPrepare(instance: instance, attempt: attempt))
        case .commit(let binding, let attempt, let token):
            takeCommit(ScriptedCommit(binding: binding, attempt: attempt, token: token))
        case .discard(let binding):
            await retire(binding, through: authority)
        case .restore(let attempt, let revision, let target, let token):
            if room(pendingRestores.count, "pending restores") {
                pendingRestores.append(ScriptedRestore(attempt: attempt, revision: revision,
                                                       target: target, token: token))
            }
        case .keepActivePartial, .placeholders, .setOutputsMuted: break
        }
    }

    private mutating func retire(_ binding: PlanBinding, through authority: HostAuthority) async {
        guard dispose(binding) else { return }
        if case .failure(let refusal) = await authority.retired(binding) {
            anomaly("retirement acknowledgement refused: \(refusal)")
        }
    }

    private mutating func takePreparation(_ graph: GraphDocument, key: HostPrepare) {
        if plannedNodes[key] != nil {
            anomaly("duplicate prepare dispatch")
        } else if room(plannedNodes.count, "tracked preparations"), room(pending.count, "pending prepares") {
            plannedNodes[key] = Set(graph.nodes.map(\.id))
            pending.append(key)
        }
    }

    private mutating func takeCommit(_ commit: ScriptedCommit) {
        if !held.contains(where: { $0.matches(commit.binding) }) { anomaly("commit of unknown binding") }
        if room(pendingCommits.count, "pending commits") { pendingCommits.append(commit) }
    }

    mutating func scriptedAnswer() -> Result<PreparedActivationID, PrepareFailure> {
        do { try faults.nextCall() } catch {
            if error == .callLimitExceeded { anomaly("answer script capacity") }
            return .failure(.engineRefused)
        }
        do { return .success(try ids.next()) } catch {
            anomaly("answer ID capacity")
            return .failure(.engineRefused)
        }
    }

    mutating func answerNext(_ authority: HostAuthority) async -> ScriptedPrepareAnswer? {
        guard let preparation = withholdNext() else { return nil }
        let answer: Result<PreparedActivationID, PrepareFailure>
        switch scriptedAnswer() {
        case .success(let id): answer = prepare(preparation, as: id)
        case .failure(let failure): answer = terminalFailure(preparation, reason: failure)
        }
        let verdict = await authority.prepareAnswered(
            answer, instance: preparation.instance, attempt: preparation.attempt
        )
        return ScriptedPrepareAnswer(preparation: preparation, answer: answer, verdict: verdict)
    }

    mutating func withholdNext() -> HostPrepare? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    mutating func requireNext() throws -> HostPrepare {
        let next = withholdNext()
        return try #require(next)
    }

    mutating func withholdCommit() -> ScriptedCommit? {
        pendingCommits.isEmpty ? nil : pendingCommits.removeFirst()
    }

    func report(on commit: ScriptedCommit, _ outcome: ActivationCommitOutcome) -> ActivationCommitReport {
        let key = HostPrepare(instance: commit.binding.instance, attempt: commit.binding.attempt)
        if plannedNodes[key] == nil || !held.contains(where: { $0.matches(commit.binding) }) {
            Issue.record("report for unknown qualified preparation")
        }
        let nodes = plannedNodes[key] ?? []
        let applied: Set<NodeID>
        switch outcome {
        case .succeeded: applied = nodes
        case .failed: applied = []
        case .partial: applied = nodes.min().map { [$0] } ?? []
        }
        return ActivationCommitReport(prepared: commit.prepared, attempt: commit.attempt, outcome: outcome,
                                      applied: applied, unapplied: nodes.subtracting(applied))
    }

    mutating func report(_ authority: HostAuthority, _ outcome: ActivationCommitOutcome) async
    -> ScriptedCommitReport? {
        guard let commit = withholdCommit() else { return nil }
        let report = report(on: commit, outcome)
        return ScriptedCommitReport(report: report, verdict: await authority.commitReported(report))
    }

    /// Acknowledges the oldest delivered restore; nil when none is pending.
    mutating func completeRestore(_ authority: HostAuthority) async
    -> Result<EngineLifecycle, HostAuthorityRefusal>? {
        guard !pendingRestores.isEmpty else { return nil }
        let restore = pendingRestores.removeFirst()
        return await authority.restoreCompleted(attempt: restore.attempt, revision: restore.revision,
                                                target: restore.target, token: restore.token)
    }

    mutating func prepare(_ preparation: HostPrepare,
                          as id: PreparedActivationID) -> Result<PreparedActivationID, PrepareFailure> {
        guard plannedNodes[preparation] != nil, !held.contains(where: { $0.preparation == preparation }) else {
            anomaly("unknown or duplicate preparation answer")
            return .failure(.engineRefused)
        }
        guard room(held.count, "held plans") else {
            plannedNodes[preparation] = nil
            return .failure(.engineRefused)
        }
        held.append(ScriptedHeldPlan(preparation: preparation, id: id))
        return .success(id)
    }

    /// Simulated terminal cleanup, including the preparation's node bookkeeping.
    mutating func terminalFailure(
        _ preparation: HostPrepare, reason: PrepareFailure
    ) -> Result<PreparedActivationID, PrepareFailure> {
        held.removeAll { $0.preparation == preparation }
        plannedNodes[preparation] = nil
        pending.removeAll { $0 == preparation }
        return .failure(reason)
    }

    private mutating func dispose(_ binding: PlanBinding) -> Bool {
        guard let index = held.firstIndex(where: { $0.matches(binding) }) else {
            anomaly("discard of unknown qualified binding")
            return false
        }
        let plan = held.remove(at: index)
        plannedNodes[plan.preparation] = nil
        if room(disposed.count, "disposal history") { disposed.append(plan) }
        return true
    }

    private mutating func room(_ count: Int, _ collection: String) -> Bool {
        guard count < trackedLimit else {
            anomaly("\(collection) capacity")
            return false
        }
        return true
    }

    private mutating func anomaly(_ message: String) {
        Issue.record(Comment(rawValue: message))
        if anomalies.count < trackedLimit { anomalies.append(message) }
    }
}
