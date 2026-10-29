import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct CopilotAssistantTests {
    @Test func settingsKeepTokenOutOfUserDefaults() throws {
        let suite = "CopilotAssistantTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentialStore()
        let settings = AssistantProviderSettings(defaults: defaults, credentials: credentials)

        settings.provider = .githubCopilot
        settings.copilotModel = "gpt-4.1"
        settings.saveCopilotToken("secret-token")

        #expect(settings.hasCopilotToken)
        #expect(settings.copilotConfiguration()?.token == "secret-token")
        #expect(settings.copilotConfiguration()?.model == "gpt-4.1")
        #expect(!defaults.dictionaryRepresentation().values.contains {
            ($0 as? String) == "secret-token"
        })

        settings.removeCopilotToken()
        #expect(!settings.hasCopilotToken)
        #expect(settings.copilotConfiguration() == nil)
    }

    @Test func copilotUsesRequiredHeadersAndReturnsText() async throws {
        let client = MockAssistantHTTPClient(responses: [
            Self.response("""
            {"choices":[{"message":{"role":"assistant","content":"WING is disconnected."}}]}
            """)
        ])
        let generator = CopilotAssistantGenerator(
            configuration: CopilotAssistantConfiguration(token: "token", model: "gpt-4o"),
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            httpClient: client
        )

        let text = try await responseText(from: generator)
        let request = try #require(await client.requests().first)

        #expect(text == "WING is disconnected.")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "Copilot-Integration-Id") == "vscode-chat")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        let names = tools.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        #expect(names == [
            "fluxklang_help",
            "inspect_fluxklang",
            "build_pending_studio_draft"
        ])
    }

    @Test func copilotExecutesReadOnlyToolLoop() async throws {
        let client = MockAssistantHTTPClient(responses: [
            Self.response("""
            {
              "choices":[{
                "message":{
                  "role":"assistant",
                  "content":null,
                  "tool_calls":[{
                    "id":"call-1",
                    "type":"function",
                    "function":{"name":"inspect_fluxklang","arguments":"{\\"category\\":\\"connection\\"}"}
                  }]
                }
              }]
            }
            """),
            Self.response("""
            {"choices":[{"message":{"role":"assistant","content":"The WING is disconnected."}}]}
            """)
        ])
        let generator = CopilotAssistantGenerator(
            configuration: CopilotAssistantConfiguration(token: "token", model: "gpt-4o"),
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            httpClient: client
        )

        let text = try await responseText(from: generator)
        let requests = await client.requests()
        let secondBody = try #require(requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let toolMessage = messages.first { ($0["role"] as? String) == "tool" }

        #expect(text == "The WING is disconnected.")
        #expect(requests.count == 2)
        #expect((toolMessage?["content"] as? String)?.localizedCaseInsensitiveContains("disconnected") == true)
    }

    @Test(arguments: [
        "Wire my OP-1 Field to the final mix.",
        "Help me route OP-1 Field to speakers.",
        "How do I connect OP-1 Field to speakers?"
    ])
    func copilotUsesVerifiedDraftReplyInsteadOfModelCommentary(_ question: String) async throws {
        let synth = Equipment(name: "OP-1 Field", outputs: ["Left", "Right"], isStereo: true)
        let context = emptyContext(
            equipment: [synth],
            connections: GlobalStudioConnections(home: StudioHomeConnections(inputs: [
                StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0),
                StudioInputConnection(connector: 2, equipmentID: synth.id, outputPort: 1)
            ]))
        )
        let client = MockAssistantHTTPClient(responses: [
            Self.response("""
            {
              "choices":[{
                "message":{
                  "role":"assistant",
                  "content":null,
                  "tool_calls":[{
                    "id":"call-1",
                    "type":"function",
                    "function":{
                      "name":"build_pending_studio_draft",
            "arguments":"{\\"sourceNames\\":[\\"OP-1 Field\\"],\\"effectNames\\":[],\\"destination\\":\\"Final Mix\\"}"
                    }
                  }]
                }
              }]
            }
            """),
            Self.response("""
            {
              "choices":[{
                "message":{
                  "role":"assistant",
                  "content":"I cannot automatically remove OP-1 Field or create a new configuration."
                }
              }]
            }
            """)
        ])
        let generator = CopilotAssistantGenerator(
            configuration: CopilotAssistantConfiguration(token: "token", model: "gpt-4o"),
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            httpClient: client
        )

        let text = try await responseText(
            from: generator,
            question: question,
            context: context
        )

        #expect(text.contains("Created a review-only Studio wiring draft"))
        #expect(text.contains("OP-1 Field"))
        #expect(!text.contains("cannot automatically"))
    }

    @Test func copilotDoesNotCreateAppendDraftForReplacementRequest() async throws {
        let synth = Equipment(name: "OP-1 Field", outputs: ["Left", "Right"], isStereo: true)
        let context = emptyContext(equipment: [synth])
        let coordinator = AssistantCoordinator(draftStore: MemoryDraftStore())
        let client = MockAssistantHTTPClient(responses: [
            Self.response("""
            {
              "choices":[{
                "message":{
                  "role":"assistant",
                  "content":null,
                  "tool_calls":[{
                    "id":"call-1",
                    "type":"function",
                    "function":{
                      "name":"build_pending_studio_draft",
            "arguments":"{\\"sourceNames\\":[\\"OP-1 Field\\"],\\"effectNames\\":[],\\"destination\\":\\"Final Mix\\"}"
                    }
                  }]
                }
              }]
            }
            """),
            Self.response("""
            {
              "choices":[{
                "message":{
                  "role":"assistant",
                  "content":"I can only append a path; start a new configuration before drafting another one."
                }
              }]
            }
            """)
        ])
        let generator = CopilotAssistantGenerator(
            configuration: CopilotAssistantConfiguration(token: "token", model: "gpt-4o"),
            coordinator: coordinator,
            httpClient: client
        )

        let text = try await responseText(
            from: generator,
            question: "Can we do a totally new one? I don't want to use OP-1 Field at all.",
            context: context
        )

        #expect(coordinator.pendingStudioDraft == nil)
        #expect(text.contains("start a new configuration"))
    }

    @Test func copilotUsesGearMentionedByUserInsteadOfIncorrectToolArguments() async throws {
        let flux = Equipment(name: "SOMA Flux", outputs: ["Left", "Right"], isStereo: true)
        let astrolab = Equipment(name: "AstroLab 88", outputs: ["Left", "Right"], isStereo: true)
        let op1 = Equipment(name: "OP-1 Field", outputs: ["Left", "Right"], isStereo: true)
        let opxy = Equipment(name: "OP-XY", outputs: ["Left", "Right"], isStereo: true)
        let equipment = [flux, astrolab, op1, opxy]
        let connections = GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: flux.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: flux.id, outputPort: 1),
            StudioInputConnection(connector: 3, equipmentID: astrolab.id, outputPort: 0),
            StudioInputConnection(connector: 4, equipmentID: astrolab.id, outputPort: 1),
            StudioInputConnection(connector: 5, equipmentID: op1.id, outputPort: 0),
            StudioInputConnection(connector: 6, equipmentID: opxy.id, outputPort: 0)
        ]))
        let coordinator = AssistantCoordinator(draftStore: MemoryDraftStore())
        let client = MockAssistantHTTPClient(responses: [
            Self.response("""
            {
              "choices":[{
                "message":{
                  "role":"assistant",
                  "content":null,
                  "tool_calls":[{
                    "id":"call-1",
                    "type":"function",
                    "function":{
                      "name":"build_pending_studio_draft",
            "arguments":"{\\"sourceNames\\":[\\"OP-1 Field\\"],\\"effectNames\\":[],\\"destination\\":\\"Final Mix\\"}"
                    }
                  }]
                }
              }]
            }
            """),
            Self.response("""
            {"choices":[{"message":{"role":"assistant","content":"The draft is ready."}}]}
            """)
        ])
        let generator = CopilotAssistantGenerator(
            configuration: CopilotAssistantConfiguration(token: "token", model: "gpt-4o"),
            coordinator: coordinator,
            httpClient: client
        )

        _ = try await responseText(
            from: generator,
            question: "Can you make a new setup? I want my Flux and Astrolab to go out of the main speakers.",
            context: emptyContext(equipment: equipment, connections: connections)
        )

        let summary = try #require(coordinator.pendingStudioDraft?.logicalRoutingSummary.first?.value)
        #expect(summary.contains("SOMA Flux"))
        #expect(summary.contains("AstroLab 88"))
        #expect(!summary.contains("OP-1 Field"))
        #expect(!summary.contains("OP-XY"))
        #expect(coordinator.pendingStudioDraft?.applicationMode == .replace)
    }

    private func responseText(from generator: some AssistantGenerating) async throws -> String {
        try await responseText(
            from: generator,
            question: "Is the WING connected?",
            context: emptyContext()
        )
    }

    private func responseText(
        from generator: some AssistantGenerating,
        question: String,
        context: AssistantToolContext
    ) async throws -> String {
        var text = ""
        for try await event in generator.stream(AssistantGenerationRequest(
            question: question,
            recentMessages: [],
            summary: "",
            context: context
        )) {
            if case .text(let value) = event {
                text = value
            }
        }
        return text
    }

    private func emptyContext(
        equipment: [Equipment] = [],
        connections: GlobalStudioConnections = GlobalStudioConnections()
    ) -> AssistantToolContext {
        AssistantToolContext(
            currentScreen: .assistant,
            connection: AssistantConnectionState(status: .disconnected, detail: nil, isDemo: false),
            equipment: equipment,
            homeConnections: connections.home,
            effectiveConnections: connections.effectiveHome,
            activeMoves: [],
            environments: [],
            activeEnvironmentID: nil,
            presets: [],
            resources: [],
            validationIssues: [],
            graph: StudioGraph(),
            endpoints: [],
            effects: [],
            globalConnections: connections
        )
    }

    private static func response(_ json: String, status: Int = 200) -> MockHTTPResponse {
        MockHTTPResponse(status: status, data: Data(json.utf8))
    }
}

private final class MemoryCredentialStore: AssistantCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    func setValue(_ value: String, for account: String) {
        lock.withLock { values[account] = value }
    }

    func removeValue(for account: String) {
        lock.withLock { values[account] = nil }
    }
}

private actor MemoryDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?

    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft }
}

private struct MockHTTPResponse: Sendable {
    var status: Int
    var data: Data
}

private actor MockAssistantHTTPClient: AssistantHTTPClient {
    private var queuedResponses: [MockHTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [MockHTTPResponse]) {
        queuedResponses = responses
    }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queuedResponses.isEmpty else {
            throw CopilotTestError.missingResponse
        }
        let response = queuedResponses.removeFirst()
        let url = request.url ?? URL(string: "https://api.githubcopilot.com")!
        return (
            response.data,
            HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private enum CopilotTestError: Error {
    case missingResponse
}
