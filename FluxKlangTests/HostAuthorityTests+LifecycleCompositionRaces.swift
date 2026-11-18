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
            await lifecycle.detach(Bench.window).wait()
            #expect(lifecycle.lastReplacementOutcome == .success(.acceptanceFailure))
            #expect(!lifecycle.isBusy && probe.finished == 1)
        }
    }
}
