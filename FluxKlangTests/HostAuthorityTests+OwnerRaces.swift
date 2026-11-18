import Foundation
import Testing
@testable import FluxKlang

private typealias Owner = OwnerBench
private enum OwnerLeaseState: CaseIterable, Sendable { case free, ownWindow, unattached }
/// How the Studio lease stands before a close is queued behind lease work.
private enum OwnerCloseStart: CaseIterable, Sendable { case free, recovering, ownWindow, unattached }
private enum OwnerLifecycleEvent: Sendable { case queued, finished }
private let leasePoints: [HostAuthorityOwner.Checkpoint] = [.leaseRead, .leaseChecked, .leaseReady]
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
                    if initial == .unattached {
                        await owner.windowClosed(Owner.windowOne)
                        await owner.windowOpened(Owner.windowOne, generation: 0)
                    }
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
                if initial == .unattached {
                    await owner.windowClosed(Owner.windowOne)
                    await owner.windowOpened(Owner.windowOne, generation: 0)
                }
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

        @Test(arguments: OwnerLeaseState.allCases)
        fileprivate func closeBeforePausedApplyRefuses(initial: OwnerLeaseState) async throws {
            let (owner, pause) = try await Self.pausable()
            if initial != .free {
                _ = try await owner.beginApply(window: Owner.windowOne).get()
                if initial == .unattached {
                    await owner.windowClosed(Owner.windowOne)
                    await owner.windowOpened(Owner.windowOne, generation: 0)
                }
            }
            await pause.arm(.applyStarting)
            let apply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: apply) else { return }
            // The close completes while the apply is paused before the lock; nothing is attached yet.
            await owner.windowClosed(Owner.windowOne)
            await pause.resume()
            #expect(await apply.value == .failure(.windowClosed))
            let lease = await owner.authority.snapshot().lease
            if initial == .free {
                #expect(lease == nil)
            } else {
                #expect(try #require(lease).windows.isEmpty)
            }
        }

        @Test(arguments: OwnerCloseStart.allCases)
        fileprivate func closeQueuedDuringLeaseWork(start: OwnerCloseStart) async throws {
            for point in leasePoints {
                let (owner, pause) = try await Self.pausable()
                if start != .free { _ = try await owner.beginApply(window: Owner.windowOne).get() }
                if start == .unattached {
                    await owner.windowClosed(Owner.windowOne)
                    await owner.windowOpened(Owner.windowOne, generation: 0)
                }
                if start == .recovering {
                    _ = try await owner.dropped().get()
                    let verified = UUID()
                    await owner.connected(session: verified)
                    await owner.verifiedReconnect(session: verified)
                }
                await pause.arm(point)
                let apply = await pause.start(owner)
                guard await pause.waitUntilReached(orJoin: apply) else { return }
                let close = await Self.settle(pause, queues: true) { await owner.windowClosed(Owner.windowOne) }
                await pause.resume()
                #expect(await apply.value == .failure(.windowClosed))
                await close.value
                let after = await owner.authority.snapshot()
                let acquired = start == .ownWindow || start == .unattached || point != .leaseRead
                #expect(after.lease?.windows == (acquired ? [] : nil))
                // A fenced apply never completes the restore its acquire queued.
                #expect(after.outputsMuted == (start == .recovering))
                #expect(after.restoring?.delivered == (start == .recovering && acquired ? false : nil))
            }
        }

        @Test(arguments: [HostAuthorityOwner.Checkpoint.applyStarting] + leasePoints)
        func closingAnotherWindowDoesNotFence(point: HostAuthorityOwner.Checkpoint) async throws {
            let (owner, pause) = try await Self.pausable()
            let session = try #require(await owner.session)
            await pause.arm(point)
            let apply = await pause.start(owner, window: Owner.windowTwo)
            guard await pause.waitUntilReached(orJoin: apply) else { return }
            let close = await Self.settle(pause, queues: point != .applyStarting) {
                await owner.windowClosed(Owner.windowOne)
            }
            await pause.resume()
            #expect(await apply.value == .success(session))
            await close.value
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowTwo])
        }

        @Test(arguments: [HostAuthorityOwner.Checkpoint.applyStarting] + leasePoints)
        func reappearingRootReusesItsID(point: HostAuthorityOwner.Checkpoint) async throws {
            let (owner, pause) = try await Self.pausable()
            let session = try #require(await owner.session)
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            await pause.arm(point)
            let apply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: apply) else { return }
            let close = await Self.settle(pause, queues: point != .applyStarting) {
                await owner.windowClosed(Owner.windowOne)
            }
            await pause.resume()
            // Refusal timing is the subject of the close tests above; only the reuse after it matters here.
            _ = await apply.value
            await close.value
            // AppRootView keeps its WindowID across disappear/reappear: refused until it reopens.
            #expect(await owner.beginApply(window: Owner.windowOne) == .failure(.windowClosed))
            await owner.windowOpened(Owner.windowOne, generation: 0)
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowOne])
        }

        @Test(.timeLimit(.minutes(1)), arguments: [HostAuthorityOwner.Checkpoint.applyStarting] + leasePoints)
        func reopenDoesNotUnfenceEarlierApply(point: HostAuthorityOwner.Checkpoint) async throws {
            let (owner, pause) = try await Self.pausable()
            let session = try #require(await owner.session)
            await pause.arm(point)
            let apply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: apply) else { return }
            let close = await Self.settle(pause, queues: point != .applyStarting) {
                await owner.windowClosed(Owner.windowOne)
            }
            // The close's fence ran before it queued or returned; the reopen cannot unfence this apply.
            await owner.windowOpened(Owner.windowOne, generation: 0)
            await pause.resume()
            #expect(await apply.value == .failure(.windowClosed))
            await close.value
            #expect(await owner.beginApply(window: Owner.windowOne) == .success(session))
            #expect(await owner.authority.snapshot().lease?.windows == [Owner.windowOne])
        }

        @Test(arguments: [HostAuthorityOwner.Checkpoint.applyStarting] + leasePoints)
        func lossAndClosePrecedence(point: HostAuthorityOwner.Checkpoint) async throws {
            let (owner, pause) = try await Self.pausable()
            await pause.arm(point)
            let apply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: apply) else { return }
            let close = await Self.settle(pause, queues: point != .applyStarting) {
                await owner.windowClosed(Owner.windowOne)
            }
            // Joined only after the apply: a refusal must not leave it suspended.
            let loss = await Self.settle(pause, queues: point != .applyStarting) { await owner.disconnected() }
            await pause.resume()
            #expect(await apply.value == .failure(.noSession))
            await close.value
            _ = try await loss.value.get()
            #expect(await owner.authority.snapshot().lease == nil)
        }

        @Test
        func closeDuringRestoreAcknowledgementRefuses() async throws {
            let (owner, pause) = try await Self.pausable()
            _ = try await owner.beginApply(window: Owner.windowOne).get()
            _ = try await owner.dropped().get()
            let verified = UUID()
            await owner.connected(session: verified)
            await owner.verifiedReconnect(session: verified)
            await pause.arm(.restoreAcknowledging)
            let apply = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: apply) else { return }
            #expect(await owner.authority.snapshot().restoring?.delivered == true)
            let close = await Self.settle(pause, queues: true) { await owner.windowClosed(Owner.windowOne) }
            await pause.resume()
            #expect(await apply.value == .failure(.windowClosed))
            await close.value
            let after = await owner.authority.snapshot()
            // The restore was acknowledged before the final check refused the apply.
            #expect(after.restoring == nil && !after.outputsMuted)
            #expect(after.lease?.windows == [])
        }

        @Test
        func closeFencesEveryInFlightApplyOfItsWindow() async throws {
            let (owner, pause) = try await Self.pausable()
            await pause.arm(.leaseReady)
            let first = await pause.start(owner)
            guard await pause.waitUntilReached(orJoin: first) else { return }
            let second = await Self.settle(pause, queues: true) { await owner.beginApply(window: Owner.windowOne) }
            let close = await Self.settle(pause, queues: true) { await owner.windowClosed(Owner.windowOne) }
            await pause.resume()
            #expect(await first.value == .failure(.windowClosed))
            #expect(await second.value == .failure(.windowClosed))
            await close.value
            #expect(await owner.authority.snapshot().lease?.windows == [])
        }

        /// A granted, connected owner whose queued lifecycle calls are observable.
        private static func pausable() async throws -> (HostAuthorityOwner, OwnerApplyPause) {
            let pause = OwnerApplyPause()
            let owner = try HostAuthorityOwner(
                host: Owner.host, checkpoint: { await pause.visit($0) },
                lifecycleQueued: { pause.lifecycle.continuation.yield(.queued) }
            )
            _ = try await owner.grant(.host).get()
            await owner.connected(session: UUID())
            return (owner, pause)
        }

        /// Starts a lifecycle call and waits until it queues for the lock or returns, whichever is first.
        /// The unexpected outcome is recorded, never awaited, so the caller still resumes its paused apply.
        /// Assumes no other lifecycle events arrive meanwhile; a call that neither queues nor returns still hangs.
        private static func settle<T: Sendable>(_ pause: OwnerApplyPause, queues: Bool,
                                                _ call: @escaping @Sendable () async -> T) async -> Task<T, Never> {
            var events = pause.lifecycle.stream.makeAsyncIterator()
            let task = Task {
                let value = await call()
                pause.lifecycle.continuation.yield(.finished)
                return value
            }
            let queued = await events.next() == .queued
            if queued != queues { Issue.record("Lifecycle call \(queued ? "queued" : "returned") unexpectedly") }
            return task
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
    /// `.queued` each time an owner built by `pausable()` queues a lifecycle call; `.finished` when
    /// a call started by `settle` returns.
    nonisolated let lifecycle = AsyncStream<OwnerLifecycleEvent>.makeStream()

    func arm(_ point: HostAuthorityOwner.Checkpoint) { self.point = point }

    func start(_ owner: HostAuthorityOwner,
               window: WindowID = Owner.windowOne) -> Task<Result<UUID, HostAuthorityOwner.ApplyRefusal>, Never> {
        Task {
            let result = await owner.beginApply(window: window)
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
