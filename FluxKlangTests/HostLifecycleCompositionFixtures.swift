import Foundation
import Observation
import Testing
@testable import FluxKlang

@MainActor
final class LifecycleGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Inert operation closures, not a controller, transport, authority or receipt substitute.
@MainActor
@Observable
final class LifecycleProbe {
    typealias Lifecycle = HostWingLifecycle

    struct Hooks {
        var oldStop: @MainActor () async -> Void = {}
        var start: @MainActor () async -> Void = {}
        var current: (@MainActor () -> Bool)?
        var stop: @MainActor () async -> Void = {}
        var finish: @MainActor () async -> Void = {}
    }

    var identity = UUID()
    var captured: [UUID] = []
    var events: [String] = []
    var assigned = 0
    var started = 0
    var stopped = 0
    var finished = 0
    var completions: [Lifecycle.Completion] = []

    func operation(_ outcome: Lifecycle.Outcome, hooks: Hooks = Hooks()) -> Lifecycle.Operation {
        let old = identity
        captured.append(old)
        return Lifecycle.Operation(stopOld: {
            self.events.append("old-stop")
            await hooks.oldStop()
            self.events.append("old-stopped")
        }, start: {
            self.assigned += 1
            let candidateID: UUID
            if case .success(.connected(let session)) = outcome { candidateID = session } else {
                candidateID = UUID()
            }
            self.identity = candidateID
            let result = await Lifecycle.startUnlessCancelled {
                self.started += 1
                self.events.append("start")
                await hooks.start()
                return outcome
            }
            return Lifecycle.Candidate(outcome: result, isCurrent: {
                hooks.current?() ?? (self.identity == candidateID)
            }, stop: {
                self.stopped += 1
                self.events.append("candidate-stop")
                await hooks.stop()
                self.events.append("candidate-stopped")
            }, finish: {
                self.finished += 1
                self.events.append("finish")
                await hooks.finish()
            })
        })
    }
}

enum LifecycleOwnerBench {
    static let window = WindowID(validated: "win.lifecycle")
    static let other = ProjectID(validated: "project.other")
    static let target = DirectSendTarget("/ch/1/fdr")

    static func owner() async throws -> HostAuthorityOwner {
        let owner = try HostAuthorityOwner()
        _ = try await owner.opened.value.get()
        return owner
    }

    static func holdOther(_ owner: HostAuthorityOwner) async throws -> EngineLeaseSnapshot {
        _ = try await owner.authority.open(
            project: other, running: RunningGraph(revision: .initial, prepared: nil)).get()
        return try await owner.authority.acquire(project: other, window: window).get()
    }

    static func holdStudio(_ owner: HostAuthorityOwner) async throws -> EngineLeaseSnapshot {
        _ = try await owner.grant(.host).get()
        return try await owner.authority.acquire(project: owner.studio, window: window).get()
    }

    static func minter(_ owner: HostAuthorityOwner) -> WingApplyGrantMinter {
        WingApplyGrantMinter(authority: owner.authority, project: owner.studio, window: window,
                             budget: WingApplyTicketBudget(limit: 8), provider: owner.provider)
    }

    static func ticket(_ owner: HostAuthorityOwner) async throws -> DirectWriteTicket {
        let admission = try #require(await owner.admission())
        return try #require(try await owner.authority.admitDirect(
            admission.intent, admission: admission.admission, project: owner.studio, window: window
        ).get())
    }

    static func refusal<Value>(_ result: Result<Value, DirectWriteRefusal>) -> DirectWriteRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }
}

/// Opens on the first of several signals and keeps that one, so a fixture wait ends on any outcome.
@MainActor
final class LifecycleFirst {
    private(set) var first: String?
    private let gate = LifecycleGate()

    func signal(_ name: String) {
        if first == nil { first = name }
        gate.open()
    }

    func wait() async -> String? {
        await gate.wait()
        return first
    }
}

/// One-shot apply pause: the armed owner checkpoint suspends one apply until `resume` opens.
@MainActor
final class LifecycleApplyPause {
    var point: HostAuthorityOwner.Checkpoint?
    var reached: LifecycleFirst?
    /// Runs each time the owner queues a lifecycle call behind its lock.
    var queued: (@MainActor () -> Void)?
    let resume = LifecycleGate()

    func visit(_ visited: HostAuthorityOwner.Checkpoint) async {
        guard visited == point else { return }
        point = nil
        reached?.signal("reached")
        await resume.wait()
    }
}

/// A granted owner and a lifecycle that opened `LifecycleOwnerBench.window`, whose replacement has published
/// `session`, then holds the FIFO turn in `finish` until `release` opens. Every wait ends on success or on
/// the failure it would hide.
@MainActor
struct LifecycleHeldTurn {
    struct Unheld: Error {}

    let pause = LifecycleApplyPause()
    let owner: HostAuthorityOwner
    let lifecycle: HostWingLifecycle
    let session = UUID()
    let release = LifecycleGate()
    let replacement: Task<HostWingLifecycle.Outcome, Never>

    init() async throws {
        let (pause, session, release, first) = (self.pause, self.session, self.release, LifecycleFirst())
        owner = try HostAuthorityOwner(checkpoint: { await pause.visit($0) },
                                       lifecycleQueued: { Task { @MainActor in pause.queued?() } })
        _ = try await owner.opened.value.get()
        _ = try await owner.grant(.host).get()
        let lifecycle = HostWingLifecycle(owner: owner)
        await lifecycle.open(LifecycleOwnerBench.window).wait()
        let probe = LifecycleProbe()
        let replacement = Task {
            await lifecycle.replace {
                probe.operation(.success(.connected(session)), hooks: .init(finish: {
                    first.signal("holding")
                    await release.wait()
                }))
            }
        }
        (self.lifecycle, self.replacement) = (lifecycle, replacement)
        Task {
            let outcome = await replacement.value
            first.signal("returned \(outcome)")
        }
        let holding = await first.wait()
        guard holding == "holding" else {
            Issue.record("replacement \(holding ?? "") before holding the turn")
            throw Unheld()
        }
    }

    /// Queues a replacement that republishes `session`, then holds its turn in `finish` until `release`
    /// opens. Returns once it is queued, with a gate that opens once it holds.
    func queueHold(until release: LifecycleGate) async
        -> (holding: LifecycleGate, task: Task<HostWingLifecycle.Outcome, Never>) {
        let (lifecycle, session, probe) = (lifecycle, session, LifecycleProbe())
        let (queued, holding) = (LifecycleGate(), LifecycleGate())
        let task = Task {
            queued.open()
            return await lifecycle.replace {
                probe.operation(.success(.connected(session)), hooks: .init(finish: {
                    holding.open()
                    await release.wait()
                }))
            }
        }
        await queued.wait()
        return (holding, task)
    }

    /// Returns once `window`'s apply is suspended at `point`; nil, recording an issue, if it completed first.
    func pausedApply(_ window: WindowID, at point: HostAuthorityOwner.Checkpoint)
        async -> Task<Result<UUID, HostAuthorityOwner.ApplyRefusal>, Never>? {
        let (owner, first) = (owner, LifecycleFirst())
        (pause.point, pause.reached) = (point, first)
        let apply = Task {
            let result = await owner.beginApply(window: window)
            first.signal("completed")
            return result
        }
        guard await first.wait() == "reached" else {
            Issue.record("apply completed before \(point): \(await apply.value)")
            return nil
        }
        return apply
    }

    /// Joins `completion`'s early fence. If the fence queues for the owner lock first, records an issue
    /// and resumes the paused apply so that the fence, and the test, can finish.
    func fence(_ completion: HostWingLifecycle.Completion) async {
        let first = LifecycleFirst()
        pause.queued = { first.signal("queued") }
        Task {
            await completion.fenced()
            first.signal("fenced")
        }
        if await first.wait() != "fenced" {
            Issue.record("early fence queued for the owner lock")
            pause.resume.open()
        }
        await completion.fenced()
        pause.queued = nil
    }
}
