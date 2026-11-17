import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

final class InspectionTestSignal<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var observers: [UUID: @Sendable (Value) -> Void] = [:]
    }
    private let state = Mutex(State())

    var isSignalled: Bool { state.withLock { $0.value != nil } }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            _ = observe { continuation.resume(returning: $0) }
        }
    }

    func observe(_ observer: @escaping @Sendable (Value) -> Void) -> UUID {
        let token = UUID()
        let ready: Value? = state.withLock { state in
            if let value = state.value { return value }
            state.observers[token] = observer
            return nil
        }
        if let ready { observer(ready) }
        return token
    }

    func removeObserver(_ token: UUID) {
        state.withLock { $0.observers[token] = nil }
    }

    func signal(_ value: Value) {
        let observers: [@Sendable (Value) -> Void] = state.withLock { state in
            guard state.value == nil else { return [] }
            state.value = value
            let observers = Array(state.observers.values)
            state.observers.removeAll()
            return observers
        }
        for observer in observers { observer(value) }
    }
}

final class InspectionTestGate: Sendable {
    static let mainThreadFailure: Comment = "Inspection test gate must not block the main thread"
    let entered = InspectionTestSignal<Void>()
    private let released = InspectionTestSignal<Void>()
    private let semaphore = DispatchSemaphore(value: 0)
    private let used = Mutex(false)
    let blockedOnMain = Mutex(false)

    func pause() async {
        entered.signal(())
        await released.wait()
    }

    func blockOnce() {
        guard used.withLock({ used in
            if used { return false }
            used = true
            return true
        }) else { return }
        let onMain = Thread.isMainThread
        blockedOnMain.withLock { $0 = onMain }
        entered.signal(())
        guard !onMain else {
            Issue.record(Self.mainThreadFailure)
            return
        }
        semaphore.wait()
    }

    func release() {
        released.signal(())
        semaphore.signal()
    }
}

/// Only an inert lifetime witness: no native access or provider adapter is involved.
private final class InspectionAccessWitness {
    let probe: InspectionAcquisitionProbe

    init(_ probe: InspectionAcquisitionProbe) {
        self.probe = probe
        probe.observations.withLock { $0.witnesses += 1 }
    }

    deinit {
        probe.observations.withLock { $0.witnesses -= 1 }
    }
}

final class InspectionAcquisitionProbe: Sendable {
    enum Stage: Hashable {
        case beforeLoader, chunk, decoded, cleanup
    }
    struct Observations {
        var calls = 0
        var active = 0
        var maximumActive = 0
        var witnesses = 0
        var loaderEntries = 0
        var cancelledAtLoaderEntry = false
        var decoded = 0
    }

    let stages = Mutex<Set<Stage>>([])
    let observations = Mutex(Observations())
    let beforeLoader = InspectionTestGate()
    let chunk = InspectionTestGate()
    let decoded = InspectionTestGate()
    let cleanup = InspectionTestGate()

    nonisolated func load(at root: URL) async throws(ProjectPackageInspectionRefusal) -> ProjectPackageInspection {
        let stages = stages.withLock { $0 }
        observations.withLock {
            $0.calls += 1
            $0.active += 1
            $0.maximumActive = max($0.maximumActive, $0.active)
        }
        let witness = InspectionAccessWitness(self)
        defer {
            if stages.contains(.cleanup) { cleanup.blockOnce() }
            withExtendedLifetime(witness) {}
            observations.withLock { $0.active -= 1 }
        }
        if stages.contains(.beforeLoader) { await beforeLoader.pause() }
        var loader = ProjectPackageInspectionLoader()
        if stages.contains(.chunk) {
            loader.chunkHookForTesting = { [chunk] _, _ in chunk.blockOnce() }
        }
        observations.withLock {
            $0.loaderEntries += 1
            $0.cancelledAtLoaderEntry = Task.isCancelled
        }
        let inspection: ProjectPackageInspection
        do throws(ProjectPackageInspectionRefusal) {
            inspection = try await loader.load(at: root)
        } catch {
            // If failure skipped an armed gate, cleanup must not prevent completion winning its wait.
            if stages.contains(.decoded) || (stages.contains(.chunk) && !chunk.entered.isSignalled) {
                releaseAll()
            }
            throw error
        }
        observations.withLock { $0.decoded += 1 }
        if stages.contains(.decoded) { await decoded.pause() }
        // Deliberately return success even when cancelled here: the owner must reject publication.
        return inspection
    }

    func releaseAll() {
        beforeLoader.release()
        chunk.release()
        decoded.release()
        cleanup.release()
    }
}

@MainActor
final class InspectionSessionFixture {
    enum EntryFailure: Error, Equatable, Sendable {
        case completedBeforeEntry(ProjectPackageInspectionRequest.Outcome?)
    }

    let scratch: URL
    let original: URL
    let replacement: URL
    let probe = InspectionAcquisitionProbe()
    let session: ProjectPackageInspectionSession
    private var requests: [ProjectPackageInspectionRequest] = []
    private var completionObservers: [Task<Void, Never>] = []

    init() throws {
        let scratch = try PackageIOTestSupport.scratch()
        self.scratch = scratch
        do {
            original = try PackageIOTestSupport.makeInspectablePackage(
                in: PackageIOTestSupport.scratchChild(scratch, "original")
            )
            var files = PackageIOTestSupport.inspectableFiles
            files["unknown.bin"] = Data([9, 8, 7])
            replacement = try PackageIOTestSupport.makeInspectablePackage(
                in: PackageIOTestSupport.scratchChild(scratch, "replacement"), files: files
            )
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        session = ProjectPackageInspectionSession(operation: { [probe] url throws(ProjectPackageInspectionRefusal) in
            try await probe.load(at: url)
        })
    }

    func begin(
        _ window: ProjectPackageInspectionSession.Registration, at root: URL? = nil
    ) throws -> ProjectPackageInspectionRequest {
        let request = try session.beginInspection(at: root ?? original, in: window)
        requests.append(request)
        return request
    }

    func retain(
        _ window: ProjectPackageInspectionSession.Registration
    ) async throws -> ProjectPackageInspection {
        let request = try begin(window)
        await request.join()
        #expect(request.outcome == .published)
        return try #require(try session.inspection(in: window))
    }

    func waitForEntry(
        _ gate: InspectionTestGate, of request: ProjectPackageInspectionRequest
    ) async throws(EntryFailure) {
        let result = InspectionTestSignal<Result<Void, EntryFailure>>()
        let token = gate.entered.observe { result.signal(.success(())) }
        defer { gate.entered.removeObserver(token) }
        // Only completion is observed by a task; no losing child waits forever for an unentered gate.
        completionObservers.append(Task {
            await request.join()
            result.signal(.failure(.completedBeforeEntry(request.outcome)))
        })
        try await result.wait().get()
    }

    private func cleanUp() async {
        probe.releaseAll()
        for request in requests { await request.join() }
        for observer in completionObservers { await observer.value }
        #expect(probe.observations.withLock { $0.active } == 0)
        #expect(probe.observations.withLock { $0.witnesses } == 0)
        #expect(!probe.chunk.blockedOnMain.withLock { $0 })
        #expect(!probe.cleanup.blockedOnMain.withLock { $0 })
        try? FileManager.default.removeItem(at: scratch)
    }

    static func run(_ body: @MainActor (InspectionSessionFixture) async throws -> Void) async throws {
        let fixture = try InspectionSessionFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }
}
