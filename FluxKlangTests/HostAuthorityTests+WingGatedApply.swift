import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"
private let safeMute = WingSetting(address: WingAddress.mute(.channel, 1), value: .int(1))
private let safeFader = WingSetting(address: WingAddress.fader(.channel, 1), value: .float(0.25))
private let sourceGroup = WingSetting(address: WingAddress.channelSourceGroup(1), value: .string("LCL"))
private let sourceIndex = WingSetting(address: WingAddress.channelSourceIndex(1), value: .int(3))
private let otherMute = WingSetting(address: WingAddress.mute(.channel, 2), value: .int(0))
private let safety = [safeMute, safeFader]
private let routing = [sourceGroup, sourceIndex]

private func targets(_ settings: [WingSetting]) -> Set<DirectSendTarget> {
    Set(settings.map { DirectSendTarget($0.address) })
}

private func orderedTargets(_ settings: some Sequence<WingSetting>) -> [DirectSendTarget] {
    settings.map { DirectSendTarget($0.address) }
}

/// The first `count` distinct WING query addresses, each set to 1.
private func plan(_ count: Int) throws -> [WingSetting] {
    let addresses = Array(WingAddress.allQueryAddresses().prefix(count))
    try #require(Set(addresses).count == count)
    return addresses.map { WingSetting(address: $0, value: .int(1)) }
}

extension HostAuthorityTests {
    /// AU6: the grant-gated `WingController.applyAndVerify` mints a fresh grant for
    /// each chunk of at most `HostAuthority.directSendBatchLimit` addresses of each
    /// send phase, binding only that chunk, and spends it before the next chunk
    /// mints or verification starts. Fakes only; nothing reaches a socket.
    @MainActor
    struct WingGatedApply {
        private func connected(_ transport: EchoingDirectTransport) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        /// Writes of `safety + routing` before each phase when one safety and one
        /// routing write are dropped once, so all four phases send.
        private static let writesBefore: [WingDirectApplyPhase: Int] = [
            .safety: 0, .safetyRetry: 2, .remaining: 3, .retry: 5
        ]

        @Test func eachSendPhaseMintsAFreshGrant() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            await transport.drop(safeFader.address, times: 1)
            await transport.drop(sourceIndex.address, times: 1)

            let result = await controller.applyAndVerify(safety + routing, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == WingDirectApplyPhase.allCases)
            #expect(mints.map(\.targets) == [targets(safety), targets([safeFader]),
                                             targets(routing), targets([sourceIndex])])
            #expect(mints.allSatisfy { $0.outstandingBefore == 0 })
            let grants = await minter.grants
            #expect(grants.count == 4)
            for (index, grant) in grants.enumerated() {
                #expect(grants[(index + 1)...].allSatisfy { $0 !== grant })
                #expect(!grant.isArmed)
            }
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directWrites == safety + [safeFader] + routing + [sourceIndex])
            #expect(await transport.legacyWrites.isEmpty)
            await controller.disconnect()
        }

        @Test(arguments: WingDirectApplyPhase.allCases)
        func aRefusedMintEmitsNoWrites(_ refused: WingDirectApplyPhase) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            await minter.refuse(refused)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            await transport.drop(safeFader.address, times: 1)
            await transport.drop(sourceIndex.address, times: 1)

            let result = await controller.applyAndVerify(safety + routing, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .failed)
            let safetyPhase = refused == .safety || refused == .safetyRetry
            #expect(result.details.hasSuffix("Routing was not sent.") == safetyPhase)
            let phases = WingDirectApplyPhase.allCases
            let last = try #require(phases.firstIndex(of: refused))
            #expect(await minter.phases == Array(phases[...last]))
            let writes = try #require(Self.writesBefore[refused])
            #expect(await transport.directCalls == writes)
            #expect(controller.transportWriteCount == writes)
            #expect(await transport.legacyWrites.isEmpty)
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// A value confirmed by an earlier apply is still cached, but a refused mint
        /// verified nothing in this apply, so it confirms nothing.
        @Test func aRefusedMintCountsNoStaleConfirmation() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            #expect(await controller.applyAndVerify([sourceGroup], session: session, minting: minter).state
                == .verified)
            #expect(controller.confirmedValues[sourceGroup.address] == sourceGroup.value)
            await minter.refuse(.remaining)

            let result = await controller.applyAndVerify(routing, session: session, minting: minter)
            #expect(result.state == .failed)
            #expect(result.confirmedCount == 0)
            #expect(await minter.phases == [.remaining, .remaining])
            #expect(await transport.directCalls == 1)
            #expect(await transport.directWrites == [sourceGroup])
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        @Test func aLiveChangeDuringVerifyBlocksTheRetry() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            await minter.bumpLive(before: .retry)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            await transport.drop(sourceIndex.address, times: 1)

            let result = await controller.applyAndVerify(routing, session: session, minting: minter)
            #expect(result.state == .failed)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.remaining, .retry])
            #expect(mints.last.flatMap { DirectSendBench.refusal($0.result) } == .staleLive)
            #expect(await transport.directWrites == routing)
            #expect(controller.confirmedValues[sourceIndex.address] == nil)
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        @Test func safetyUnconfirmedNeverMintsRemaining() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            await transport.drop(safeFader.address)

            let result = await controller.applyAndVerify(safety + routing, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .failed)
            #expect(result.details == "Safe endpoint levels could not be confirmed. Routing was not sent.")
            #expect(await minter.phases == [.safety, .safetyRetry])
            #expect(await transport.directWrites == safety + [safeFader])
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// The task is cancelled while the first routing write is in flight: the
        /// rest of the phase is refused by the controller, and every grant is spent.
        @Test func cancellationRelinquishes() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            await transport.holdNextWrite()

            let applying = Task {
                await controller.applyAndVerify(routing + [otherMute], session: session, minting: minter)
            }
            await transport.waitUntilHeld()
            applying.cancel()
            await transport.release()

            #expect(await applying.value.state == .failed)
            #expect(await minter.phases.first == .remaining)
            #expect(await minter.mints.allSatisfy { $0.outstandingBefore == 0 })
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directWrites == [sourceGroup])
            await controller.disconnect()
        }

        @Test func transportFailureRelinquishes() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            await transport.fail(sourceIndex.address)

            let result = await controller.applyAndVerify(routing + [otherMute], session: session, minting: minter)
            #expect(result.state == .failed)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.remaining, .retry])
            #expect(mints.map(\.targets) == [targets(routing + [otherMute]), targets([sourceIndex, otherMute])])
            #expect(mints.allSatisfy { $0.outstandingBefore == 0 })
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directCalls == 3)
            #expect(await transport.directWrites == [sourceGroup])
            await controller.disconnect()
        }

        /// The real WING scope admits the safety mute under `wing.mute` but no
        /// routing address: the remaining phase is refused and sends nothing.
        @Test func outOfScopeRoutingIsRefused() async throws {
            let authority = try await AuthorityBench.makeAuthority(sendScope: WingDirectSendScope())
            let minter = GatedApplyMinter(authority, parameter: ParameterCatalog.wingMute)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)

            let result = await controller.applyAndVerify([safeMute] + routing, safetySettings: [safeMute],
                                                         session: session, minting: minter)
            #expect(result.state == .failed)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.safety, .remaining])
            #expect(mints.last.flatMap { DirectSendBench.refusal($0.result) } == .outOfScope)
            #expect(await transport.directWrites == [safeMute])
            #expect(await transport.legacyWrites.isEmpty)
            #expect(routing.allSatisfy { controller.values[$0.address] == nil })
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        @Test func phaseWithNothingPendingMintsNothing() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)

            let result = await controller.applyAndVerify([safeMute] + routing, safetySettings: [safeMute],
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            #expect(await minter.phases == [.safety, .remaining])
            #expect(await controller.applyAndVerify([], session: session, minting: minter).state == .verified)
            #expect(await minter.phases == [.safety, .remaining])
            #expect(await transport.directWrites == [safeMute] + routing)
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// Chunks are consecutive, disjoint and in order, and each is spent before
        /// the next mints; every entry is sent once, in the original order.
        @Test(arguments: [(256, [256]), (257, [256, 1]), (600, [256, 256, 88])])
        func aLargePhaseMintsOneGrantPerChunk(_ count: Int, _ chunks: [Int]) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try plan(count)

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .verified)
            #expect(result.confirmedCount == count)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == Array(repeating: .remaining, count: chunks.count))
            #expect(mints.map(\.orderedTargets.count) == chunks)
            #expect(mints.flatMap(\.orderedTargets) == orderedTargets(settings))
            #expect(mints.allSatisfy { $0.outstandingBefore == 0 })
            #expect(await minter.grants.count == chunks.count)
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directWrites == settings)
            await controller.disconnect()
        }

        /// The first chunk's writes stand; the refused second chunk confirms nothing,
        /// and the third chunk, which would be granted, is never asked for.
        @Test func aRefusedSecondChunkSendsNothingMore() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            await minter.refuse(.remaining, mints: 1..<2)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try plan(600)

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .failed)
            #expect(result.confirmedCount == 0)
            #expect(result.details == "The host did not authorize the WING write. Nothing more was sent.")
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.remaining, .remaining])
            #expect(mints.map(\.orderedTargets) == [orderedTargets(settings[..<256]),
                                                    orderedTargets(settings[256..<512])])
            let grants = await minter.grants
            #expect(grants.count == 1)
            #expect(grants.allSatisfy { !$0.isArmed })
            #expect(await transport.directCalls == 256)
            #expect(await transport.directWrites == Array(settings[..<256]))
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// A failed entry stops its phase: no later chunk of that phase mints.
        @Test func aFailedEntryInTheFirstChunkMintsNoSecond() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try plan(300)
            await transport.fail(settings[10].address)

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .failed)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.remaining, .retry])
            #expect(mints.map(\.orderedTargets) == [orderedTargets(settings[..<256]),
                                                    orderedTargets(settings[10..<266])])
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await transport.directCalls == 12)
            #expect(await transport.directWrites == Array(settings[..<10]))
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// The largest Studio plan the allocator produces, 32 safety and 964
        /// remaining settings, mints 1 + 4 grants on the real authority book.
        @Test func theLargestStudioPlanVerifiesInChunks() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try plan(996)

            let result = await controller.applyAndVerify(settings, safetySettings: Array(settings[..<32]),
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            #expect(result.confirmedCount == 996)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.safety] + Array(repeating: .remaining, count: 4))
            #expect(mints.map(\.orderedTargets.count) == [32, 256, 256, 256, 196])
            #expect(mints.flatMap(\.orderedTargets) == orderedTargets(settings))
            #expect(mints.allSatisfy { $0.outstandingBefore == 0 })
            #expect(await minter.grants.count == 5)
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directWrites == settings)
            await controller.disconnect()
        }

        /// Entries confirmed between a chunk's mint and its sends are skipped, the
        /// chunk's unspent targets are relinquished before the next chunk mints, and
        /// nothing outside the chunk's own grant is sent.
        @Test func pendingShrinkingAfterAChunkMintSkipsConfirmedEntries() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try plan(300)
            for setting in settings { await transport.drop(setting.address, times: 1) }
            let confirmed = Array(settings[..<5] + settings[260..<265])
            await minter.after(.retry, mint: 0) {
                await transport.confirm(confirmed)
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while ContinuousClock.now < deadline,
                      !confirmed.allSatisfy({ controller.confirmedValues[$0.address] == $0.value }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .verified)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.remaining, .remaining, .retry, .retry])
            #expect(mints.map(\.orderedTargets) == [orderedTargets(settings[..<256]),
                                                    orderedTargets(settings[256...]),
                                                    orderedTargets(settings[..<256]),
                                                    orderedTargets(settings[256...])])
            #expect(mints.allSatisfy { $0.outstandingBefore == 0 })
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            let retried = settings[5..<260] + settings[265...]
            #expect(await transport.directWrites == settings + retried)
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }
    }
}
