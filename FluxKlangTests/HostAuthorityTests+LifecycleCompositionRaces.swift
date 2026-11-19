import Foundation
import Observation
import Testing
@testable import FluxKlang

private typealias Lifecycle = HostWingLifecycle
private typealias Bench = LifecycleOwnerBench

enum LifecycleCancellationPhase: CaseIterable, Sendable {
    case release, oldStop, candidateStart, beforePublication, afterPublication
}

extension HostAuthorityTests {
    @MainActor
    struct LifecycleCompositionRaces {
        @Test func cancelledQueuedReplacementWaitsItsTurnWithoutTeardown() async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let entered = LifecycleGate()
            let release = LifecycleGate()
            let queued = LifecycleGate()
            let first = Task {
                await lifecycle.replace {
                    probe.operation(.success(.demo), hooks: .init(start: {
                        entered.open()
                        await release.wait()
                    }))
                }
            }
            await entered.wait()
            let cancelled = Task {
                queued.open()
                return await lifecycle.replace { probe.operation(.success(.connected(UUID()))) }
            }
            await queued.wait()
            cancelled.cancel()
            let next = Task { await lifecycle.replace { probe.operation(.success(.disconnected)) } }
            #expect(probe.captured.count == 1 && probe.started == 1)
            #expect(lifecycle.lastReplacementOutcome == nil)
            release.open()
            #expect(await first.value == .success(.demo))
            #expect(await cancelled.value == .failure(.cancelled))
            #expect(await next.value == .success(.disconnected))
            #expect(probe.captured.count == 2 && probe.started == 2 && probe.stopped == 0)
            #expect(!lifecycle.isBusy)
        }

        @Test(arguments: LifecycleCancellationPhase.allCases)
        func cancellationRespectsCleanupAndPublicationBoundary(phase: LifecycleCancellationPhase) async throws {
            let owner = try HostAuthorityOwner(sessionInvalidated: {
                if phase == .release { withUnsafeCurrentTask { $0?.cancel() } }
            })
            _ = try await owner.opened.value.get()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let session = UUID()
            var checks = 0
            let operation = Task {
                await lifecycle.replace {
                    probe.operation(.success(.connected(session)), hooks: .init(oldStop: {
                        if phase == .oldStop { withUnsafeCurrentTask { $0?.cancel() } }
                    }, start: {
                        if phase == .candidateStart { withUnsafeCurrentTask { $0?.cancel() } }
                    }, current: {
                        checks += 1
                        if (phase == .beforePublication && checks == 1)
                            || (phase == .afterPublication && checks == 2) {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                        return true
                    }))
                }
            }
            let outcome = await operation.value
            let committed = phase == .afterPublication
            #expect(outcome == (committed ? .success(.connected(session)) : .failure(.cancelled)))
            #expect(probe.events.contains("old-stopped"))
            #expect(probe.assigned == (phase == .release || phase == .oldStop ? 0 : 1))
            #expect(probe.stopped == (phase == .candidateStart || phase == .beforePublication ? 1 : 0))
            #expect(probe.finished == (committed ? 1 : 0))
            #expect(await owner.session == (committed ? session : nil))
            await lifecycle.detach(Bench.window).wait()
            #expect(!lifecycle.isBusy)
        }

        @Test(arguments: [false, true])
        func initialRefusalWinsConcurrentCancellation(cancelDuringRelease: Bool) async throws {
            let owner = try HostAuthorityOwner(sessionInvalidated: {
                if cancelDuringRelease { withUnsafeCurrentTask { $0?.cancel() } }
            })
            _ = try await owner.opened.value.get()
            let held = try await Bench.holdOther(owner)
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let task = Task {
                await lifecycle.replace {
                    probe.operation(.success(.demo), hooks: .init(oldStop: {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }))
                }
            }
            let outcome = await task.value
            #expect(outcome == .failure(.initialRelease(.lease(.heldByOtherProject(Bench.other)))))
            #expect(outcome.failureMessage == """
                The previous connection was stopped. No replacement was started because host release was refused.
                """)
            #expect(probe.events == ["old-stop", "old-stopped"])
            #expect(probe.assigned == 0 && probe.started == 0 && probe.finished == 0)
            #expect(await owner.authority.snapshot().lease == held)
            #expect(await owner.session == nil)
            await lifecycle.detach(WindowID(validated: "win.unattached")).wait()
            #expect(!lifecycle.isBusy && lifecycle.lastReplacementOutcome == outcome)
        }

        @Test func assignmentObservationCancellationDoesNotStartAndJoinsCleanup() async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let stopping = LifecycleGate()
            let release = LifecycleGate()
            withObservationTracking {
                _ = probe.identity
            } onChange: {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let task = Task {
                await lifecycle.replace {
                    probe.operation(.success(.connected(UUID())), hooks: .init(stop: {
                        stopping.open()
                        await release.wait()
                    }))
                }
            }
            await stopping.wait()
            #expect(probe.assigned == 1 && probe.started == 0 && probe.stopped == 1)
            #expect(lifecycle.isBusy && lifecycle.lastReplacementOutcome == nil)
            #expect(await owner.session == nil)
            release.open()
            #expect(await task.value == .failure(.cancelled))
            #expect(probe.events.last == "candidate-stopped" && probe.finished == 0)
            #expect(!lifecycle.isBusy)
        }

        @Test func activeCancellationWaitsForCapturedOldStop() async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let stopping = LifecycleGate()
            let release = LifecycleGate()
            let task = Task {
                await lifecycle.replace {
                    probe.operation(.success(.demo), hooks: .init(oldStop: {
                        stopping.open()
                        await release.wait()
                    }))
                }
            }
            await stopping.wait()
            task.cancel()
            let queued = lifecycle.detach(Bench.window)
            #expect(probe.events == ["old-stop"])
            #expect(lifecycle.isBusy && lifecycle.lastReplacementOutcome == nil)
            release.open()
            #expect(await task.value == .failure(.cancelled))
            await queued.wait()
            #expect(probe.events == ["old-stop", "old-stopped"])
            #expect(probe.assigned == 0 && !lifecycle.isBusy)
        }

        @Test(arguments: [false, true])
        func candidateCancellationJoinsStopBeforeNextTurn(connectionFailed: Bool) async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let starting = LifecycleGate()
            let releaseStart = LifecycleGate()
            let stopping = LifecycleGate()
            let releaseStop = LifecycleGate()
            let apparent: Lifecycle.Outcome = connectionFailed
                ? .failure(.connection("failure loses to cancellation")) : .success(.connected(UUID()))
            let task = Task {
                await lifecycle.replace {
                    probe.operation(apparent, hooks: .init(start: {
                        starting.open()
                        await releaseStart.wait()
                    }, stop: {
                        stopping.open()
                        await releaseStop.wait()
                    }))
                }
            }
            await starting.wait()
            task.cancel()
            releaseStart.open()
            await stopping.wait()
            let queued = Task { await lifecycle.replace { probe.operation(.success(.disconnected)) } }
            #expect(probe.captured.count == 1 && probe.stopped == 1 && probe.finished == 0)
            #expect(await owner.session == nil)
            #expect(lifecycle.lastReplacementOutcome == nil)
            releaseStop.open()
            #expect(await task.value == .failure(.cancelled))
            #expect(await queued.value == .success(.disconnected))
            #expect(probe.events == ["old-stop", "old-stopped", "start", "candidate-stop", "candidate-stopped",
                                      "old-stop", "old-stopped", "start", "finish"])
            #expect(!lifecycle.isBusy)
        }

        @Test func busyNotificationDetachCannotOvertakeReplacement() async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            var acquired: EngineLeaseSnapshot?
            withObservationTracking {
                _ = lifecycle.isBusy
            } onChange: {
                MainActor.assumeIsolated {
                    probe.completions.append(lifecycle.detach(Bench.window))
                }
            }
            _ = await lifecycle.replace {
                probe.operation(.success(.demo), hooks: .init(start: {
                    do { acquired = try await Bench.holdStudio(owner) } catch { Issue.record(error) }
                }))
            }
            for completion in probe.completions { await completion.wait() }
            #expect(probe.completions.count == 1)
            let after = await owner.authority.snapshot()
            #expect(acquired != nil && after.lease?.token == acquired?.token)
            #expect(after.lease?.windows.isEmpty == true)
            #expect(lifecycle.lastReplacementOutcome == .success(.demo) && !lifecycle.isBusy)
        }

        @Test(arguments: [false, true])
        func reportAndBusyResetReentryRetainsReservation(observeReset: Bool) async throws {
            let owner = try await Bench.owner()
            let lifecycle = Lifecycle(owner: owner)
            let probe = LifecycleProbe()
            let entered = LifecycleGate()
            let release = LifecycleGate()
            let task = Task {
                await lifecycle.replace {
                    probe.operation(.failure(.connection("keep this report")), hooks: .init(start: {
                        do { _ = try await Bench.holdStudio(owner) } catch { Issue.record(error) }
                        entered.open()
                        await release.wait()
                    }))
                }
            }
            await entered.wait()
            withObservationTracking {
                if observeReset { _ = lifecycle.isBusy } else { _ = lifecycle.lastReplacementOutcome }
            } onChange: {
                MainActor.assumeIsolated {
                    probe.completions.append(lifecycle.detach(Bench.window))
                }
            }
            release.open()
            let outcome = await task.value
            for completion in probe.completions { await completion.wait() }
            #expect(probe.completions.count == 1)
            #expect(await owner.authority.snapshot().lease?.windows.isEmpty == true)
            #expect(outcome == .failure(.connection("keep this report")))
            #expect(lifecycle.lastReplacementOutcome == outcome && !lifecycle.isBusy)
            #expect(await lifecycle.replace { probe.operation(.success(.disconnected)) } == .success(.disconnected))
        }

        @Test func ownerNilDefaultSerializesWithoutHiddenAuthority() async {
            let lifecycle = Lifecycle()
            let probe = LifecycleProbe()
            #expect(lifecycle.owner == nil)
            _ = await lifecycle.replace { probe.operation(.success(.acceptanceFailure)) }
            let completion = lifecycle.detach(Bench.window)
            let opened = lifecycle.open(Bench.window)
            #expect(lifecycle.isBusy)
            await completion.fenced()
            await opened.fenced()
            await completion.wait()
            await opened.wait()
            #expect(lifecycle.lastReplacementOutcome == .success(.acceptanceFailure))
            #expect(!lifecycle.isBusy && probe.finished == 1)
        }

        @Test(.timeLimit(.minutes(1))) func queuedOpenFollowsDetachOnItsTurn() async throws {
            let held = try await LifecycleHeldTurn()
            let detach = held.lifecycle.detach(Bench.window)
            let reopen = held.lifecycle.open(Bench.window)
            await held.fence(detach)
            await reopen.fenced()
            // Both wait behind the replacement, so the reopen cannot overtake the queued detach.
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            #expect(held.lifecycle.isBusy)
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await reopen.wait()
            await detach.wait()
            #expect(await held.owner.beginApply(window: Bench.window) == .success(held.session))
            #expect(await held.owner.authority.snapshot().lease?.windows == [Bench.window])
            // A later detach closes it again, and it stays closed after that detach completes.
            await held.lifecycle.detach(Bench.window).wait()
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            #expect(await held.owner.authority.snapshot().lease?.windows == [])
            #expect(!held.lifecycle.isBusy)
        }

        @Test(.timeLimit(.minutes(1))) func laterDetachKeepsEarlierOpenFromReopening() async throws {
            let held = try await LifecycleHeldTurn()
            let (probe, later, queued, holding, hold) = (LifecycleProbe(), UUID(), LifecycleGate(), LifecycleGate(),
                                                        LifecycleGate())
            let reopen = held.lifecycle.open(Bench.window)
            // A second replacement queued between them holds the turn after the open's and before the detach's.
            let replacement = Task {
                queued.open()
                return await held.lifecycle.replace {
                    probe.operation(.success(.connected(later)), hooks: .init(finish: {
                        holding.open()
                        await hold.wait()
                    }))
                }
            }
            await queued.wait()
            let detach = held.lifecycle.detach(Bench.window)
            await held.fence(detach)
            held.release.open()
            await reopen.wait()
            await holding.wait()
            // The open's turn ran before the detach's, but the detach was submitted later, so the root stays closed.
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            hold.open()
            #expect(await replacement.value == .success(.connected(later)))
            await detach.wait()
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            #expect(!held.lifecycle.isBusy)
        }

        @Test(.timeLimit(.minutes(1))) func openAfterLaterDetachReopens() async throws {
            let held = try await LifecycleHeldTurn()
            let first = held.lifecycle.open(Bench.window)
            let detach = held.lifecycle.detach(Bench.window)
            let second = held.lifecycle.open(Bench.window)
            await held.fence(detach)
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
            await first.wait()
            await detach.wait()
            await second.wait()
            // Only the open submitted after the detach reopens the root.
            #expect(await held.owner.beginApply(window: Bench.window) == .success(held.session))
            #expect(await held.owner.authority.snapshot().lease?.windows == [Bench.window])
        }

        @Test(.timeLimit(.minutes(1))) func staleOpenHopLeavesLaterFenceClosed() async throws {
            let held = try await LifecycleHeldTurn()
            // An open captured generation 1 at submission; detach 2 was submitted next and its fence
            // reached the owner before the open's hop did. Actor jobs need not run in submission order.
            await held.owner.fenceApplies(for: Bench.window, generation: 1)
            await held.owner.fenceApplies(for: Bench.window, generation: 2)
            await held.owner.windowOpened(Bench.window, generation: 1)
            // The replacement still holds the turn, so detach 2's own turn has not closed the root again.
            #expect(held.lifecycle.isBusy)
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            await held.owner.windowOpened(Bench.window, generation: 2)
            #expect(await held.owner.beginApply(window: Bench.window) == .success(held.session))
            held.release.open()
            #expect(await held.replacement.value == .success(.connected(held.session)))
        }

        @Test(.timeLimit(.minutes(1))) func earlierCloseKeepsLaterGeneration() async throws {
            let held = try await LifecycleHeldTurn()
            let (releaseFirst, releaseSecond) = (LifecycleGate(), LifecycleGate())
            let firstDetach = held.lifecycle.detach(Bench.window)
            let first = await held.queueHold(until: releaseFirst)
            let secondDetach = held.lifecycle.detach(Bench.window)
            await held.fence(firstDetach)
            await held.fence(secondDetach)
            held.release.open()
            await firstDetach.wait()
            await first.holding.wait()
            #expect(await held.owner.closureGenerations == [Bench.window: 2])
            // Submitted after detach 2: the generations it and detach 3 carry never restart.
            let reopen = held.lifecycle.open(Bench.window)
            let second = await held.queueHold(until: releaseSecond)
            let thirdDetach = held.lifecycle.detach(Bench.window)
            await held.fence(thirdDetach)
            releaseFirst.open()
            await reopen.wait()
            await second.holding.wait()
            // Detach 2's close did not release detach 3's fence, so the earlier open stayed stale.
            #expect(await held.owner.closureGenerations == [Bench.window: 3])
            #expect(await held.owner.beginApply(window: Bench.window) == .failure(.windowClosed))
            releaseSecond.open()
            await thirdDetach.wait()
            _ = await first.task.value
            _ = await second.task.value
            #expect(await held.owner.closureGenerations.isEmpty && !held.lifecycle.isBusy)
        }
    }
}
