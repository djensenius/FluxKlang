import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AssistantAuthorizedCapability: Hashable, Sendable {
    case help
    case inspect
    case buildPendingDraft
    case writeWing
}

enum AssistantToolAuthorizationError: Error, Equatable {
    case denied(AssistantAuthorizedCapability)
}

struct AssistantToolAuthorizer: Sendable {
    let allowed: Set<AssistantAuthorizedCapability>

    static let model = AssistantToolAuthorizer(allowed: [.help, .inspect, .buildPendingDraft])

    func authorize(_ capability: AssistantAuthorizedCapability) throws {
        guard allowed.contains(capability) else {
            throw AssistantToolAuthorizationError.denied(capability)
        }
    }
}

struct AssistantGeneratorRouter: AssistantGenerating {
    let model: any AssistantGenerating
    let fallback: any AssistantGenerating

    func availability() async -> AssistantModelAvailability {
        await model.availability()
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let generator = await model.availability() == .ready ? model : fallback
                do {
                    for try await event in generator.stream(request) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#if canImport(FoundationModels)
struct FoundationModelAssistantGenerator: AssistantGenerating {
    let coordinator: AssistantCoordinator
    var authorizer = AssistantToolAuthorizer.model

    func availability() async -> AssistantModelAvailability {
        guard #available(iOS 27, macOS 27, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .intelligenceDisabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .failed("Unknown model availability state.")
        }
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        guard #available(iOS 27, macOS 27, *) else {
            return AsyncThrowingStream { $0.finish(throwing: AssistantModelError.unsupportedOS) }
        }
        return streamOnOS27(request)
    }

    @available(iOS 27, macOS 27, *)
    private func streamOnOS27(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let initialDraft = await coordinator.pendingStudioDraft
                    let tools: [any Tool] = [
                        AssistantHelpFoundationTool(authorizer: authorizer),
                        AssistantContextFoundationTool(
                            context: request.context,
                            authorizer: authorizer
                        ),
                        AssistantDraftFoundationTool(
                            context: request.context,
                            coordinator: coordinator,
                            authorizer: authorizer
                        )
                    ]
                    let session = LanguageModelSession(
                        model: SystemLanguageModel.default,
                        tools: tools,
                        instructions: """
                        You are FluxKlang's focused, on-device assistant. Answer only about this app and the \
                        supplied Studio state. Use tools for app facts. Never claim to change a WING console. \
                        The only change-capable tool may create a pending Studio draft that the user must review. \
                        Be concise, describe uncertainty, and never invent equipment, connections, or validation.
                        """
                    )
                    for try await snapshot in session.streamResponse(to: boundedPrompt(request)) {
                        try Task.checkCancellation()
                        continuation.yield(.text(snapshot.content))
                    }
                    if let draft = await coordinator.pendingStudioDraft, draft != initialDraft {
                        continuation.yield(.cards(Self.cards(for: draft)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func boundedPrompt(_ request: AssistantGenerationRequest) -> String {
        let summary = String(request.summary.prefix(1_200))
        let turns = request.recentMessages.suffix(8).map {
            "\($0.role.rawValue): \(String($0.text.prefix(1_000)))"
        }.joined(separator: "\n")
        return """
        Conversation summary:
        \(summary.isEmpty ? "No earlier summary." : summary)

        Recent visible turns:
        \(turns.isEmpty ? "No earlier turns." : turns)

        User:
        \(String(request.question.prefix(2_000)))
        """
    }

    private static func cards(for draft: StudioPatchDraft) -> [AssistantCard] {
        var cards: [AssistantCard] = [
            .wiring(
                summary: draft.logicalRoutingSummary.map(\.value),
                cableInstructions: draft.cableInstructions.map(\.instruction.value)
            ),
            .pendingDraft(
                id: draft.id,
                summary: draft.logicalRoutingSummary.map(\.value).joined(separator: "\n"),
                hasErrors: draft.hasErrors
            )
        ]
        if !draft.validation.isEmpty {
            cards.append(.conflicts(draft.validation.map(\.message)))
        }
        return cards
    }
}

enum AssistantModelError: Error {
    case unsupportedOS
}

@available(iOS 27, macOS 27, *)
@Generable(description: "A request for one FluxKlang help topic.")
private struct AssistantHelpArguments {
    var topic: String
}

@available(iOS 27, macOS 27, *)
private struct AssistantHelpFoundationTool: Tool {
    let authorizer: AssistantToolAuthorizer
    let name = "fluxklang_help"
    let description = "Returns authoritative built-in help for one FluxKlang topic."

    func call(arguments: AssistantHelpArguments) async throws -> String {
        try authorizer.authorize(.help)
        let topic = AssistantHelpTopic.allCases.first {
            $0.rawValue.caseInsensitiveCompare(arguments.topic) == .orderedSame
        } ?? .studio
        let entry = FluxKlangHelpCatalog.entry(for: topic)
        return "\(entry.title): \(entry.overview)"
    }
}

@available(iOS 27, macOS 27, *)
@Generable(description: "A request to inspect one read-only FluxKlang state category.")
private struct AssistantContextArguments {
    var category: String
}

@available(iOS 27, macOS 27, *)
private struct AssistantContextFoundationTool: Tool {
    let context: AssistantToolContext
    let authorizer: AssistantToolAuthorizer
    let name = "inspect_fluxklang"
    let description = """
        Reads one category: screen, connection, equipment, wiring, moves, environments, presets, \
        resources, validation, or studio.
        """

    func call(arguments: AssistantContextArguments) async throws -> String {
        try authorizer.authorize(.inspect)
        let result: AssistantToolResult = switch arguments.category.lowercased() {
        case "connection": .connectionState(context.connection)
        case "equipment": .equipment(context.equipment)
        case "wiring": .effectiveConnections(context.effectiveConnections)
        case "moves": .activeMoves(context.activeMoves)
        case "environments": .environments(context.environments)
        case "presets": .presets(context.presets)
        case "resources": .resources(context.resources)
        case "validation": .validationIssues(context.validationIssues)
        case "studio": .studioGraph(context.graph)
        default: .currentScreen(context.currentScreen)
        }
        return try AssistantFallbackResponder.response(
            to: .live(arguments.category, requires: [result.grounding]),
            groundedBy: [result]
        )
    }
}

@available(iOS 27, macOS 27, *)
@Generable(description: "A request to create a review-only Studio wiring draft.")
private struct AssistantDraftArguments {
    var sourceNames: [String]
    var effectNames: [String]
    var destination: String
}

@available(iOS 27, macOS 27, *)
private struct AssistantDraftFoundationTool: Tool {
    let context: AssistantToolContext
    let coordinator: AssistantCoordinator
    let authorizer: AssistantToolAuthorizer
    let name = "build_pending_studio_draft"
    let description = """
        Creates a pending Studio draft from exact visible equipment/effect names. It never writes to WING \
        and the user must review and accept the draft.
        """

    func call(arguments: AssistantDraftArguments) async throws -> String {
        try authorizer.authorize(.buildPendingDraft)
        let sources = context.equipment.filter { equipment in
            arguments.sourceNames.contains {
                $0.caseInsensitiveCompare(equipment.name) == .orderedSame
            }
        }.map(\.id)
        let effects = context.effects.filter { effect in
            arguments.effectNames.contains {
                $0.caseInsensitiveCompare(effect.name) == .orderedSame
            }
        }.map(\.id)
        let destination: StudioEndpointDestination =
            arguments.destination.lowercased().contains("space") ? .space : .finalMix
        let result = await coordinator.perform(
            .buildStudioDraft(StudioWiringRequest(
                sourceInstrumentIDs: sources,
                effectChainIDs: effects,
                destination: destination
            )),
            context: context
        )
        return try AssistantFallbackResponder.response(
            to: .live("Build pending draft", requires: [.pendingDraft]),
            groundedBy: [result]
        )
    }
}
#else
struct FoundationModelAssistantGenerator: AssistantGenerating {
    let coordinator: AssistantCoordinator
    var authorizer = AssistantToolAuthorizer.model

    func availability() async -> AssistantModelAvailability {
        .unsupportedOS
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: AssistantModelError.unsupportedOS) }
    }
}
#endif
