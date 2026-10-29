import Foundation

/// The only natural-language routing preparation path. All branches resolve before any pending mutation.
enum AssistantRoutingPreparation {
    enum Result {
        case prepared(StudioPatchDraft)
        case clarification(String)
    }

    // Keep all-or-clarify rejection exits before building the single immutable review.
    // swiftlint:disable:next cyclomatic_complexity
    static func prepare(
        text: String, intent: AssistantRoutingIntent, context: AssistantToolContext
    ) -> Result {
        guard case .routing = AssistantRoutingInterpretationAdapter.validate(intent, text: text),
              completeCoverage(intent, text: text) else { return failure }
        var routes: [StudioWiringRoute] = []
        var references: [AssistantLiveReference] = []
        var outputs: [AssistantRoutingOutputReference] = []
        var sources: Set<Equipment.ID> = []
        var usedEffects: Set<Effect.ID> = []
        var usedEffectDevices: Set<Equipment.ID> = []
        var excludedSources: Set<Equipment.ID> = []
        var excludedEffects: Set<Effect.ID> = []
        var excludedDevices: Set<Equipment.ID> = []
        let effectEquipment = Set(context.effects.compactMap(\.equipmentID))
        for excluded in intent.excludedMentions {
            let effects = context.effects.filter { matchesName(excluded, name: $0.name) }
            let source = resolveSource(excluded, context: context, excluding: effectEquipment)
            guard effects.count + (source == nil ? 0 : 1) == 1 else { return failure }
            if let source { excludedSources.insert(source.id) }
            if let effect = effects.first {
                excludedEffects.insert(effect.id)
                if let device = effect.equipmentID { excludedDevices.insert(device) }
            }
        }
        for branch in intent.branches {
            guard let source = resolveSource(branch.source, context: context, excluding: effectEquipment),
                  !excludedSources.contains(source.id),
                  sources.insert(source.id).inserted,
                  let output = AssistantRoutingOutputResolver.resolve(
                    branch.destination, in: context.effectiveConnections)
            else { return failure }
            var effects: [Effect.ID] = []
            for mention in branch.effects {
                let matches = context.effects.filter { matchesName(mention, name: $0.name) }
                guard matches.count == 1, let effect = matches.first, let device = effect.equipmentID,
                      !excludedEffects.contains(effect.id), !excludedDevices.contains(device),
                      usedEffects.insert(effect.id).inserted, usedEffectDevices.insert(device).inserted
                else { return failure }
                effects.append(effect.id)
            }
            // Copied evidence must not promise one source's processing for another named source.
            let others = intent.branches.filter { $0.source != branch.source }.map(\.source)
            let otherDestinations = Set(intent.branches.map(\.destination)).subtracting([branch.destination])
            guard !otherDestinations.contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, branch.destinationEvidence)
            }) else { return failure }
            guard branch.effects.isEmpty || !others.contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, branch.processingEvidence)
            }) else { return failure }
            references.append(contentsOf: source.references)
            outputs.append(output.reference)
            routes.append(StudioWiringRoute(
                sourceInstrumentIDs: [source.id], effectChainIDs: effects,
                destination: output.destination, includesDrySignal: branch.includesDrySignal,
                outputConnectors: output.reference.connectors))
        }
        guard let primary = routes.first else { return failure }
        var request = StudioWiringRequest(
            sourceInstrumentIDs: primary.sourceInstrumentIDs, effectChainIDs: primary.effectChainIDs,
            destination: primary.destination, includesDrySignal: primary.includesDrySignal,
            outputConnectors: primary.outputConnectors, additionalRoutes: Array(routes.dropFirst()),
            applicationMode: intent.replacesSetup ? .replace : .append)
        request.liveReferences = Array(Set(references))
        request.outputReferences = Array(Set(outputs))
        var draft = StudioWiringAdvisor.build(
            request: request, equipment: context.equipment, effects: context.effects,
            connections: context.globalConnections, currentGraph: context.graph,
            environmentID: context.activeEnvironmentID)
        draft.liveReferences = request.liveReferences
        draft.outputReferences = request.outputReferences
        guard !draft.hasErrors else { return failure }
        guard intent.replacesSetup || (!conflictsWithExistingGraph(
            draft.request, effects: context.effects, graph: context.graph)
            && !conflictsWithExistingDestinations(draft, endpoints: context.endpoints)) else { return failure }
        return .prepared(draft)
    }

    static func conflictsWithExistingDestinations(_ draft: StudioPatchDraft, endpoints: [StudioEndpoint]) -> Bool {
        draft.fragment.endpoints.contains { proposed in
            endpoints.contains { existing in
                guard let old = existing.outputConnectors, let new = proposed.outputConnectors else { return false }
                let sameMains = existing.destination == .finalMix && proposed.destination == .finalMix
                let sameName = existing.destination == proposed.destination
                    && AssistantRoutingInterpretationAdapter.normalize(existing.name)
                        == AssistantRoutingInterpretationAdapter.normalize(proposed.name)
                return old != new && (sameMains || sameName || !Set(old).isDisjoint(with: new))
            }
        }
    }

    static func conflictsWithExistingGraph(
        _ request: StudioPatchRequest, effects: [Effect], graph: StudioGraph
    ) -> Bool {
        let sources = Set(request.sourceInstrumentIDs + request.additionalRoutes.flatMap(\.sourceInstrumentIDs))
        let usedEffects = Set(request.effectChainIDs + request.additionalRoutes.flatMap(\.effectChainIDs))
        let existingEffects = Set(graph.nodes.compactMap { node -> Effect.ID? in
            if case .effect(let id) = node.kind { return id }
            return nil
        })
        let existingSourceNodes = Set(graph.nodes.compactMap { node -> StudioNode.ID? in
            if case .instrument(let id) = node.kind, sources.contains(id) { return node.id }
            return nil
        })
        let existingDevices = Set(effects.filter { existingEffects.contains($0.id) }.compactMap(\.equipmentID))
        let usedDevices = Set(effects.filter { usedEffects.contains($0.id) }.compactMap(\.equipmentID))
        return !usedEffects.isDisjoint(with: existingEffects) || !usedDevices.isDisjoint(with: existingDevices)
            || graph.edges.contains { existingSourceNodes.contains($0.from.nodeID) }
    }

    /// Cancellation/unavailability/misclassification never falls through to a regex or external provider.
    static func interpret(
        text: String, context: AssistantToolContext, interpreter: any AssistantActionInterpreting
    ) async throws -> Result {
        guard await interpreter.availability() == .available else { return failure }
        try Task.checkCancellation()
        let interpretation: AssistantActionInterpretation
        do {
            interpretation = try await interpreter.interpret(.init(text: text, liveContext: context.liveWing))
        } catch is CancellationError { throw CancellationError() } catch { return failure }
        try Task.checkCancellation()
        guard case .routing(let intent) = interpretation else { return failure }
        return prepare(text: text, intent: intent, context: context)
    }

    private static var failure: Result { .clarification(AssistantRoutingOwnership.clarification) }

    private static func resolveSource(
        _ mention: String, context: AssistantToolContext, excluding: Set<Equipment.ID>
    ) -> (id: Equipment.ID, references: [AssistantLiveReference])? {
        let liveMentions = context.liveWing.observations.filter {
            AssistantRoutingInterpretationAdapter.normalize($0.label.value)
                == AssistantRoutingInterpretationAdapter.normalize(mention)
                || $0.identity.caseInsensitiveCompare(mention) == .orderedSame
        }
        if !liveMentions.isEmpty {
            let resolution = AssistantSourceResolver.resolve(
                mention, context: context, excluding: excluding, requiresSourceIntent: false)
            guard resolution.clarification == nil, resolution.equipmentIDs.count == 1,
                  let id = resolution.equipmentIDs.first, !resolution.references.isEmpty,
                  context.equipment.contains(where: { $0.id == id }), !excluding.contains(id),
                  resolution.references.allSatisfy({ $0.isValid(in: context.liveWing) }) else { return nil }
            return (id, resolution.references)
        }
        let matches = context.equipment.filter { !excluding.contains($0.id) && matchesName(mention, name: $0.name) }
        guard matches.count == 1, let id = matches.first?.id else { return nil }
        return (id, [])
    }

    /// Short aliases must consist entirely of configured name tokens (Solar, OP-XY, Evil Pet).
    private static func matchesName(_ mention: String, name: String) -> Bool {
        let tokens: (String) -> [String] = { text in
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let requested = tokens(mention)
        let configured = tokens(name)
        guard !requested.isEmpty, requested.joined().count >= 3, requested.count <= configured.count
        else { return false }
        return (0...(configured.count - requested.count)).contains {
            Array(configured[$0..<($0 + requested.count)]) == requested
        }
    }

    /// Coverage is a rejection fence, not a topology parser. Unknown names, referents and unsupported
    /// operators must not disappear from an otherwise valid subset. Apple alone supplies branch scope.
    private static func completeCoverage(_ intent: AssistantRoutingIntent, text: String) -> Bool {
        guard intent.branches.allSatisfy({ sourceOccurrencesCovered($0, in: text) }),
              directivesCovered(intent, in: text) else { return false }
        var remaining = text
        for evidence in intent.exclusionEvidence {
            let positiveNames = intent.branches.flatMap { [$0.source] + $0.effects }
            guard !positiveNames.contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, evidence)
            }) else { return false }
            let neutral = evidence.replacingOccurrences(
                of: #"\b(?:without|except|not|don['’]t|do not|never|exclude)\b"#, with: " ",
                options: [.regularExpression, .caseInsensitive])
            remaining = remaining.replacingOccurrences(of: evidence, with: neutral)
        }
        let mentions = intent.branches.flatMap { [$0.source, $0.destination] + $0.effects } + intent.excludedMentions
        for mention in Set(mentions).sorted(by: { $0.count > $1.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: mention)
                + "(?![\\p{L}\\p{N}])"
            remaining = remaining.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let allowed = Set(("i want to use and on with going through via into out the my i'd id like would "
            + "please route send connect wire patch add include also then followed by only just "
            + "dry wet processed signal in parallel both a an of directly straight "
            + "without except not don't do never exclude replace entire whole current setup studio graph")
            .split(separator: " ").map(String.init))
        let words = remaining.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        guard words.allSatisfy({ allowed.contains($0) }) else { return false }
        // A bare parallel/dry request is not permission to invent a blend or drop its raw path.
        if AssistantRoutingOwnership.word("dry|wet|parallel", in: remaining),
           !intent.branches.contains(where: \.includesDrySignal) { return false }
        if AssistantRoutingOwnership.word("without|except|not|don't|never|exclude",
            in: remaining.replacingOccurrences(of: "’", with: "'")) { return false }
        return true
    }

    private static func directivesCovered(_ intent: AssistantRoutingIntent, in text: String) -> Bool {
        let processing = intent.branches.filter { !$0.effects.isEmpty }.map(\.processingEvidence)
        let dry = intent.branches.filter(\.includesDrySignal).map(\.dryEvidence)
        let allEffects = Set(intent.branches.flatMap(\.effects))
        for branch in intent.branches {
            let evidence = branch.destinationEvidence + " " + branch.processingEvidence + " " + branch.dryEvidence
            guard !allEffects.subtracting(branch.effects).contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, evidence)
            }) else { return false }
            if branch.effects.isEmpty,
               AssistantRoutingOwnership.word("through|via", in: evidence) { return false }
            if !branch.includesDrySignal,
               AssistantRoutingOwnership.word("dry|wet|parallel", in: evidence) { return false }
        }
        for (pattern, evidence) in [
            ("through|via", processing), ("dry|wet|parallel", dry)
        ] {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b(?:" + pattern + ")\\b", options: .caseInsensitive) else { return false }
            let covered = (evidence + intent.exclusionEvidence).compactMap { text.range(of: $0) }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                guard let range = Range(match.range, in: text),
                      covered.contains(where: {
                          $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound
                      })
                else { return false }
            }
        }
        return true
    }

    private static func sourceOccurrencesCovered(_ branch: AssistantRoutingIntent.Branch, in text: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: branch.source)
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let evidence = [branch.destinationEvidence, branch.processingEvidence, branch.dryEvidence]
            .filter { !$0.isEmpty }
        // A broad copied span must not hide an additional directive for the same source.
        guard evidence.allSatisfy({
            regex.numberOfMatches(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)) == 1
        }) else { return false }
        let covered = evidence.compactMap { text.range(of: $0) }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).allSatisfy {
            guard let occurrence = Range($0.range, in: text) else { return false }
            return covered.contains { $0.lowerBound <= occurrence.lowerBound && $0.upperBound >= occurrence.upperBound }
        }
    }
}
