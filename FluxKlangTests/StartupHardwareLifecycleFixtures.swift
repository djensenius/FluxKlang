import Foundation
import Synchronization
@testable import FluxKlang

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
