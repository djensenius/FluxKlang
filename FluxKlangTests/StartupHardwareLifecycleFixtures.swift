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
    private var onMessages: (([MIDIControlChange]) -> Void)?
    private var onSourcesChanged: (([String]) -> Void)?

    func start(
        sourceNameContains: [String],
        onMessages: @escaping ([MIDIControlChange]) -> Void,
        onSourcesChanged: @escaping ([String]) -> Void
    ) {
        starts.append(sourceNameContains)
        self.onMessages = onMessages
        self.onSourcesChanged = onSourcesChanged
    }

    func stop() {
        stops += 1
        onSourcesChanged?([])
    }

    func reportSources(_ names: [String]) {
        onSourcesChanged?(names)
    }

    func send(_ messages: [MIDIControlChange]) {
        onMessages?(messages)
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
