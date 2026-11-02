import Foundation
import Testing
@testable import FluxKlang

struct WingApplyVerificationTests {
    @Test @MainActor func assistantReadPreservesListenConfirmationsWithoutHiddenRetry() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await controller.connect(host: "192.0.2.10")
        var verificationTask: Task<WingApplyVerification, Never>?
        var refreshTask: Task<Bool, Never>?
        do {
            let session = try #require(controller.sessionID)
            let settings = [
                WingSetting(address: WingAddress.channelSourceGroup(7), value: .string("LCL")),
                WingSetting(address: WingAddress.channelSourceIndex(7), value: .int(7))
            ]
            let verification = Task { await controller.applyAndVerify(settings) }
            verificationTask = verification
            try await AssistantBackendFixture.wait {
                settings.allSatisfy { controller.confirmedValues[$0.address] == $0.value }
            }
            let confirmations = controller.confirmedValues
            let receivedAt = controller.confirmedReceivedAt
            await transport.configure(answers: false)
            let queryCount = await transport.queries.count
            let refresh = Task {
                await controller.refreshLiveReferences([
                    .init(sessionID: session, kind: .channel, index: 7, label: .init("Lead"),
                          sourceGroup: "LCL", sourceIndex: 7, equipmentID: UUID())
                ])
            }
            refreshTask = refresh
            try await AssistantBackendFixture.waitAsync { await transport.queries.count > queryCount }
            for setting in settings {
                #expect(controller.confirmedValues[setting.address] == confirmations[setting.address])
                #expect(controller.confirmedReceivedAt[setting.address] == receivedAt[setting.address])
            }
            #expect(await verification.value.state == .verified)
            #expect(await refresh.value == false, "Cached confirmations cannot satisfy a new GET")
            #expect(await transport.writes == settings, "An assistant GET must never cause routing SET retries")
        } catch {
            verificationTask?.cancel()
            refreshTask?.cancel()
            _ = await verificationTask?.value
            _ = await refreshTask?.value
            await controller.disconnect()
            throw error
        }
        await controller.disconnect()
    }

    @Test func reportsMissingAndMismatchedValuesAsPending() {
        let expected = [
            WingSetting(address: "/one", value: .int(1)),
            WingSetting(address: "/two", value: .float(0.25)),
            WingSetting(address: "/three", value: .string("BUS"))
        ]

        let pending = WingApplyVerifier.pendingSettings(
            expected: expected,
            confirmedValues: [
                "/one": .int(1),
                "/two": .float(0.5)
            ]
        )

        #expect(pending.map(\.address) == ["/two", "/three"])
    }

    @Test func acceptsSmallHardwareFloatRounding() {
        let expected = [WingSetting(address: "/fader", value: .float(0.25))]

        let result = WingApplyVerifier.result(
            expected: expected,
            confirmedValues: ["/fader": .float(0.2505)],
            sendFailed: false
        )

        #expect(result.state == .verified)
    }
}
