//
//  ScriptedActivationEngine.swift
//  FluxKlangTests
//
//  A scripted activation engine for the HostAuthority tests: it drains the
//  actor's command queue, records every command and answers prepares from a
//  fixed ID sequence and fault script, or under chosen, possibly reused IDs
//  whose plans it holds until a discard disposes of them. No audio, MIDI,
//  hardware or I/O.
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

/// A plan the scripted engine prepared under `id` for `attempt` and still holds.
/// IDs are not unique: the engine may reuse one (`prepare(_:as:)`), as nothing
/// in the contracts forbids.
struct ScriptedHeldPlan: Hashable, Sendable {
    let id: PreparedActivationID
    let attempt: PrepareAttemptID
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
    /// Plans prepared with `prepare(_:as:)` and still held, oldest first. A taken
    /// `.discard` disposes of the oldest held plan with its ID, and only of a held plan.
    private(set) var held: [ScriptedHeldPlan] = []
    /// The held plans the engine's discards disposed of, in order.
    private(set) var disposed: [ScriptedHeldPlan] = []

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

    /// Takes every queued command, recording each and remembering each prepare.
    /// Returns the commands taken by this call.
    @discardableResult
    mutating func drain(_ authority: HostAuthority) async -> [EngineCommand] {
        var taken: [EngineCommand] = []
        while let command = await authority.nextEngineCommand() {
            _ = recorder.record(command)
            switch command {
            case .prepare(_, let attempt): pending.append(attempt)
            case .discard(let id): dispose(id)
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
        let verdict = await authority.prepareAnswered(answer, attempt: attempt)
        return ScriptedPrepareAnswer(attempt: attempt, answer: answer, verdict: verdict)
    }

    /// Takes the oldest pending prepare without answering it (the answer is lost
    /// or late); the test delivers it later, for example with `scriptedAnswer()`.
    mutating func withholdNext() -> PrepareAttemptID? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Prepares `attempt`'s plan under the chosen `id` (which may reuse an ID) and
    /// holds it. Returns the success answer without delivering it.
    mutating func prepare(_ attempt: PrepareAttemptID,
                          as id: PreparedActivationID) -> Result<PreparedActivationID, PrepareFailure> {
        held.append(ScriptedHeldPlan(id: id, attempt: attempt))
        return .success(id)
    }

    /// The engine lets go of `attempt`'s plan on its own (for example, after its own
    /// timeout), freeing the ID for reuse. Nothing is reported to the actor.
    mutating func release(_ attempt: PrepareAttemptID) {
        held.removeAll { $0.attempt == attempt }
    }

    private mutating func dispose(_ id: PreparedActivationID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        disposed.append(held.remove(at: index))
    }
}
