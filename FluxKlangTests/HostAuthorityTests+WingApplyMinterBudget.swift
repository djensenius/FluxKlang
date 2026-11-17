import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"

extension HostAuthorityTests {
    /// AU7b: `WingApplyTicketBudget` caps the tickets one gated apply may mint.
    /// Fakes only; nothing reaches a socket.
    @MainActor
    struct WingApplyMinterBudget {
        private func connected(_ transport: EchoingDirectTransport) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        @Test(arguments: [
            (0, 0, 0), (0, 1, 2), (1, 0, 3), (0, 256, 2), (0, 257, 4), (256, 1, 5), (32, 964, 10)
        ])
        func limitFollowsTheChunkCounts(_ safety: Int, _ remaining: Int, _ expected: Int) {
            #expect(WingApplyTicketBudget.limit(safetyCount: safety, remainingCount: remaining) == expected)
            #expect(WingApplyBench.drain(WingApplyTicketBudget(limit: expected)) == expected)
        }

        @Test func theBudgetUsesTheControllersOwnSplit() async throws {
            let (controller, _) = try await connected(EchoingDirectTransport())
            let settings = try WingApplyBench.settings(300)
            let duplicated = settings + settings[..<10]
            let outside = try #require(WingApplyBench.settings(400).last)

            #expect(WingApplyBench.drain(controller.directApplyBudget(duplicated)) == 4)
            let safety = Array(settings[..<5]) + [outside]
            #expect(controller.directApplyPlan(duplicated, safetySettings: safety).safety.count == 5)
            #expect(controller.directApplyPlan(duplicated, safetySettings: safety).remaining.count == 295)
            #expect(WingApplyBench.drain(controller.directApplyBudget(duplicated, safetySettings: safety)) == 6)
            #expect(WingApplyBench.drain(controller.directApplyBudget([])) == 0)
            await controller.disconnect()
        }

        @Test func takeStopsAtExactlyTheLimit() async {
            let budget = WingApplyTicketBudget(limit: 50)
            let successes = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<200 { group.addTask { budget.take() } }
                var taken = 0
                for await success in group where success { taken += 1 }
                return taken
            }
            #expect(successes == 50)
            #expect(!budget.take())
            #expect(!budget.take())
            #expect(!WingApplyTicketBudget(limit: 0).take())
            #expect(!WingApplyTicketBudget(limit: -3).take())
        }

        /// A budget of 1, and one chunk short of a phase, stop the apply at the next mint.
        @Test(arguments: [(300, 1), (513, 2)])
        func anExhaustedBudgetStopsTheApply(_ count: Int, _ limit: Int) async throws {
            let authority = try await WingApplyBench.authority()
            let minter = RecordingApplyMinter(try WingApplyBench.minter(authority,
                                                                         budget: WingApplyTicketBudget(limit: limit)))
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try WingApplyBench.settings(count)

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .failed)
            #expect(result.confirmedCount == 0)
            let mints = await minter.mints
            #expect(mints.count == limit + 1)
            let expected: [DirectWriteRefusal?] = Array(repeating: nil, count: limit) + [.tooManyOutstanding]
            #expect(mints.map(\.refusal) == expected)
            #expect(await transport.directWrites == Array(settings[..<(256 * limit)]))
            #expect(await transport.legacyWrites.isEmpty)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await authority.outstandingDirectWriteCount() == 0)
            await controller.disconnect()
        }
    }
}
