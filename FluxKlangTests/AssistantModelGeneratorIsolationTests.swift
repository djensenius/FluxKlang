import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantModelGeneratorIsolationTests {
    @Test func concreteConstructionIsPassive() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())

        _ = FoundationModelAssistantGenerator(coordinator: coordinator, mirroring: audit)

        expectAudit(audit, attempts: 0)
    }

    @Test func isolatedAvailabilityIsDeterministicWithoutFrameworkAccess() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let generator = FoundationModelAssistantGenerator(coordinator: coordinator, mirroring: audit)

        #expect(await generator.availability() == .deterministic)

        expectAudit(audit, attempts: 1)
    }

    @Test func repeatedStreamsDenyWithoutEventsOrDraftChanges() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let fixture = AssistantRoutingFixture()
        let prior = try fixture.prepared()
        let store = RoutingTestDraftStore()
        #expect(await store.save(prior) == .writeCompleted)
        let coordinator = AssistantCoordinator(draftStore: store)
        await coordinator.load()
        #expect(coordinator.pendingStudioDraft == prior)
        let generator = FoundationModelAssistantGenerator(coordinator: coordinator, mirroring: audit)
        let request = AssistantGenerationRequest(
            question: "Help", recentMessages: [], summary: "", context: fixture.context)
        expectAudit(audit, attempts: 0)

        for attempt in 1...2 {
            try #require(AppPersistence.isTesting)
            try #require(AssistantServiceIsolation.deniesLiveServices)
            var events = 0
            do {
                for try await _ in generator.stream(request) { events += 1 }
                Issue.record("Expected isolation denial")
            } catch AssistantServiceIsolation.AccessError.denied {
                // The concrete boundary must preserve this exact error.
            } catch {
                Issue.record("Expected AssistantServiceIsolation.AccessError.denied")
            }
            #expect(events == 0)
            #expect(coordinator.pendingStudioDraft == prior)
            #expect(await store.load() == .loaded(prior))
            #expect(await store.saves == 1)
            expectAudit(audit, attempts: UInt64(attempt))
        }
    }

    // Local mirrors describe these paths only, not global callsite coverage.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.passiveConstruction, for: .assistantModelGenerator) == 1)
        #expect(snapshot.count(.attempted, for: .assistantModelGenerator) == attempts)
        #expect(snapshot.count(.denied, for: .assistantModelGenerator) == attempts)
        #expect(snapshot.count(.factoryEvaluated, for: .assistantModelGenerator) == 0)
        #expect(snapshot.count(.apiEntered, for: .assistantModelGenerator) == 0)
    }

    // MARK: - Source scan

    /// The directory is found by a file that is not under scan, so a renamed or moved generator file fails the test
    /// instead of skipping it.
    private nonisolated static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Assistant", "../../Sources/FluxKlang/Shared/Assistant"]
        let marker = "AssistantCoordinator.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private nonisolated static let sourcesAreReachable = sourceDirectory() != nil

    /// Neither generator has a tool that can create a draft, so neither may read the coordinator's pending draft to
    /// shape its reply: any change it saw there would belong to another request. Neither may call into the
    /// coordinator at all, which also rules out reading the draft through another member. Foundation Models streaming
    /// is denied in every test host, so this scan stands in for running it. The search is over the raw text, so a
    /// comment that names the property is found too. It is skipped when the sources are not next to the tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the assistant sources are not next to the tests"))
    func modelGeneratorsDoNotReadThePendingDraft() throws {
        let directory = try #require(Self.sourceDirectory(), "the assistant sources are not next to the tests")
        let generators = [
            ("FoundationModelAssistant.swift", "struct FoundationModelAssistantGenerator"),
            ("CopilotAssistantGenerator.swift", "struct CopilotAssistantGenerator")
        ]
        var draftReads: [String] = []
        var coordinatorCalls: [String] = []
        for (name, declaration) in generators {
            let file = directory.appendingPathComponent(name)
            try #require(FileManager.default.fileExists(atPath: file.path), "\(name) was renamed or moved")
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains(declaration), "\(name) declares its generator")
            if text.contains("pendingStudioDraft") { draftReads.append(name) }
            if text.range(of: #"\bcoordinator\s*\."#, options: .regularExpression) != nil {
                coordinatorCalls.append(name)
            }
        }
        #expect(draftReads.isEmpty, "a model generator reads the pending draft")
        #expect(coordinatorCalls.isEmpty, "a model generator calls into the assistant coordinator")
    }
}
