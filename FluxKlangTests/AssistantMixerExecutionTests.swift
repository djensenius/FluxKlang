import Foundation
import Observation
import Testing

@testable import FluxKlang

@MainActor
struct AssistantMixerExecutionTests {
    private func connected() async -> (WingController, AssistantRecordingWingTransport) {
        let transport = AssistantRecordingWingTransport()
        let wing = WingController(transport: transport)
        await wing.connect(host: "192.0.2.10")
        return (wing, transport)
    }

    private func executor(_ wing: WingController) -> AssistantMixerExecutor {
        AssistantMixerExecutor(controller: { wing }, layout: { FaderLayout() }, timeout: .seconds(1))
    }

    @Test func absoluteRelativeAndMuteUseFreshReadbackAndOnlyAllowlistedAddresses() async throws {
        for operation in [AssistantMixerCommand.Operation.setDB(-12), .adjustDB(-3), .mute(true), .mute(false)] {
            let (wing, transport) = await connected()
            // Optimistic cache is not the fresh baseline. Incoming value wins.
            await wing.setFader(.channel, 7, decibels: -50)
            await transport.put(WingAddress.fader(.channel, 7), .float(0.75))
            let before = wing.transportWriteCount
            let reply = await executor(wing).execute(.init(target: .channel(7), operation: operation))
            #expect(reply.contains("Confirmed WING Channel 7"))
            #expect(wing.transportWriteCount == before + 1)
            let writes = await transport.writes
            let last = try #require(writes.last)
            switch operation {
            case .mute(let muted):
                #expect(last.address == "/ch/7/mute")
                #expect(last.value == .int(muted ? 1 : 0))
            case .setDB:
                #expect(last.address == "/ch/7/fdr")
                #expect(abs((last.value.floatValue ?? 100) - (-12)) < 0.001)
            case .adjustDB:
                #expect(last.address == "/ch/7/fdr")
                #expect(abs((last.value.floatValue ?? 100) - (-3)) < 0.001)
            }
            await wing.disconnect()
        }
    }

    @Test func mainUsesFaderLawAndNamedMonoRequiresFreshUniqueIdentity() async {
        let (wing, transport) = await connected()
        let main = await executor(wing).execute(.init(target: .main(1), operation: .setDB(-90)))
        #expect(main.contains("Confirmed WING Main 1: off (−∞ dB; minimum fader position)"))
        #expect(!main.contains("-90.0 dB"))
        #expect(await transport.writes.last?.value == .float(-144))
        let named = await executor(wing).execute(.init(target: .liveName("Lead"), operation: .adjustDB(-3)))
        #expect(named.contains("Confirmed WING Channel 7"))
        await wing.disconnect()
    }

    @Test func writeAuthorizationIsSingleUseEvenAfterSuccessfulSend() throws {
        let authorization = WingMixerWriteAuthorization(deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        var actualWrites = 0
        try authorization.consume { actualWrites += 1 }
        #expect(throws: WingTransportError.notAuthorized) {
            try authorization.consume { actualWrites += 1 }
        }
        #expect(actualWrites == 1)
    }

    @Test func relativeFromOffRejectsWithoutInventingFiniteBaseline() async {
        let (wing, transport) = await connected()
        await transport.put("/ch/7/fdr", .float(0))
        for delta: Float in [-3, 3] {
            let reply = await executor(wing).execute(.init(target: .channel(7), operation: .adjustDB(delta)))
            #expect(reply.contains("off (−∞)"))
            #expect(reply.contains("absolute level"))
        }
        #expect(await transport.writes.isEmpty)
        #expect(wing.transportWriteCount == 0)
        await wing.disconnect()
    }

    @Test func finalSendAuthorizationIsRevokedBeforeAnyActualWrite() async throws {
        // Cancellation, expiry, socket session, active controller, layout and
        // confirmed-name invalidation while the final send is already queued.
        for scenario in 0...6 {
            let (wing, transport) = await connected()
            let state = AssistantMixerTestState(wing: wing)
            let executor = AssistantMixerExecutor(controller: { state.wing }, layout: { state.layout },
                                                  timeout: .seconds(1))
            await transport.pauseMixerSend()
            let task = Task { await executor.execute(.init(target: .channel(7), operation: .adjustDB(-3))) }
            try await AssistantBackendFixture.waitAsync { await transport.mixerSendWaiting }
            switch scenario {
            case 0: task.cancel()
            case 1: try await Task.sleep(for: .milliseconds(1100))
            case 2: await wing.disconnect()
            case 3: state.wing = WingController(transport: AssistantRecordingWingTransport())
            case 4:
                let original = state.layout
                state.layout = FaderLayout(strips: [.init(node: .channel(8))])
                state.layout = original
            case 5: await transport.start(remoteHost: "192.0.2.10", localPort: nil, broadcast: false)
            default:
                await transport.emit("/ch/7/name", .string("Renamed"))
                try await AssistantBackendFixture.wait { wing.confirmedValues["/ch/7/name"] == .string("Renamed") }
            }
            await transport.releaseMixerSend()
            let reply = await task.value
            #expect(!reply.contains("Confirmed WING"))
            #expect(await transport.writes.isEmpty)
            await wing.disconnect()
        }
    }

    @Test func renameOrDuplicateBetweenDiscoveryAndBaselineNeverWrites() async throws {
        for renameSelected in [false, true] {
            let (wing, transport) = await connected()
            await transport.pauseBaselineAfterNameDiscovery()
            let task = Task { await executor(wing).execute(.init(target: .liveName("Lead"), operation: .mute(true))) }
            try await AssistantBackendFixture.waitAsync { await transport.queryWaiting }
            let address = renameSelected ? "/ch/7/name" : "/ch/8/name"
            let value = WingValue.string(renameSelected ? "Renamed" : "Lead")
            await transport.put(address, value)
            await transport.emit(address, value)
            try await AssistantBackendFixture.wait { wing.confirmedValues[address] == value }
            await transport.releaseQueries()
            let reply = await task.value
            #expect(!reply.contains("Confirmed WING"))
            #expect(await transport.writes.isEmpty)
            #expect(wing.transportWriteCount == 0)
            await wing.disconnect()
        }
    }

    @Test func sessionOrNameChangeAfterSetIsUnconfirmedWithExactlyOneActualWrite() async throws {
        for changeSession in [false, true] {
            let (wing, transport) = await connected()
            await transport.pauseReadback()
            let task = Task { await executor(wing).execute(.init(target: .channel(7), operation: .setDB(-12))) }
            try await AssistantBackendFixture.waitAsync { await transport.queryWaiting }
            #expect(await transport.writes.count == 1)
            if changeSession { await wing.disconnect() } else {
                await transport.put("/ch/7/name", .string("Renamed"))
                await transport.emit("/ch/7/name", .string("Renamed"))
                try await AssistantBackendFixture.wait { wing.confirmedValues["/ch/7/name"] == .string("Renamed") }
            }
            await transport.releaseQueries()
            let reply = await task.value
            #expect(reply.contains("could not be confirmed"))
            #expect(!reply.contains("Confirmed WING"))
            #expect(await transport.writes.count == 1)
            await wing.disconnect()
        }
    }

    @Test func realisticMultiValueReplyDecodingProvidesFreshEngineeringBaseline() async throws {
        let (wing, transport) = await connected()
        let reply = await executor(wing).execute(.init(target: .channel(7), operation: .adjustDB(-3)))
        #expect(reply.contains("Confirmed WING Channel 7: -3.0 dB"))
        #expect(await transport.writes.last?.value == .float(-3))
        let mute = await executor(wing).execute(.init(target: .channel(7), operation: .mute(true)))
        #expect(mute.contains("Confirmed WING Channel 7: muted"))
        #expect(wing.confirmedValues["/ch/7/mute"] == .int(1))
        #expect(wing.confirmedValues["/ch/7/fdr"]?.floatValue == FaderMath.position(fromDecibels: -3))
        await wing.disconnect()
    }

    @Test func missingFreshRepliesDisconnectedDemoAndInvalidBaselinesNeverWrite() async {
        let (wing, transport) = await connected()
        await transport.configure(answers: false)
        let timedOut = await executor(wing).execute(.init(target: .channel(7), operation: .setDB(-12)))
        #expect(timedOut.contains("No changes"))
        #expect(wing.transportWriteCount == 0)
        await transport.configure()
        for value in [WingValue.float(.nan), .float(.infinity), .float(1.1), .string("0.75")] {
            await transport.put("/ch/7/fdr", value)
            let reply = await executor(wing).execute(.init(target: .channel(7), operation: .adjustDB(-3)))
            #expect(reply.contains("No changes"))
            #expect(wing.transportWriteCount == 0)
        }
        await wing.disconnect()
        #expect(await executor(wing).execute(.init(target: .main(1), operation: .mute(true))).contains("No changes"))
        let demo = WingController.preview()
        #expect(await executor(demo).execute(.init(target: .main(1), operation: .mute(true))).contains("No changes"))
        #expect(demo.transportWriteCount == 0)
    }

    @Test func relativeOutOfRangeAndNonfiniteRequestsRejectNotClamp() async {
        let (wing, transport) = await connected()
        for operation in [AssistantMixerCommand.Operation.adjustDB(11), .adjustDB(-91), .setDB(11), .setDB(.nan)] {
            let reply = await executor(wing).execute(.init(target: .channel(7), operation: operation))
            #expect(reply.contains("No changes"))
        }
        #expect(wing.transportWriteCount == 0)
        #expect(await transport.writes.isEmpty)
        await wing.disconnect()
    }

    @Test func duplicateNameAndStereoAreZeroWriteClarifications() async {
        let (wing, transport) = await connected()
        await transport.put("/ch/8/name", .string("Lead"))
        let duplicate = await executor(wing).execute(.init(target: .liveName("Lead"), operation: .mute(true)))
        #expect(duplicate.contains("unique"))
        await transport.put("/ch/8/name", .string("Right"))
        let stereoLayout = FaderLayout(strips: [.init(node: .channel(7), rightNode: .channel(8), customLabel: "Lead")])
        let stereo = AssistantMixerExecutor(
            controller: { wing }, layout: { stereoLayout }, timeout: .seconds(1))
        #expect(await stereo.execute(.init(target: .liveName("Lead"), operation: .mute(true))).contains("stereo"))
        #expect(wing.transportWriteCount == 0)
        await wing.disconnect()
    }

    @Test func sendFailureMissingOrMismatchedConfirmationNeverClaimsSuccessOrRetries() async {
        for scenario in 0...2 {
            let (wing, transport) = await connected()
            await transport.configure(afterWrite: scenario != 1, fail: scenario == 0, mismatch: scenario == 2)
            let reply = await executor(wing).execute(.init(target: .channel(7), operation: .setDB(-12)))
            #expect(!reply.contains("Confirmed WING"))
            #expect(reply.contains("retry"))
            #expect(wing.transportWriteCount == 1)
            #expect(await transport.writes.count == 1)
            await wing.disconnect()
        }
    }

    @Test func controllerReplacementSessionChangeLayoutChangeAndCancellationBeforeSetAreZeroWrite() async throws {
        for scenario in 0...3 {
            let (wing, transport) = await connected()
            await transport.configure(delay: .milliseconds(35))
            let state = AssistantMixerTestState(wing: wing)
            let executor = AssistantMixerExecutor(
                controller: { state.wing }, layout: { state.layout }, timeout: .milliseconds(150))
            let task = Task { await executor.execute(.init(target: .channel(7), operation: .adjustDB(-3))) }
            try await Task.sleep(for: .milliseconds(10))
            switch scenario {
            case 0: state.wing = WingController(transport: AssistantRecordingWingTransport())
            case 1: await wing.disconnect()
            case 2: state.layout = FaderLayout(strips: [.init(node: .channel(8))])
            default: task.cancel()
            }
            let reply = await task.value
            #expect(!reply.contains("Confirmed WING"))
            #expect(wing.transportWriteCount == 0)
            await wing.disconnect()
        }
    }

    @Test func commandCannotMigrateToAnotherSubmissionSession() async {
        let (wing, transport) = await connected()
        let reply = await executor(wing).execute(.init(target: .main(1), operation: .mute(true)), sessionID: UUID())
        #expect(reply.contains("No changes"))
        #expect(wing.transportWriteCount == 0)
        #expect(await transport.writes.isEmpty)
        await wing.disconnect()
    }

    @Test func concurrentCommandsAreNotQueuedOrReplayed() async throws {
        let (wing, transport) = await connected()
        await transport.configure(delay: .milliseconds(25))
        let executor = executor(wing)
        let first = Task { await executor.execute(.init(target: .channel(7), operation: .adjustDB(-3))) }
        try await Task.sleep(for: .milliseconds(5))
        let second = await executor.execute(.init(target: .channel(7), operation: .adjustDB(-3)))
        #expect(second.contains("another mixer command"))
        _ = await first.value
        #expect(wing.transportWriteCount <= 1)
        await wing.disconnect()
    }

    @Test func confirmationSessionIgnoresWrongPeerPortGenerationOldTimestampAndOptimism() async throws {
        let transport = AssistantRecordingWingTransport()
        await transport.configure(answers: false)
        let wing = WingController(transport: transport)
        await wing.connect(host: "192.0.2.10")
        #expect(wing.confirmedSnapshot().status == .refreshing)
        let session = try #require(wing.sessionID)
        for variant in 0...3 {
            await transport.emit(
                "/ch/7/name", .string("Wrong"),
                host: variant == 0 ? "192.0.2.99" : "192.0.2.10",
                port: variant == 1 ? 123 : WingNetwork.defaultPort,
                session: variant == 2 ? UUID() : nil,
                date: variant == 3 ? .distantPast : Date())
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(wing.confirmedValues["/ch/7/name"] == nil)
        await wing.setName(.channel, 7, to: "Optimistic")
        #expect(wing.name(.channel, 7) == "Optimistic")
        #expect(wing.confirmedValues["/ch/7/name"] == nil)
        await transport.emit("/ch/7/name", .string("Confirmed"))
        try await AssistantBackendFixture.wait { wing.confirmedValues["/ch/7/name"] != nil }
        #expect(wing.confirmedSnapshot().status == .observed)
        #expect(wing.confirmedSnapshot(now: Date().addingTimeInterval(31)).status == .stale)
        await wing.disconnect()
        #expect(wing.confirmedSnapshot().status == .disconnected)
        #expect(wing.confirmedValues.isEmpty)
        await wing.connect(host: "192.0.2.10")
        #expect(wing.sessionID != session)
        #expect(wing.confirmedValues.isEmpty)
        await wing.disconnect()
    }
}

@MainActor
@Observable
private final class AssistantMixerTestState {
    var wing: WingController
    var layout = FaderLayout()
    init(wing: WingController) { self.wing = wing }
}
