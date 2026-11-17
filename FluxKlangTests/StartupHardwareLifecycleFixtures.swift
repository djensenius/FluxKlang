import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

func requireIsolatedStartupProcess() throws {
    let environment = ProcessInfo.processInfo.environment
    try #require(AppPersistence.isTesting, "Startup boundaries require process-selected isolation")
    try #require(environment["FLUXKLANG_ISOLATED_TESTING"] == "1")
    try #require(environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "0")
    try #require(environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "0")
}

final class StartupWingTransportSpy: Sendable {
    private let recorded = Mutex<[StartupStopGatedTransport]>([])
    var transports: [StartupStopGatedTransport] { recorded.withLock { $0 } }

    func makeTransport(port: UInt16, probe: @escaping LocalNetworkProbe.Check) -> any WingTransporting {
        let transport = StartupStopGatedTransport()
        recorded.withLock { $0.append(transport) }
        return transport
    }
}

actor StartupStopGatedTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private let stopEntries: AsyncStream<Void>
    private let stopEntry: AsyncStream<Void>.Continuation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts = 0
    private(set) var sends = 0
    private(set) var stopsStarted = 0
    private(set) var stopsCompleted = 0

    init() {
        (stopEntries, stopEntry) = AsyncStream<Void>.makeStream()
    }

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) async throws {
        starts += 1
        throw WingTransportError.notStarted
    }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) async throws {
        sends += 1
        throw WingTransportError.notStarted
    }

    func sendMixerValue(_ node: WingNodeRef, value: WingValue, muted: Bool, sessionID: UUID,
                        authorization: WingMixerWriteAuthorization) async throws {
        sends += 1
        throw WingTransportError.notStarted
    }

    func stop() async {
        stopsStarted += 1
        stopEntry.yield(())
        stopEntry.finish()
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        stopsCompleted += 1
    }

    func releaseStop() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForStopEntry() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stopEntries] in
                for await _ in stopEntries { return true }
                return false
            }
            group.addTask {
                // A deadline only fails missing signals; elapsed time never proves completion.
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let entered = await group.next() ?? false
            group.cancelAll()
            return entered
        }
    }
}

@MainActor
final class HardwareFactorySpy {
    let input = RecordingLaunchControlXLInput()
    let wing = WingFactorySpy()
    private(set) var inputsMade = 0

    var factories: HardwareServiceFactories {
        HardwareServiceFactories(makeLaunchControlXLInput: { [self] in
            inputsMade += 1
            return input
        }, makeWingTransport: wing.makeTransport)
    }
}

/// All state captured by the @Sendable WING factory is protected by the mutex.
final class WingFactorySpy: Sendable {
    private let recordedPorts = Mutex<[UInt16]>([])
    var ports: [UInt16] { recordedPorts.withLock { $0 } }

    @MainActor var factories: HardwareServiceFactories {
        var factories = HardwareServiceFactories.inert
        factories.makeWingTransport = makeTransport
        return factories
    }

    func makeTransport(port: UInt16, probe: @escaping LocalNetworkProbe.Check) -> any WingTransporting {
        recordedPorts.withLock { $0.append(port) }
        return InertWingTransport()
    }
}

@MainActor
final class RecordingLaunchControlXLInput: LaunchControlXLInput {
    private(set) var starts: [[String]] = []
    private(set) var stops = 0
    private(set) var onPackets: (@MainActor (MIDIPacketBatch) -> Void)?
    private var onSourcesChanged: (([MIDIConnectedSource]) -> Void)?
    private var tokens = FakeSourceTokens()

    func start(
        sourceNameContains: [String],
        onPackets: @escaping @MainActor (MIDIPacketBatch) -> Void,
        onSourcesChanged: @escaping ([MIDIConnectedSource]) -> Void
    ) {
        starts.append(sourceNameContains)
        self.onPackets = onPackets
        self.onSourcesChanged = onSourcesChanged
    }

    func stop() {
        stops += 1
        onSourcesChanged?([])
    }

    /// Unresolved sources, one stable token per name, all sharing the stream's legacy source.
    func reportSources(_ names: [String]) {
        onSourcesChanged?(tokens.unresolved(names))
    }

    func reportConnected(_ sources: [MIDIConnectedSource]) {
        onSourcesChanged?(sources)
    }

    /// One batch of raw packets, as CoreMIDI would deliver them from the connection `source`.
    func send(packets: [[UInt8]], from source: MIDIConnectionToken? = nil, afterGap: Bool = false) {
        onPackets?(MIDIPacketBatch(packets: packets, afterGap: afterGap, source: source))
    }
}

/// Assigns each source name a fake reports the next token, from 1, and keeps that token, so reporting the same
/// names again, in any order, describes the same connections.
struct FakeSourceTokens {
    private var names: [String] = []

    mutating func unresolved(_ reported: [String]) -> [MIDIConnectedSource] {
        reported.compactMap { name in
            let index = names.firstIndex(of: name) ?? names.endIndex
            if index == names.endIndex { names.append(name) }
            return MIDIConnectionToken(rawValue: UInt(index + 1)).map {
                MIDIConnectedSource(token: $0, endpoint: nil, name: name)
            }
        }
    }
}

struct LaunchControlXLFixture {
    let directory = URL.temporaryDirectory.appendingPathComponent("lcxl-\(UUID().uuidString)", isDirectory: true)
    let configuration: LaunchControlXLConfiguration

    var store: JSONFileStore { JSONFileStore(directory: directory, cloud: nil) }

    init(mode: LaunchControlXLMode) throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = mode
        self.configuration = configuration
    }

    /// Saves the fixture mode where `AppModel`'s controller loads it, overriding the bundled default.
    func seed() async {
        await store.save(configuration, to: "launch-control-xl.json")
    }

    @MainActor
    func controller(
        makeMIDIInput: @escaping @MainActor () -> any LaunchControlXLInput
    ) -> LaunchControlXLController {
        LaunchControlXLController(
            fileStore: store,
            defaultConfiguration: configuration,
            makeMIDIInput: makeMIDIInput
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct StartupAppModelFixture {
    let directory = URL.temporaryDirectory.appendingPathComponent("startup-\(UUID().uuidString)", isDirectory: true)
    let suite: String
    let defaults: UserDefaults

    init() throws {
        try requireIsolatedStartupProcess()
        let suite = "StartupHardware-\(UUID().uuidString)"
        self.suite = suite
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func makeModel(
        wing: WingController? = nil,
        hardware: HardwareServiceFactories,
        launchControlXLStore: JSONFileStore? = nil
    ) -> AppModel {
        let modelDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AppModel(
            assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            assistantProviderSettings: AssistantProviderSettings(
                defaults: defaults, credentials: MemoryAssistantCredentialStore()),
            wing: wing,
            hardware: hardware,
            launchControlXLStore: launchControlXLStore
                ?? JSONFileStore(directory: modelDirectory.appendingPathComponent("lcxl"), cloud: nil),
            domainStore: JSONFileStore(directory: modelDirectory.appendingPathComponent("domain"), cloud: nil),
            assistantConversationStore: AssistantConversationStore(
                local: LocalAssistantHistoryBackend(
                    directory: modelDirectory.appendingPathComponent("history"),
                    legacyFileURL: modelDirectory.appendingPathComponent("legacy-history.json")),
                cloud: nil))
    }

    func finish(_ models: AppModel...) async {
        for model in models {
            if model.launchControlXL.configuration.mode != .disabled {
                await model.launchControlXL.setMode(.disabled)
            }
            await model.wing.disconnect()
            await model.awaitDomainScheduledSaveSnapshots()
            await model.awaitSiriEntityIndexingSnapshot()
        }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
