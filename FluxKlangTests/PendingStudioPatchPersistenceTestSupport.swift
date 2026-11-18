import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

actor PendingPersistenceGate {
    private let entries: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init() {
        (entries, signal) = AsyncStream<Void>.makeStream()
    }

    func enter() async {
        entered = true
        signal.yield(())
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
        signal.finish()
    }

    func waitForEntry() async -> Bool {
        if entered { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [entries] in
                for await _ in entries { return true }
                return false
            }
            group.addTask {
                // Deadline only detects failure to enter; time never establishes completion.
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
    }
}

// Scheduling only: every outcome is returned unchanged from the actual store.
actor PendingPersistenceForwarder: PendingStudioPatchPersisting {
    enum Point: Hashable {
        case beforeLoad(Int), afterLoad(Int), beforeSave(Int), afterSave(Int)
    }

    let store: PendingStudioPatchStore
    private var gates: [Point: PendingPersistenceGate] = [:]
    private var closed = false
    private var loads = 0
    private(set) var snapshots: [StudioPatchDraft?] = []

    init(store: PendingStudioPatchStore) {
        self.store = store
    }

    func hold(_ point: Point) -> PendingPersistenceGate {
        precondition(gates[point] == nil && !closed)
        let gate = PendingPersistenceGate()
        gates[point] = gate
        return gate
    }

    private func pause(_ point: Point) async {
        if !closed { await gates[point]?.enter() }
    }

    func load() async -> PendingStudioPatchLoadOutcome {
        loads += 1
        let index = loads
        await pause(.beforeLoad(index))
        let outcome = await store.load()
        await pause(.afterLoad(index))
        return outcome
    }

    func save(_ draft: StudioPatchDraft?) async -> PendingStudioPatchMutationOutcome {
        snapshots.append(draft)
        let index = snapshots.count
        await pause(.beforeSave(index))
        let outcome = await store.save(draft)
        await pause(.afterSave(index))
        return outcome
    }

    func finish() async {
        closed = true
        for gate in gates.values { await gate.release() }
    }
}

@MainActor
final class PendingPersistenceFixture {
    let root: URL
    let file: URL
    let store: PendingStudioPatchStore
    let forwarding: PendingPersistenceForwarder
    let owner: AssistantCoordinator
    let context: AssistantToolContext
    private var cancellations: [@MainActor () -> Void] = []
    private var joins: [@MainActor () async -> Void] = []
    private var closed = false

    init(root: URL) {
        self.root = root
        file = root.appendingPathComponent("pending/draft.json")
        store = PendingStudioPatchStore(fileURL: file, directory: root)
        forwarding = PendingPersistenceForwarder(store: store)
        owner = AssistantCoordinator(draftStore: forwarding)
        let first = Equipment(name: "First", outputs: ["Out"])
        let second = Equipment(name: "Second", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: first.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: second.id, outputPort: 0)
        ])
        context = AssistantToolContext(
            currentScreen: .studio, connection: .init(status: .disconnected, detail: nil, isDemo: false),
            equipment: [first, second], homeConnections: home, effectiveConnections: home,
            activeMoves: [], environments: [], activeEnvironmentID: nil, presets: [], resources: [],
            validationIssues: [], graph: StudioGraph(), endpoints: [], effects: [],
            globalConnections: GlobalStudioConnections(home: home), liveWing: .unavailable)
    }

    static func run(_ body: @MainActor (PendingPersistenceFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14b2-\(UUID().uuidString)", isDirectory: true)
        let fixture = PendingPersistenceFixture(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            try await body(fixture)
        } catch {
            await fixture.finish()
            try FileManager.default.removeItem(at: root)
            throw error
        }
        await fixture.finish()
        try FileManager.default.removeItem(at: root)
    }

    func start<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value
    ) -> Task<Value, Never> {
        precondition(!closed)
        let task = Task { await operation() }
        cancellations.append { task.cancel() }
        joins.append { _ = await task.value }
        return task
    }

    private func finish() async {
        closed = true
        for cancel in cancellations { cancel() }
        await forwarding.finish()
        for join in joins { await join() }
    }

    func draft(_ source: Int = 0) -> StudioPatchDraft {
        StudioWiringAdvisor.build(
            request: .init(sourceInstrumentIDs: [context.equipment[source].id]),
            equipment: context.equipment, effects: context.effects,
            connections: context.globalConnections, currentGraph: context.graph,
            environmentID: context.activeEnvironmentID)
    }

    func build(_ source: Int = 0) async throws -> StudioPatchDraft {
        _ = await owner.perform(
            .buildStudioDraft(.init(sourceInstrumentIDs: [context.equipment[source].id])), context: context)
        return try #require(owner.pendingStudioDraft)
    }

    func commit(_ draft: StudioPatchDraft) async -> Bool {
        await owner.commitPreparedRouting(
            draft, expectedPending: owner.pendingStudioDraft, preparedContext: context, currentContext: context)
    }

    func attempt() throws -> PendingStudioPatchStorageAttempt {
        try #require(owner.latestStorageAttempt)
    }
}

// Answers every request with the same text. The first request first runs another request's draft mutation.
actor OvertakingCopilotHTTP: AssistantHTTPClient {
    static let answer = "Own Copilot answer."
    private let overtake: @MainActor @Sendable () async -> Void
    private(set) var requests = 0
    init(overtake: @escaping @MainActor @Sendable () async -> Void) { self.overtake = overtake }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        if requests == 1 { await overtake() }
        let body = #"{"choices":[{"message":{"role":"assistant","content":"\#(Self.answer)"}}]}"#
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
