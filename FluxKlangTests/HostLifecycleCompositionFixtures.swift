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
