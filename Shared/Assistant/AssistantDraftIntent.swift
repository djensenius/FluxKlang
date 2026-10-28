import Foundation

// swiftlint:disable file_length
private struct ResolvedDestination {
    var kind: StudioEndpointDestination
    var outputConnectors: [WingOutputConnector] = []
    var markers: [String]
    var index: String.Index
}

enum AssistantDraftReply {
    static func text(for draft: StudioPatchDraft) -> String {
        let summary = draft.logicalRoutingSummary.map(\.value).joined(separator: "; ")
        let subject = summary.isEmpty ? "a new Studio path" : summary
        let action = draft.applicationMode == .replace
            ? "Created a review-only replacement Studio draft for"
            : "Created a review-only Studio wiring draft for"
        if draft.hasErrors {
            return "\(action) \(subject). "
                + "Review its validation issues before accepting it."
        }

        return "\(action) \(subject). "
            + "Review the draft card to accept or discard it."
    }
}

enum AssistantDraftIntent {
    static func requestsReplacement(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return [
            "totally new",
            "just ",
            "only ",
            "new setup",
            "new configuration",
            "start over",
            "start a new",
            "from scratch",
            "replace",
            "remove",
            "get rid",
            "clear the current",
            "clear current"
        ].contains { normalized.contains($0) }
    }

    static func mentionedEquipmentIDs(
        in question: String,
        equipment: [Equipment],
        excluding excludedIDs: Set<Equipment.ID> = []
    ) -> [Equipment.ID] {
        let candidates = equipment.filter { !excludedIDs.contains($0.id) }.map {
            ($0.id, $0.name)
        }
        let excluded = Set(excludedIDsMentioned(in: question, candidates: candidates))
        return mentionedIDs(in: question, candidates: candidates).filter {
            !excluded.contains($0)
        }
    }

    static func mentionedEffectIDs(in question: String, effects: [Effect]) -> [Effect.ID] {
        let candidates = effects.map { ($0.id, $0.name) }
        let excluded = Set(excludedIDsMentioned(in: question, candidates: candidates))
        return mentionedIDs(in: question, candidates: candidates).filter {
            !excluded.contains($0)
        }
    }

    static let missingSource = """
        No draft was created because I could not identify a requested source instrument in your message. \
        Name the source gear you want in the new path.
        """

    static func wiringRequest(from request: AssistantGenerationRequest) -> StudioWiringRequest? {
        let current = request.question.lowercased()
        let isRetry = current.contains("try again") || current.contains("connected now")
        guard hasRoutingIntent(current) || isRetry else { return nil }
        let recentUserText = request.recentMessages.suffix(8)
            .filter { $0.role == .user }
            .map(\.text)
            .joined(separator: "\n")
        let groundingText = isRetry ? recentUserText + "\n" + request.question : request.question
        let effectEquipmentIDs = Set(request.context.effects.compactMap(\.equipmentID))
        let resolution = AssistantSourceResolver.resolve(
            groundingText, context: request.context, excluding: effectEquipmentIDs
        )
        let sourceIDs = resolution.equipmentIDs
        guard resolution.clarification == nil, !sourceIDs.isEmpty else { return nil }
        let effectIDs = mentionedEffectIDs(in: groundingText, effects: request.context.effects)
        let scopedRoutes = sourceScopedRoutes(
            in: groundingText,
            context: request.context,
            effects: request.context.effects,
            outputs: request.context.effectiveConnections.outputs
        )
        if scopedRoutes == nil,
           requiresTopologyClarification(groundingText, effectCount: effectIDs.count) {
            return nil
        }
        let routes = scopedRoutes ?? routes(
            in: groundingText,
            sourceIDs: sourceIDs,
            effectIDs: effectIDs,
            effects: request.context.effects,
            outputs: request.context.effectiveConnections.outputs
        )
        guard let primary = routes.first else { return nil }
        var result = StudioWiringRequest(
            sourceInstrumentIDs: primary.sourceInstrumentIDs,
            effectChainIDs: primary.effectChainIDs,
            destination: primary.destination,
            includesDrySignal: primary.includesDrySignal,
            outputConnectors: primary.outputConnectors,
            additionalRoutes: Array(routes.dropFirst()),
            applicationMode: requestsReplacement(groundingText) ? .replace : .append
        )
        result.liveReferences = resolution.references
        return result
    }

    static func clarification(from request: AssistantGenerationRequest) -> String? {
        let question = request.question
        let normalized = question.lowercased()
        guard hasRoutingIntent(normalized), !isInformationalQuestion(normalized) else { return nil }
        let effectEquipmentIDs = Set(request.context.effects.compactMap(\.equipmentID))
        let resolution = AssistantSourceResolver.resolve(
            question, context: request.context, excluding: effectEquipmentIDs
        )
        if let clarification = resolution.clarification { return clarification }
        let sources = resolution.equipmentIDs
        if sources.isEmpty {
            return "Which source instrument should I route?"
        }
        if resolvedDestinations(
            in: question,
            outputs: request.context.effectiveConnections.outputs
        ).isEmpty {
            if question.localizedCaseInsensitiveContains("monitor")
                || question.localizedCaseInsensitiveContains("cue") {
                return """
                Which configured monitor or cue destination do you mean? \
                FluxKlang currently knows Main Speakers and Space, but no named monitor/cue endpoint.
                """
            }
            let names = sources.compactMap { id in
                request.context.equipment.first { $0.id == id }?.name
            }.joined(separator: " and ")
            return "Where should \(names) go: Main Speakers, Space, or both?"
        }
        let effects = mentionedEffectIDs(in: question, effects: request.context.effects)
        if requiresTopologyClarification(question, effectCount: effects.count) {
            let names = effects.compactMap { id in
                request.context.effects.first { $0.id == id }?.name
            }.joined(separator: " and ")
            return "Should \(names) be serial (one into the next) or parallel?"
        }
        return nil
    }

    static func requestsInventory(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return [
            "what is connected", "what equipment is connected", "which instruments are connected",
            "live labels", "wing labels", "channel labels", "input labels",
            "list gear",
            "list equipment",
            "list instruments",
            "what equipment",
            "source instruments",
            "what i have available",
            "what do i have available",
            "inputs and outputs",
            "ins and outs"
        ].contains { normalized.contains($0) }
    }

    static func includesDrySignal(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return ["raw", "dry", "unprocessed", "clean signal"].contains {
            normalized.contains($0)
        }
    }

    static func requestsSourceDraft(_ question: String) -> Bool {
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if requestsDraftAmendment(question) { return true }
        if normalized.range(of: #"^(?:help me (?:to )?|how (?:do i|can i|should i|to) )"#
            + #"(?:route|connect|wire|patch)\b"#, options: .regularExpression) != nil { return true }
        guard !["what ", "why ", "how ", "help ", "explain ", "tell me ", "list ", "show "].contains(where: {
            normalized.hasPrefix($0)
        }) else { return false }
        return hasRoutingIntent(normalized) || requestsDraftAmendment(question)
    }

    /// Only source positions participate in gear/alias lookup. Effect and
    /// destination scribbles are metadata, not extra source instruments.
    static func sourceMentionText(_ question: String) -> String {
        let normalized = question.lowercased()
        let clauses = normalized.replacingOccurrences(of: #"\b(?:and|then)\b|[,;\n]"#,
            with: "\n", options: .regularExpression).components(separatedBy: "\n")
        var continuesSources = true
        return clauses.compactMap { clause -> String? in
            let from = clause.range(of: " from ")
            let hasNewSource = continuesSources || from != nil || clause.contains(" through ")
                || clause.range(of: #"^\s*(?:route|connect|wire|patch|add|include)\b"#,
                                options: .regularExpression) != nil
            let source = from.map { String(clause[$0.upperBound...]) } ?? clause
            let boundary = source.range(of: #"\s+(?:through|via|to|into|towards)\s+"#,
                                        options: .regularExpression)
            continuesSources = hasNewSource && boundary == nil
            guard hasNewSource else { return nil }
            return boundary.map { String(source[..<$0.lowerBound]) } ?? source
        }.joined(separator: " and ")
    }

    private static func hasRoutingIntent(_ normalized: String) -> Bool {
        [
            "setup",
            "speaker",
            "wire",
            "connect",
            "patch",
            "route",
            "go to",
            "send signal",
            "through"
        ].contains { normalized.contains($0) }
    }

    private static func isInformationalQuestion(_ normalized: String) -> Bool {
        ["how is ", "what is ", "why is ", "explain "].contains {
            normalized.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0)
        }
    }

    private static func routes(
        in question: String,
        sourceIDs: [Equipment.ID],
        effectIDs: [Effect.ID],
        effects: [Effect],
        outputs: [StudioOutputConnection]
    ) -> [StudioWiringRoute] {
        let destinations = resolvedDestinations(in: question, outputs: outputs)
        return destinations.flatMap { destination -> [StudioWiringRoute] in
            let clause = destinationClause(markers: destination.markers, in: question)
            let clauseEffects = mentionedEffectIDs(in: clause, effects: effects)
            let explicitlyDry = includesDrySignal(clause)
            let selectedEffects: [Effect.ID]
            if destinations.count == 1 {
                selectedEffects = effectIDs
            } else {
                selectedEffects = explicitlyDry ? [] : (clauseEffects.isEmpty ? effectIDs : clauseEffects)
            }
            let isParallel = question.localizedCaseInsensitiveContains("parallel")
                || question.localizedCaseInsensitiveContains("separately")
            if isParallel, selectedEffects.count > 1 {
                return selectedEffects.enumerated().map { index, effectID in
                    StudioWiringRoute(
                        sourceInstrumentIDs: sourceIDs,
                        effectChainIDs: [effectID],
                        destination: destination.kind,
                        includesDrySignal: index == 0
                            && destinations.count == 1
                            && includesDrySignal(question),
                        outputConnectors: destination.outputConnectors
                    )
                }
            }

            return [StudioWiringRoute(
                sourceInstrumentIDs: sourceIDs,
                effectChainIDs: selectedEffects,
                destination: destination.kind,
                includesDrySignal: destinations.count == 1
                    && !selectedEffects.isEmpty
                    && includesDrySignal(question),
                outputConnectors: destination.outputConnectors
            )]
        }
    }

    private static func sourceScopedRoutes(
        in question: String,
        context: AssistantToolContext,
        effects: [Effect],
        outputs: [StudioOutputConnection]
    ) -> [StudioWiringRoute]? {
        let destinations = resolvedDestinations(in: question, outputs: outputs)
        guard destinations.count == 1 else { return nil }
        let effectEquipmentIDs = Set(effects.compactMap(\.equipmentID))
        let clauses = question.lowercased()
            .replacingOccurrences(of: ",", with: " and ")
            .components(separatedBy: " and ")
        let routes = clauses.compactMap { clause -> StudioWiringRoute? in
            let sources = AssistantSourceResolver.resolve(
                clause, context: context, excluding: effectEquipmentIDs
            ).equipmentIDs
            let clauseEffects = mentionedEffectIDs(in: clause, effects: effects)
            guard !sources.isEmpty, !clauseEffects.isEmpty else { return nil }
            return StudioWiringRoute(
                sourceInstrumentIDs: sources,
                effectChainIDs: clauseEffects,
                destination: destinations[0].kind,
                includesDrySignal: includesDrySignal(clause),
                outputConnectors: destinations[0].outputConnectors
            )
        }
        let distinctSources = Set(routes.flatMap(\.sourceInstrumentIDs))
        return routes.count > 1 && distinctSources.count > 1 ? routes : nil
    }

    private static func requiresTopologyClarification(_ question: String, effectCount: Int) -> Bool {
        guard effectCount > 1 else { return false }
        let normalized = question.lowercased()
        let explicitTopology = [" then ", " into ", " after ", "serial", "parallel", "separately"]
        return !explicitTopology.contains { normalized.contains($0) }
    }

    private static func resolvedDestinations(
        in question: String,
        outputs: [StudioOutputConnection]
    ) -> [ResolvedDestination] {
        let normalized = question.lowercased()
        var candidates: [ResolvedDestination] = [
            ["main speakers", "main speaker", "the speakers", "speakers", "speaker", "the mains", "mains"].compactMap {
                normalized.range(of: $0)?.lowerBound
            }.min().map {
                ResolvedDestination(
                    kind: .finalMix,
                    markers: ["main speakers", "main speaker", "speakers", "speaker", "mains"],
                    index: $0
                )
            },
            normalized.range(of: "space").map {
                ResolvedDestination(kind: .space, markers: ["space"], index: $0.lowerBound)
            }
        ].compactMap { $0 }
        let grouped = Dictionary(grouping: outputs) { output in
            output.destinationName.map(destinationBaseName) ?? ""
        }
        for (name, connections) in grouped
        where !name.isEmpty && !name.localizedCaseInsensitiveContains("main speaker") {
            guard let range = normalized.range(of: name.lowercased()) else { continue }
            candidates.append(ResolvedDestination(
                kind: .custom,
                outputConnectors: connections.map(\.outputConnector).sorted {
                    ($0.bank.rawValue, $0.index) < ($1.bank.rawValue, $1.index)
                },
                markers: [name.lowercased()],
                index: range.lowerBound
            ))
        }
        var seen: Set<String> = []
        return candidates.sorted { $0.index < $1.index }.filter {
            let key = "\($0.kind.rawValue)|\($0.outputConnectors.map(\.label).joined(separator: ","))"
            return seen.insert(key).inserted
        }
    }

    private static func destinationClause(
        markers: [String],
        in question: String
    ) -> String {
        let clauses = question.lowercased()
            .replacingOccurrences(of: ",", with: " and ")
            .components(separatedBy: " and ")
        return clauses.first { clause in
            markers.contains { clause.contains($0) }
        } ?? question
    }

    private static func destinationBaseName(_ name: String) -> String {
        let suffixes = [" left", " right", " l", " r"]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in suffixes where trimmed.lowercased().hasSuffix(suffix) {
            return String(trimmed.dropLast(suffix.count))
        }
        return trimmed
    }

    static func requestsDraftAmendment(_ question: String) -> Bool {
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("and ")
            || normalized.hasPrefix("also ")
            || normalized.hasPrefix("add ")
            || normalized.hasPrefix("what about ")
            || normalized.contains("include ")
    }

    private static func mentionedIDs<ID: Hashable>(
        in question: String,
        candidates: [(id: ID, name: String)]
    ) -> [ID] {
        let questionTokens = tokens(in: question)
        let candidateTokens = candidates.map { tokens(in: $0.name) }
        let tokenCounts = candidateTokens.reduce(into: [String: Int]()) { counts, candidate in
            for token in Set(candidate) where token.count >= 3 {
                counts[token, default: 0] += 1
            }
        }
        return candidates.indices.compactMap { index -> (ID, Int)? in
            let nameTokens = candidateTokens[index]
            let fullNameIndex = candidateTokens.filter { $0 == nameTokens }.count == 1
                ? firstSubsequenceIndex(of: nameTokens, in: questionTokens) : nil
            let prefix = Array(nameTokens.prefix(2))
            let prefixIndex = candidateTokens.filter { Array($0.prefix(2)) == prefix }.count == 1
                ? firstSubsequenceIndex(of: prefix, in: questionTokens) : nil
            let uniqueTokenIndex = nameTokens.compactMap { token -> Int? in
                guard token.count >= 3, tokenCounts[token] == 1 else { return nil }
                return questionTokens.firstIndex(of: token)
            }.min()
            guard let mentionIndex = [fullNameIndex, prefixIndex, uniqueTokenIndex].compactMap({ $0 }).min()
            else { return nil }
            return (candidates[index].id, mentionIndex)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    private static func firstSubsequenceIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        return (0...(haystack.count - needle.count)).first { index in
            Array(haystack[index..<(index + needle.count)]) == needle
        }
    }

    private static func excludedIDsMentioned<ID: Hashable>(
        in question: String,
        candidates: [(id: ID, name: String)]
    ) -> [ID] {
        let normalized = question.lowercased()
        let markers = [
            "don't use",
            "do not use",
            "don't want to use",
            "do not want to use",
            "without",
            "remove",
            "get rid"
        ]
        return markers.flatMap { marker -> [ID] in
            guard let range = normalized.range(of: marker) else { return [] }
            return mentionedIDs(in: String(normalized[range.upperBound...]), candidates: candidates)
        }
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

struct AssistantDraftPreflightGenerator: AssistantGenerating {
    let coordinator: AssistantCoordinator
    let downstream: any AssistantGenerating

    func availability() async -> AssistantModelAvailability {
        await downstream.availability()
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        if AssistantDraftIntent.requestsInventory(request.question) {
            return inventoryStream(context: request.context)
        }
        let resolution = AssistantSourceResolver.resolve(request.question, context: request.context)
        if let clarification = resolution.clarification { return textStream(clarification) }
        if let clarification = AssistantDraftIntent.clarification(from: request) {
            return textStream(clarification)
        }
        if let wiringRequest = AssistantDraftIntent.wiringRequest(from: request) {
            return draftStream(wiringRequest, context: request.context)
        }

        let mentionedSources = resolution.equipmentIDs
        guard AssistantDraftIntent.requestsDraftAmendment(request.question),
              !mentionedSources.isEmpty else {
            return downstream.stream(request)
        }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard let pending = coordinator.pendingStudioDraft else {
                    do {
                        for try await event in downstream.stream(request) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                let updatedSources = orderedUnique(
                    pending.request.sourceInstrumentIDs + mentionedSources
                )
                var wiringRequest = StudioWiringRequest(
                    sourceInstrumentIDs: updatedSources,
                    effectChainIDs: pending.request.effectChainIDs,
                    destination: pending.request.destination,
                    includesDrySignal: pending.request.includesDrySignal,
                    additionalRoutes: pending.request.additionalRoutes,
                    applicationMode: pending.applicationMode
                )
                wiringRequest.liveReferences = (pending.liveReferences ?? []) + resolution.references
                let result = await coordinator.perform(
                    .buildStudioDraft(wiringRequest),
                    context: request.context
                )
                guard case .pendingDraft(let draft?) = result else {
                    continuation.finish()
                    return
                }
                continuation.yield(.text(AssistantDraftReply.text(for: draft)))
                continuation.yield(.cards(cards(for: draft)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func textStream(_ text: String) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }

    private func draftStream(
        _ wiringRequest: StudioWiringRequest,
        context: AssistantToolContext
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let result = await coordinator.perform(.buildStudioDraft(wiringRequest), context: context)
                guard case .pendingDraft(let draft?) = result else {
                    continuation.finish()
                    return
                }
                continuation.yield(.text(AssistantDraftReply.text(for: draft)))
                continuation.yield(.cards(cards(for: draft)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func inventoryStream(
        context: AssistantToolContext
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        let equipmentByID = Dictionary(
            context.equipment.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let grouped = Dictionary(grouping: context.effectiveConnections.inputs, by: \.equipmentID)
        let sources = grouped.compactMap { equipmentID, connections -> String? in
            guard let equipment = equipmentByID[equipmentID] else { return nil }
            let connectors = connections.map(\.connector).sorted().map(String.init).joined(separator: "/")
            return "\(equipment.name) (WING inputs \(connectors))"
        }.sorted()
        let outputs = context.effectiveConnections.outputs.map {
            "\($0.outputConnector.label): \($0.label(equipment: context.equipment))"
        }.sorted()
        let available = context.equipment.map(\.name).sorted().joined(separator: "\n")
        let sourceText = sources.isEmpty ? "No configured source instruments." : sources.joined(separator: "\n")
        let outputText = outputs.isEmpty ? "No configured outputs." : outputs.joined(separator: "\n")
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(
                "Saved equipment (not connected-equipment detection):\n\(available)"
                    + "\n\nSaved configured source instruments (effective Home + Temporary Moves):\n\(sourceText)"
                    + "\n\nSaved configured outputs:\n\(outputText)\n\n\(context.liveWing.summary)"
            ))
            continuation.finish()
        }
    }

    private func cards(for draft: StudioPatchDraft) -> [AssistantCard] {
        var result: [AssistantCard] = [
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
            result.append(.conflicts(draft.validation.map(\.message)))
        }
        return result
    }

    private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
