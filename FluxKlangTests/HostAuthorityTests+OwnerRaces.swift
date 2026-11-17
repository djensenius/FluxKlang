import Foundation
import Testing
@testable import FluxKlang

private typealias Owner = OwnerBench
private enum OwnerLeaseState: CaseIterable, Sendable { case free, ownWindow, unattached }
private enum OwnerLoss: CaseIterable, Sendable {
    case disconnect, demo, drop

    func perform(on owner: HostAuthorityOwner) async -> Result<Void, HostAuthorityRefusal> {
        switch self {
        case .disconnect: await owner.disconnected()
        case .demo: await owner.enteredDemoMode()
        case .drop: await owner.dropped()
        }
    }
}

extension HostAuthorityTests {
    struct OwnerRaces {
        @Test(arguments: [false, true])
        func connectInvalidatesAPausedApply(reuseSession: Bool) async throws {
            let pause = OwnerApplyPause()
            let owner = try HostAuthorityOwner(host: Owner.host, checkpoint: { await pause.visit($0) })
            let session = UUID()
            await owner.connected(session: session)
            await pause.arm(.applyStarting)
            let oldApply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: oldApply) else { return }
            await owner.connected(session: reuseSession ? session : UUID())
            await pause.resume()
            #expect(await oldApply.value == .failure(.noSession))
            #expect(await owner.authority.snapshot().lease == nil)
        }

        @Test(arguments: OwnerLoss.allCases, OwnerLeaseState.allCases)
        fileprivate func lossDuringLeaseWork(kind: OwnerLoss, initial: OwnerLeaseState) async throws {
            for point in [HostAuthorityOwner.Checkpoint.leaseRead, .leaseChecked, .leaseReady] {
                let pause = OwnerApplyPause()
                let lossProgress = AsyncStream<Void>.makeStream()
                let owner = try HostAuthorityOwner(
                    host: Owner.host, checkpoint: { await pause.visit($0) },
                    lifecycleQueued: { lossProgress.continuation.yield(()) }
                )
                _ = try await owner.grant(.host).get()
                await owner.connected(session: UUID())
                if initial != .free {
                    _ = try await owner.beginApply(window: Owner.windowOne).get()
                    if initial == .unattached { await owner.windowClosed(Owner.windowOne) }
                }
                await pause.arm(point)
                let oldApply = await pause.start(owner)
                guard await pause.waitUntilReached(orJoin: oldApply) else { return }
                let loss = Task {
                    let result = await kind.perform(on: owner)
                    lossProgress.continuation.yield(())
                    return result
                }
                // With the gate, loss queues; without it, loss must finish before apply resumes.
                // Awaiting loss.value here would deadlock the correct implementation.
                var events = lossProgress.stream.makeAsyncIterator()
                _ = await events.next()
                #expect(await owner.session == nil)
                await pause.resume()
                #expect(await oldApply.value == .failure(.noSession))
                _ = try await loss.value.get()
                let stopped = await owner.authority.snapshot()
                #expect(stopped.lease == nil && stopped.queue.isEmpty && stopped.restoring == nil)
                let recovering = kind == .drop && (initial != .free || point != .leaseRead)
                #expect(stopped.outputsMuted == recovering)
                #expect(stopped.pendingOutput == (recovering ? true : nil))
                #expect(await owner.authority.lifecycle(of: owner.studio, window: Owner.windowOne)
                        == (recovering ? .recovering : .stopped))
                #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.noSession))

                let replacement = UUID()
                await owner.connected(session: replacement)
                #expect(await owner.beginApply(window: Owner.windowTwo) == .success(replacement))
                if recovering {
                    #expect(Owner.refusal(try await Owner.admit(owner, Owner.windowTwo))
                            == .gate(.unavailable(.recovering)))
                    await owner.verifiedReconnect(session: replacement)
                }
                let ticket = try await Owner.ticket(owner, Owner.windowTwo)
                #expect(Owner.refusal(await owner.authority.redeemDirect(ticket)) == nil)
            }
        }

        @Test(arguments: [false, true], OwnerLeaseState.allCases)
        fileprivate func staleApplyCannotReleaseAReplacement(demo: Bool, initial: OwnerLeaseState) async throws {
            let pause = OwnerApplyPause()
            let owner = try HostAuthorityOwner(host: Owner.host, checkpoint: { await pause.visit($0) })
            _ = try await owner.grant(.host).get()
            let session = UUID()
            await owner.connected(session: session)
            if initial != .free {
                _ = try await owner.beginApply(window: Owner.windowOne).get()
                if initial == .unattached { await owner.windowClosed(Owner.windowOne) }
            }
            await pause.arm(.applyStarting)
            let oldApply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: oldApply) else { return }
            // Nothing throws until the paused task has been resumed and joined.
            let loss = await (demo ? OwnerLoss.demo : .disconnect).perform(on: owner)
            #expect(await owner.authority.snapshot().lease == nil)
            // Even reuse of the caller's session UUID must not revive an old apply.
            await owner.connected(session: session)
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
            let replacement = await owner.authority.snapshot()
            let ticket: Result<DirectWriteTicket?, DirectWriteRefusal>?
            if let admission = await owner.admission() {
                ticket = await Owner.admit(owner, Owner.windowOne, admission)
            } else {
                ticket = nil
            }
            await pause.resume()
            #expect(await oldApply.value == .failure(.noSession))
            _ = try loss.get()
            let after = await owner.authority.snapshot()
            #expect(after.lease == replacement.lease && after.lease?.windows == [Owner.windowOne])
            #expect(AuthorityBench.context(after) == AuthorityBench.context(replacement))
            let admitted = try #require(ticket)
            let fresh = try #require(try admitted.get())
            #expect(Owner.refusal(await owner.authority.redeemDirect(fresh)) == nil)
        }
    }
}

/// One armed checkpoint suspends exactly one apply; all handshakes use continuations, not time.
private actor OwnerApplyPause {
    private enum Event {
        case reached
        case completed
    }
    private var point: HostAuthorityOwner.Checkpoint?
    private var continuation: CheckedContinuation<Void, Never>?
    private let events = AsyncStream<Event>.makeStream()

    func arm(_ point: HostAuthorityOwner.Checkpoint) { self.point = point }

    func start(_ owner: HostAuthorityOwner) -> Task<Result<UUID, HostAuthorityOwner.ApplyRefusal>, Never> {
        Task {
            let result = await owner.beginApply(window: Owner.windowOne)
            events.continuation.yield(.completed)
            return result
        }
    }

    func visit(_ point: HostAuthorityOwner.Checkpoint) async {
        guard self.point == point else { return }
        self.point = nil
        await withCheckedContinuation {
            continuation = $0
            events.continuation.yield(.reached)
        }
    }

    func waitUntilReached(orJoin task: Task<Result<UUID, HostAuthorityOwner.ApplyRefusal>, Never>) async -> Bool {
        var iterator = events.stream.makeAsyncIterator()
        if case .reached = await iterator.next() { return true }
        resume()
        let result = await task.value
        Issue.record("Apply completed before checkpoint \(String(describing: point)): \(result)")
        return false
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
