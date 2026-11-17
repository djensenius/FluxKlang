import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"

/// The epoch the provider reports, and how many times it was asked.
private final class EpochSource: Sendable {
    private let state: Mutex<(epoch: HostEpoch, calls: Int)>

    init(_ epoch: HostEpoch) {
        state = Mutex((epoch, 0))
    }

    var calls: Int { state.withLock { $0.calls } }

    func set(_ epoch: HostEpoch) {
        state.withLock { $0.epoch = epoch }
    }

    func next() -> HostEpoch {
        state.withLock {
            $0.calls += 1
            return $0.epoch
        }
    }
}

extension HostAuthorityTests {
    /// AU7b: the production `WingApplyGrantMinter` admits a fresh `.bind(applyRoute)`
    /// ticket for each chunk and spends it on exactly that chunk, on a real
    /// authority under `WingDirectSendScope`. Fakes only; nothing reaches a socket.
    @MainActor
    struct WingApplyMinter {
        private func connected(_ transport: EchoingDirectTransport) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        private func someTargets() throws -> [DirectSendTarget] {
            WingApplyBench.targets(try WingApplyBench.settings(3))
        }

        private func assertNothingArmed(_ authority: HostAuthority) async {
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await authority.outstandingDirectWriteCount() == 0)
        }

        @Test func aHappyApplyMintsOneTicketPerChunk() async throws {
            let authority = try await WingApplyBench.authority()
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try WingApplyBench.settings(300)
            let safety = Array(settings[..<5])
            let minter = RecordingApplyMinter(try WingApplyBench.minter(
                authority, budget: controller.directApplyBudget(settings, safetySettings: safety)))

            let result = await controller.applyAndVerify(settings, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            #expect(result.confirmedCount == 300)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.safety, .remaining, .remaining])
            #expect(mints.allSatisfy { $0.refusal == nil && $0.targets.count <= HostAuthority.directSendBatchLimit })
            #expect(mints.map(\.targets) == [WingApplyBench.targets(settings[..<5]),
                                             WingApplyBench.targets(settings[5..<261]),
                                             WingApplyBench.targets(settings[261...])])
            #expect(await transport.directWrites == settings)
            #expect(await transport.legacyWrites.isEmpty)
            await assertNothingArmed(authority)
            await controller.disconnect()
        }

        /// Every address is dropped once, so all four phases send and the retries mint too.
        @Test func theWorstCaseRetryStaysWithinTheBudget() async throws {
            let authority = try await WingApplyBench.authority()
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try WingApplyBench.settings(300)
            let safety = Array(settings[..<32])
            for setting in settings { await transport.drop(setting.address, times: 1) }
            let budget = controller.directApplyBudget(settings, safetySettings: safety)
            let minter = RecordingApplyMinter(try WingApplyBench.minter(authority, budget: budget))

            let result = await controller.applyAndVerify(settings, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.safety, .safetyRetry, .remaining, .remaining, .retry, .retry])
            #expect(mints.allSatisfy { $0.refusal == nil })
            #expect(!budget.take())
            #expect(await transport.directWrites.count == 32 + 32 + 268 + 268)
            await assertNothingArmed(authority)
            await controller.disconnect()
        }

        /// A console update changes every safety value after the safety set verified, so
        /// the final retry pends S + R = 257 addresses and mints twice: the `c(S + R)`
        /// term of the budget, which `c(R)` alone would not cover.
        @Test func aFinalRetryOfSafetyAndRemainingMintsWithinTheBudget() async throws {
            let authority = try await WingApplyBench.authority()
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try WingApplyBench.settings(257)
            let safety = Array(settings[..<256])
            for setting in settings { await transport.drop(setting.address, times: 1) }
            let budget = controller.directApplyBudget(settings, safetySettings: safety)
            let minter = RecordingApplyMinter(try WingApplyBench.minter(authority, budget: budget))
            let changed = safety.map { WingSetting(address: $0.address, value: .int(2)) }
            await minter.run(before: .remaining) {
                await transport.confirm(changed)
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while ContinuousClock.now < deadline,
                      !changed.allSatisfy({ controller.confirmedValues[$0.address] == $0.value }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }

            let result = await controller.applyAndVerify(settings, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.safety, .safetyRetry, .remaining, .retry, .retry])
            #expect(mints.allSatisfy { $0.refusal == nil })
            #expect(mints.map(\.targets.count) == [256, 256, 1, 256, 1])
            #expect(!budget.take())
            await assertNothingArmed(authority)
            await controller.disconnect()
        }

        @Test func aStaleLiveEpochIsRefusedUnchanged() async throws {
            let authority = try await WingApplyBench.authority()
            let minter = try WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 5))
            await authority.updateLive(try AuthorityBench.liveState(epoch: try DirectSendBench.nextEpoch()))

            let result = await minter.grant(for: .remaining, targets: try someTargets())
            #expect(DirectSendBench.refusal(result) == .staleLive)
            await assertNothingArmed(authority)
        }

        /// The provider is read on every mint: a new epoch it reports is admitted, and
        /// one it does not report is refused, however the first mint went.
        @Test func theProviderIsReadFreshOnEveryMint() async throws {
            let authority = try await WingApplyBench.authority()
            let epochA = AuthorityBench.hostEpoch
            let epochB = try DirectSendBench.nextEpoch()
            let source = EpochSource(epochA)
            let minter = WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 5)) {
                try? WingApplyBench.admission(epoch: source.next())
            }
            let targets = WingApplyBench.targets(try WingApplyBench.settings(3))

            let first = await minter.grant(for: .remaining, targets: targets)
            first.relinquishIfGranted()
            #expect(DirectSendBench.refusal(first) == nil)

            await authority.updateLive(try AuthorityBench.liveState(epoch: epochB))
            #expect(DirectSendBench.refusal(await minter.grant(for: .remaining, targets: targets)) == .staleLive)
            source.set(epochB)
            let third = await minter.grant(for: .remaining, targets: targets)
            third.relinquishIfGranted()
            #expect(DirectSendBench.refusal(third) == nil)
            #expect(source.calls == 3)
            await assertNothingArmed(authority)
        }

        @Test func noAdmissionContextIsRefusedBeforeAdmitting() async throws {
            let authority = try await WingApplyBench.authority()
            let minter = WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 5)) { nil }

            let result = await minter.grant(for: .remaining, targets: try someTargets())
            #expect(DirectSendBench.refusal(result) == .staleLive)
            await assertNothingArmed(authority)
        }

        @Test func aSpentBudgetAdmitsNothingAndNeverCallsTheProvider() async throws {
            let authority = try await WingApplyBench.authority()
            let source = EpochSource(AuthorityBench.hostEpoch)
            let minter = WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 1)) {
                try? WingApplyBench.admission(epoch: source.next())
            }
            let targets = WingApplyBench.targets(try WingApplyBench.settings(3))

            let first = await minter.grant(for: .remaining, targets: targets)
            first.relinquishIfGranted()
            #expect(DirectSendBench.refusal(first) == nil)
            let second = await minter.grant(for: .remaining, targets: targets)
            #expect(DirectSendBench.refusal(second) == .tooManyOutstanding)
            #expect(source.calls == 1)
            await assertNothingArmed(authority)
        }

        /// A Studio apply never runs on a parameter or another route's ticket,
        /// whatever the provider supplies.
        @Test(arguments: [0, 1])
        func anotherScopeIsRefusedBeforeAdmitting(_ kind: Int) async throws {
            let authority = try await WingApplyBench.authority()
            let supplied = kind == 0
                ? try WingApplyBench.parameterAdmission()
                : try WingApplyBench.admission(route: RouteID(validated: "wing.other"))
            let minter = WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 5)) { supplied }

            let fader = DirectSendTarget(WingAddress.fader(.channel, 1))
            let result = await minter.grant(for: .remaining, targets: [fader])
            #expect(DirectSendBench.refusal(result) == .outOfScope)
            await assertNothingArmed(authority)
        }

        /// A refused binding still spends the admitted ticket and arms nothing.
        @Test func aTargetOutsideTheRouteClassesIsRefusedAndSpendsTheTicket() async throws {
            let authority = try await WingApplyBench.authority()
            let minter = try WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 5))
            let inside = WingApplyBench.targets(try WingApplyBench.settings(2))

            let result = await minter.grant(for: .remaining, targets: inside + [DirectSendTarget("/main/1/send/1/foo")])
            #expect(DirectSendBench.refusal(result) == .outOfScope)
            await assertNothingArmed(authority)
        }

        @Test func aRefusedBindingSpendsTheTicketAndArmsNothing() async throws {
            let authority = try await WingApplyBench.authority()
            let minter = try WingApplyBench.minter(authority, budget: WingApplyTicketBudget(limit: 5))
            let tooMany = WingApplyBench.targets(try WingApplyBench.settings(HostAuthority.directSendBatchLimit + 1))
            let repeated = try #require(tooMany.first)

            #expect(DirectSendBench.refusal(await minter.grant(for: .remaining, targets: [])) == .invalidBinding)
            #expect(DirectSendBench.refusal(await minter.grant(for: .remaining, targets: tooMany)) == .invalidBinding)
            #expect(DirectSendBench.refusal(await minter.grant(for: .remaining, targets: [repeated, repeated]))
                == .invalidBinding)
            await assertNothingArmed(authority)
        }
    }
}

private extension Result where Success == DirectWriteAuthorization {
    func relinquishIfGranted() {
        if case .success(let grant) = self { grant.relinquish() }
    }
}
