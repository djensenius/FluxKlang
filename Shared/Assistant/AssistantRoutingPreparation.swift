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
        let effectEquipment = Set(context.effects.compactMap(\.equipmentID))
        for excluded in intent.excludedMentions {
            let effects = context.effects.filter { matchesName(excluded, name: $0.name) }
            guard effects.count == 1 || resolveSource(excluded, context: context, excluding: effectEquipment) != nil
            else { return failure }
        }
        for branch in intent.branches {
            guard let source = resolveSource(branch.source, context: context, excluding: effectEquipment),
                  sources.insert(source.id).inserted,
                  let output = AssistantRoutingOutputResolver.resolve(
                    branch.destination, in: context.effectiveConnections)
            else { return failure }
            var effects: [Effect.ID] = []
            for mention in branch.effects {
                let matches = context.effects.filter { matchesName(mention, name: $0.name) }
                guard matches.count == 1, let effect = matches.first, let device = effect.equipmentID,
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
        // Existing effects are shared physical devices, not independently instantiated processors.
        if !intent.replacesSetup {
            let existingEffects = context.graph.nodes.compactMap { node -> Effect.ID? in
                if case .effect(let id) = node.kind { return id }
                return nil
            }
            let existingSourceNodes = Set(context.graph.nodes.compactMap { node -> StudioNode.ID? in
                if case .instrument(let id) = node.kind, sources.contains(id) { return node.id }
                return nil
            })
            let existingEffectDevices = Set(context.effects.filter {
                existingEffects.contains($0.id)
            }.compactMap(\.equipmentID))
            guard usedEffects.isDisjoint(with: existingEffects),
                  usedEffectDevices.isDisjoint(with: existingEffectDevices),
                  !context.graph.edges.contains(where: { existingSourceNodes.contains($0.from.nodeID) })
            else { return failure }
        }
        return .prepared(draft)
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
        var remaining = text
        for evidence in intent.exclusionEvidence {
            let positiveNames = intent.branches.flatMap { [$0.source] + $0.effects }
            guard !positiveNames.contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, evidence)
            }) else { return false }
            let neutral = evidence.replacingOccurrences(
                of: #"\b(?:without|except|not|don't|do not|never|exclude)\b"#, with: " ",
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
        if AssistantRoutingOwnership.word("without|except|not|don't|never|exclude", in: remaining) { return false }
        return true
    }
}
