import Foundation
import Testing
@testable import FluxKlang

private typealias Lifecycle = HostWingLifecycle
private typealias Bench = LifecycleOwnerBench

extension HostAuthorityTests {
    @MainActor
    struct LifecycleComposition {
        @Test(arguments: [false, true])
        func fifoCapturesOldOnlyOnTurn(disconnect: Bool) async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let firstSession = UUID()
            let secondSession = UUID()
            let starting = LifecycleGate()
            let release = LifecycleGate()
            let queued = LifecycleGate()
            let original = probe.identity
            let first = Task {
                await lifecycle.replace {
                    probe.operation(.success(.connected(firstSession)), hooks: .init(oldStop: {
                        starting.open()
                        await release.wait()
                    }))
                }
            }
            await starting.wait()
            let secondOutcome: Lifecycle.Outcome = disconnect
                ? .success(.disconnected) : .success(.connected(secondSession))
            let second = Task {
                queued.open()
                return await lifecycle.replace { probe.operation(secondOutcome) }
            }
            await queued.wait()
            #expect(probe.captured == [original])
            #expect(probe.events == ["old-stop"])
            #expect(await owner.session == nil)
            release.open()
            #expect(await first.value == .success(.connected(firstSession)))
            #expect(await second.value == secondOutcome)
            #expect(probe.captured == [original, firstSession])
            #expect(probe.events == ["old-stop", "old-stopped", "start", "finish",
                                      "old-stop", "old-stopped", "start", "finish"])
            #expect(await owner.session == (disconnect ? nil : secondSession))
            #expect(await owner.permission == nil)
            let snapshot = await owner.authority.snapshot()
            #expect(snapshot.lease == nil && snapshot.queue.isEmpty && snapshot.restoring == nil)
            #expect(!lifecycle.isBusy)
        }

        @Test func initialRefusalStopsOldAndAdvancesQueueWithoutConstructing() async throws {
            let owner = try await Bench.owner()
            let held = try await Bench.holdOther(owner)
            await owner.connected(session: UUID())
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let original = probe.identity
            let stopping = LifecycleGate()
            let release = LifecycleGate()
            let first = Task {
                await lifecycle.replace {
                    probe.operation(.success(.demo), hooks: .init(oldStop: {
                        stopping.open()
                        await release.wait()
                    }))
                }
            }
            await stopping.wait()
            let completion = lifecycle.detach(WindowID(validated: "win.unattached"))
            #expect(await owner.session == nil)
            #expect(probe.assigned == 0 && probe.started == 0)
            release.open()
            let expected: Lifecycle.Outcome = .failure(.initialRelease(.lease(.heldByOtherProject(Bench.other))))
            #expect(await first.value == expected)
            await completion.wait()
            #expect(probe.identity == original && probe.events == ["old-stop", "old-stopped"])
            #expect(probe.assigned == 0 && probe.finished == 0)
            #expect(await owner.authority.snapshot().lease == held)
            #expect(lifecycle.lastReplacementOutcome == expected)
            #expect(!lifecycle.isBusy)
            _ = try await owner.authority.release(project: Bench.other).get()
            #expect(await lifecycle.replace { probe.operation(.success(.disconnected)) } == .success(.disconnected))
        }

        @Test func publishedMismatchRetainsCleanupRefusalAndActualSessionEvidence() async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let session = UUID()
            let stopped = LifecycleGate()
            let release = LifecycleGate()
            var checks = 0
            var held: EngineLeaseSnapshot?
            var published: UUID?
            let first = Task {
                await lifecycle.replace {
                    probe.operation(.success(.connected(session)), hooks: .init(start: {
                        do { held = try await Bench.holdOther(owner) } catch { Issue.record(error) }
                    }, current: {
                        checks += 1
                        return checks == 1
                    }, stop: {
                        published = await owner.session
                        stopped.open()
                        await release.wait()
                    }))
                }
            }
            await stopped.wait()
            first.cancel()
            let completion = lifecycle.detach(WindowID(validated: "win.unattached"))
            #expect(published == session)
            #expect(probe.assigned == 1 && probe.started == 1 && probe.stopped == 1)
            release.open()
            let outcome = await first.value
            await completion.wait()
            #expect(outcome == .failure(.publishedIdentityChanged(
                cleanupRefusal: .lease(.heldByOtherProject(Bench.other)))))
            #expect(outcome.failureMessage == """
                A replacement connection was published, then stopped after its identity changed. \
                Host-session cleanup was refused.
                """)
            #expect(await owner.session == nil)
            #expect(held != nil)
            #expect(await owner.authority.snapshot().lease == held)
            #expect(probe.finished == 0 && probe.events.last == "candidate-stopped")
            #expect(lifecycle.lastReplacementOutcome == outcome && !lifecycle.isBusy)
            _ = try await owner.authority.release(project: Bench.other).get()
            #expect(await lifecycle.replace { probe.operation(.success(.demo)) } == .success(.demo))
        }

        @Test(arguments: [false, true])
        func refusalWithoutWaitersResetsBusyAfterCompletion(published: Bool) async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let original = probe.identity
            let session = UUID()
            await owner.connected(session: UUID())
            var held: EngineLeaseSnapshot?
            if !published { held = try await Bench.holdOther(owner) }
            var checks = 0
            var observedSession: UUID?
            let refusal: HostAuthorityRefusal = .lease(.heldByOtherProject(Bench.other))
            let expected: Lifecycle.Outcome = published
                ? .failure(.publishedIdentityChanged(cleanupRefusal: refusal)) : .failure(.initialRelease(refusal))
            let outcome = await lifecycle.replace {
                probe.operation(.success(.connected(session)), hooks: .init(start: {
                    do { held = try await Bench.holdOther(owner) } catch { Issue.record(error) }
                }, current: {
                    checks += 1
                    return checks == 1
                }, stop: {
                    observedSession = await owner.session
                }))
            }
            #expect(outcome == expected)
            #expect(lifecycle.lastReplacementOutcome == expected)
            #expect(!lifecycle.isBusy)
            #expect(await owner.session == nil)
            #expect(probe.assigned == (published ? 1 : 0))
            #expect(probe.started == (published ? 1 : 0))
            #expect(probe.stopped == (published ? 1 : 0) && probe.finished == 0)
            #expect(checks == (published ? 2 : 0))
            #expect(observedSession == (published ? session : nil))
            #expect(probe.identity == (published ? session : original))
            #expect(probe.events == (published
                ? ["old-stop", "old-stopped", "start", "candidate-stop", "candidate-stopped"]
                : ["old-stop", "old-stopped"]))
            #expect(held != nil)
            #expect(await owner.authority.snapshot().lease == held)
            _ = try await owner.authority.release(project: Bench.other).get()
            #expect(await owner.authority.snapshot().lease == nil)
        }

        @Test(arguments: [false, true])
        func failedOrStaleCandidateNeverPublishes(stale: Bool) async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let requested: Lifecycle.Outcome = stale
                ? .success(.connected(UUID())) : .failure(.connection("Detailed failure"))
            let outcome = await lifecycle.replace {
                probe.operation(requested, hooks: .init(current: { !stale }))
            }
            #expect(outcome == (stale ? .failure(.superseded) : requested))
            #expect(await owner.session == nil)
            #expect(await owner.permission == nil)
            #expect(probe.stopped == (stale ? 1 : 0) && probe.finished == 0)
            #expect(await owner.authority.snapshot().queue.isEmpty)
        }

        @Test func plannedReleaseFencesTicketsAndGrantsWithoutEngineWork() async throws {
            let owner = try await Bench.owner()
            _ = try await Bench.holdStudio(owner)
            let ticket = try await Bench.ticket(owner)
            let grant = try await Bench.minter(owner).grant(for: .safety, targets: [Bench.target]).get()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            #expect(await lifecycle.replace { probe.operation(.success(.demo)) } == .success(.demo))
            #expect(Bench.refusal(await owner.authority.redeemDirect(ticket)) == .staleLease)
            #expect(!grant.isArmed)
            let snapshot = await owner.authority.snapshot()
            #expect(snapshot.lease == nil && snapshot.queue.isEmpty && !snapshot.outputsMuted)
            #expect(snapshot.pendingOutput == nil && snapshot.restoring == nil)
        }

        @Test func existingRecoveryIsNotFalselyCleared() async throws {
            let owner = try await Bench.owner()
            let lease = try await Bench.holdStudio(owner)
            _ = try await owner.authority.leaseLost(lease.token).get()
            let before = await owner.authority.snapshot()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            _ = await lifecycle.replace { probe.operation(.success(.connected(UUID()))) }
            let after = await owner.authority.snapshot()
            #expect(before.outputsMuted && after.outputsMuted)
            #expect(after.queue == before.queue && after.restoring == before.restoring)
            #expect(await owner.authority.lifecycle(of: owner.studio, window: Bench.window) == .recovering)
        }

        @Test func detachRetainsLeaseDropsTicketsAndSurvivesReferenceLoss() async throws {
            let owner = try await Bench.owner()
            let lease = try await Bench.holdStudio(owner)
            let ticket = try await Bench.ticket(owner)
            let completion = Lifecycle(owner: owner).detach(Bench.window)
            await completion.wait()
            let after = await owner.authority.snapshot()
            #expect(after.lease?.token == lease.token && after.lease?.windows.isEmpty == true)
            #expect(Bench.refusal(await owner.authority.redeemDirect(ticket)) == .notOutstanding)
            #expect(after.queue.isEmpty)
        }

        @Test(.timeLimit(.minutes(1)),
              arguments: [HostAuthorityOwner.Checkpoint.applyStarting, .leaseRead, .leaseChecked, .leaseReady])
        func queuedDetachFencesPausedApply(point: HostAuthorityOwner.Checkpoint) async throws {
            let held = try await LifecycleHeldTurn()
            guard let apply = await held.pausedApply(Bench.window, at: point) else { return }
            let completion = held.lifecycle.detach(Bench.window)
            await held.fence(completion)
            #expect(held.lifecycle.isBusy)
            held.pause.resume.open()
            #expect(await apply.value == .failure(.windowClosed))
            // Paused past the lease check, it acquired before its recheck and stays attached until the turn.
            let attached = point == .leaseChecked || point == .leaseReady
            #expect(await held.owner.authority.snapshot().lease?.windows == (attached ? [Bench.window] : nil))
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await completion.wait()
            #expect(await held.owner.authority.snapshot().lease?.windows == (attached ? [] : nil))
            #expect(await held.owner.session == held.session && !held.lifecycle.isBusy)
        }

        @Test(.timeLimit(.minutes(1))) func earlyFenceKeepsDetachOnItsTurn() async throws {
            let held = try await LifecycleHeldTurn()
            #expect(await held.owner.beginApply(window: Bench.window) == .success(held.session))
            let completion = held.lifecycle.detach(Bench.window)
            await held.fence(completion)
            // Only the fence ran early: the window stays attached while the replacement holds the turn.
            #expect(await held.owner.authority.snapshot().lease?.windows == [Bench.window])
            #expect(held.lifecycle.isBusy)
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await completion.wait()
            #expect(await held.owner.authority.snapshot().lease?.windows == [])
            #expect(!held.lifecycle.isBusy)
        }

        @Test(.timeLimit(.minutes(1))) func queuedDetachDoesNotFenceAnotherWindow() async throws {
            let held = try await LifecycleHeldTurn()
            let other = WindowID(validated: "win.other")
            await held.owner.windowOpened(other, generation: 0)
            guard let apply = await held.pausedApply(other, at: .applyStarting) else { return }
            let completion = held.lifecycle.detach(Bench.window)
            await held.fence(completion)
            held.pause.resume.open()
            #expect(await apply.value == .success(held.session))
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await completion.wait()
            #expect(await held.owner.authority.snapshot().lease?.windows == [other])
        }

        @Test(.timeLimit(.minutes(1))) func reappearedRootAppliesOnlyAfterReopen() async throws {
            let held = try await LifecycleHeldTurn()
            let completion = held.lifecycle.detach(Bench.window)
            await held.fence(completion)
            // The fence closes the root: an apply after it is refused and attaches nothing.
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            #expect(await held.owner.authority.snapshot().lease?.windows == nil)
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await completion.wait()
            // AppRootView keeps its WindowID across disappear/reappear; it applies only once reopened.
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            await held.lifecycle.open(Bench.window).wait()
            #expect(await held.owner.beginApply(window: Bench.window) == .success(held.session))
            #expect(await held.owner.authority.snapshot().lease?.windows == [Bench.window])
        }

        @Test func openDetachCyclesReleaseWindowState() async throws {
            let owner = try await Bench.owner()
            let session = UUID()
            await owner.connected(session: session)
            let lifecycle = Lifecycle(owner: owner)
            #expect(await owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            let others = (0..<3).map { _ in WindowID(uuid: UUID()) }
            for window in [Bench.window, Bench.window] + others {
                await lifecycle.open(window).wait()
                #expect(await owner.openWindows == [window])
                #expect(await owner.beginApply(window: window) == .success(session))
                await lifecycle.detach(window).wait()
                // Closed with no lifecycle work left: refused, and the owner keeps nothing for it.
                #expect(await owner.beginApply(window: window) == .failure(.windowClosed))
                #expect(await owner.openWindows.isEmpty)
                #expect(await owner.closureGenerations.isEmpty)
            }
            #expect(!lifecycle.isBusy)
        }

        @Test(.timeLimit(.minutes(1))) func staleOpenAfterPruningCannotReopen() async throws {
            let held = try await LifecycleHeldTurn()
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await held.lifecycle.detach(Bench.window).wait()
            #expect(await held.owner.closureGenerations.isEmpty)
            let (releaseFirst, releaseSecond) = (LifecycleGate(), LifecycleGate())
            let first = await held.queueHold(until: releaseFirst)
            let reopen = held.lifecycle.open(Bench.window)
            let second = await held.queueHold(until: releaseSecond)
            let detach = held.lifecycle.detach(Bench.window)
            await held.fence(detach)
            #expect(await held.owner.closureGenerations == [Bench.window: 2])
            releaseFirst.open()
            await reopen.wait()
            await second.holding.wait()
            // The open was submitted before the later detach, whose fence landed first: the root stays closed.
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            releaseSecond.open()
            _ = await first.task.value
            _ = await second.task.value
            await detach.wait()
            #expect(await held.owner.closureGenerations.isEmpty)
            // Reopening after pruning works.
            await held.lifecycle.open(Bench.window).wait()
            #expect(await held.owner.beginApply(window: Bench.window) == .success(held.session))
        }

        @Test func historicalSuccessNeverAuthorizesAndMinterReadsFreshPermission() async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            _ = await lifecycle.replace { probe.operation(.success(.connected(UUID()))) }
            #expect(await owner.permission == nil)
            #expect(await owner.authority.snapshot().lease == nil)
            _ = try await Bench.holdStudio(owner)
            let minter = Bench.minter(owner)
            let first = try await minter.grant(for: .safety, targets: [Bench.target]).get()
            await owner.revoke()
            #expect(!first.isArmed)
            let refusal = Bench.refusal(await minter.grant(for: .remaining, targets: [Bench.target]))
            #expect(refusal == .gate(.refused(.rejected(.permissionDenied))))
            #expect(lifecycle.lastReplacementOutcome?.succeeded == true)
            _ = try await owner.grant(.host).get()
            let fresh = try await minter.grant(for: .retry, targets: [Bench.target]).get()
            #expect(fresh.isArmed)
            fresh.relinquish()
        }
    }
}
