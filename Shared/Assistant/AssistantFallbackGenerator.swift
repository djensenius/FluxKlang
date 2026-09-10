import Foundation

struct AssistantFallbackGenerator: AssistantGenerating {
    let coordinator: AssistantCoordinator

    func availability() async -> AssistantModelAvailability {
        .unsupportedOS
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let reply = try await response(to: request)
                    try Task.checkCancellation()
                    continuation.yield(.text(reply.text))
                    if !reply.cards.isEmpty {
                        continuation.yield(.cards(reply.cards))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    private func response(
        to request: AssistantGenerationRequest
    ) async throws -> (text: String, cards: [AssistantCard]) {
        let normalized = request.question.lowercased()
        if let topic = helpTopic(in: normalized) {
            let entry = FluxKlangHelpCatalog.entry(for: topic)
            let result = AssistantToolResult.help(entry)
            let text = try AssistantFallbackResponder.response(
                to: .catalog(request.question),
                groundedBy: [result]
            )
            return (text, [.help(topic: topic, title: entry.title, overview: entry.overview)])
        }
        if normalized.contains("move") {
            let result = await coordinator.perform(.listActiveMoves, context: request.context)
            let text = try AssistantFallbackResponder.response(
                to: .live(request.question, requires: [.activeMoves]),
                groundedBy: [result]
            )
            let moves = request.context.activeMoves.map { move in
                let name = request.context.equipment.first { $0.id == move.equipmentID }?.name
                    ?? "Unknown equipment"
                return "\(name) is using a Temporary Move."
            }
            return (text, [.moves(moves.isEmpty ? ["No active Temporary Moves."] : moves)])
        }
        if normalized.contains("conflict") || normalized.contains("validation") {
            let result = await coordinator.perform(.explainValidationIssues, context: request.context)
            let text = try AssistantFallbackResponder.response(
                to: .live(request.question, requires: [.validation]),
                groundedBy: [result]
            )
            return (text, [.conflicts(request.context.validationIssues.map(\.value))])
        }
        if normalized.contains("pending") || normalized.contains("draft") {
            let result = await coordinator.perform(.validatePendingStudioDraft, context: request.context)
            let text = try AssistantFallbackResponder.response(
                to: .live(request.question, requires: [.pendingDraft]),
                groundedBy: [result]
            )
            return (text, cards(for: coordinator.pendingStudioDraft))
        }
        if normalized.contains("wire") || normalized.contains("connect") || normalized.contains("patch") {
            let sourceIDs = request.context.equipment.filter {
                normalized.contains($0.name.lowercased())
            }.map(\.id)
            if !sourceIDs.isEmpty {
                let result = await coordinator.perform(
                    .buildStudioDraft(StudioWiringRequest(sourceInstrumentIDs: sourceIDs)),
                    context: request.context
                )
                let text = try AssistantFallbackResponder.response(
                    to: .live(request.question, requires: [.pendingDraft]),
                    groundedBy: [result]
                )
                return (text, cards(for: coordinator.pendingStudioDraft))
            }
            return (
                "Choose one or more source instruments in the wiring form so I can create a reviewable draft.",
                []
            )
        }
        let results = [
            await coordinator.perform(.describeCurrentScreen, context: request.context),
            await coordinator.perform(.inspectConnectionState, context: request.context)
        ]
        let text = try AssistantFallbackResponder.response(
            to: .live(request.question, requires: [.currentScreen, .connectionState]),
            groundedBy: results
        )
        return (text + "\nAsk about help, wiring, conflicts, moves, or a pending draft.", [])
    }

    private func helpTopic(in text: String) -> AssistantHelpTopic? {
        AssistantHelpTopic.allCases.first { text.contains($0.rawValue.lowercased()) }
            ?? (text.contains("help") ? .studio : nil)
    }

    private func cards(for draft: StudioPatchDraft?) -> [AssistantCard] {
        guard let draft else { return [] }
        let summary = draft.logicalRoutingSummary.map(\.value)
        let cables = draft.cableInstructions.map(\.instruction.value)
        var result: [AssistantCard] = [
            .wiring(summary: summary, cableInstructions: cables),
            .pendingDraft(
                id: draft.id,
                summary: summary.joined(separator: "\n"),
                hasErrors: draft.hasErrors
            )
        ]
        if !draft.validation.isEmpty {
            result.append(.conflicts(draft.validation.map(\.message)))
        }
        return result
    }
}
