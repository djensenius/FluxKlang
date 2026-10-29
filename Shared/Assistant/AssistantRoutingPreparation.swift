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
        var names: [AssistantRoutingNameReference] = []
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
            if let source {
                excludedSources.insert(source.id)
                references.append(contentsOf: source.references)
                names.append(.init(mention: excluded, id: source.id, kind: .excludedSource))
            }
            if let effect = effects.first {
                excludedEffects.insert(effect.id)
                names.append(.init(mention: excluded, id: effect.id, kind: .excludedEffect,
                                   equipmentID: effect.equipmentID))
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
            names.append(.init(mention: branch.source, id: source.id, kind: .source))
            var effects: [Effect.ID] = []
            for mention in branch.effects {
                let matches = context.effects.filter { matchesName(mention, name: $0.name) }
                guard matches.count == 1, let effect = matches.first, let device = effect.equipmentID,
                      !excludedEffects.contains(effect.id), !excludedDevices.contains(device),
                      usedEffects.insert(effect.id).inserted, usedEffectDevices.insert(device).inserted
                else { return failure }
                effects.append(effect.id)
                names.append(.init(mention: mention, id: effect.id, kind: .effect, equipmentID: device))
            }
            // Copied evidence must not promise one source's processing for another named source.
            let others = intent.branches.filter { $0.source != branch.source }.map(\.source)
            let destination = AssistantRoutingInterpretationAdapter.normalize(branch.destination)
            guard destinationSpans(in: branch.destinationEvidence, intent: intent,
                additionalNames: AssistantRoutingOutputResolver.groups(in: context.effectiveConnections).map(\.name))
                .allSatisfy({ $0.name == destination }),
                  completeDestinationPhrase(branch, intent: intent) else { return failure }
            guard !others.contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, branch.processingEvidence)
                    || AssistantRoutingInterpretationAdapter.contains($0, branch.dryEvidence)
            }) else { return failure }
            references.append(contentsOf: source.references)
            outputs.append(output.reference)
            routes.append(StudioWiringRoute(
                sourceInstrumentIDs: [source.id], effectChainIDs: effects,
                destination: output.destination, includesDrySignal: branch.includesDrySignal,
                outputConnectors: output.reference.connectors))
        }
        let mentioned = AssistantSourceResolver.resolve(text, context: context, excluding: effectEquipment)
        guard mentioned.clarification == nil, Set(mentioned.equipmentIDs).isSubset(of: sources),
              effectMentionsCovered(text, effects: context.effects, covered: usedEffects.union(excludedEffects),
                  mentions: intent.branches.flatMap { [$0.source, $0.destination] + $0.effects }
                    + intent.excludedMentions),
              let primary = routes.first else { return failure }
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
        draft.nameReferences = names
        guard !draft.hasErrors else { return failure }
        guard intent.replacesSetup || (!conflictsWithExistingGraph(
            draft.request, effects: context.effects, graph: context.graph)
            && !conflictsWithExistingDestinations(draft, endpoints: context.endpoints)) else { return failure }
        return .prepared(draft)
    }

    static func conflictsWithExistingDestinations(_ draft: StudioPatchDraft, endpoints: [StudioEndpoint]) -> Bool {
        draft.fragment.endpoints.contains { proposed in
            endpoints.contains { existing in
                guard let old = existing.explicitOutputConnectors, let new = proposed.explicitOutputConnectors
                else { return false }
                let sameMains = existing.destination == .finalMix && proposed.destination == .finalMix
                let sameName = existing.destination == proposed.destination
                    && AssistantRoutingInterpretationAdapter.normalize(existing.name)
                        == AssistantRoutingInterpretationAdapter.normalize(proposed.name)
                let overlaps = !Set(old).isDisjoint(with: new)
                return (overlaps && existing.destination != proposed.destination)
                    || (old != new && (sameMains || sameName || overlaps))
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

    static func isValidNameReference(
        _ reference: AssistantRoutingNameReference, context: AssistantToolContext
    ) -> Bool {
        let effects = context.effects.filter { matchesName(reference.mention, name: $0.name) }
        if let device = reference.equipmentID,
           effects.first(where: { $0.id == reference.id })?.equipmentID != device { return false }
        let source = resolveSource(reference.mention, context: context,
            excluding: Set(context.effects.compactMap(\.equipmentID)))
        switch reference.kind {
        case .source: return source?.id == reference.id
        case .effect: return effects.count == 1 && effects.first?.id == reference.id
        case .excludedSource: return effects.isEmpty && source?.id == reference.id
        case .excludedEffect: return source == nil && effects.count == 1 && effects.first?.id == reference.id
        }
    }

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

    private static func effectMentionsCovered(
        _ text: String, effects: [Effect], covered: Set<Effect.ID>, mentions: [String]
    ) -> Bool {
        let remaining = Set(mentions).sorted { $0.count > $1.count }.reduce(text) { text, mention in
            text.replacingOccurrences(
                of: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: mention)
                    + "(?![\\p{L}\\p{N}_])", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let words = remaining.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return effects.allSatisfy { effect in
            !words.indices.contains { index in
                if covered.contains(effect.id) {
                    var preceding = words[..<index]
                    while ["the", "my", "a", "an", "both"].contains(preceding.last ?? "") {
                        preceding = preceding.dropLast()
                    }
                    guard ["then", "through", "via", "into"].contains(preceding.last ?? "")
                        || Array(preceding.suffix(2)) == ["followed", "by"] else { return false }
                }
                // Every valid alias has a matching prefix of at most three tokens (minimum three characters).
                return (1...min(3, words.count - index)).contains { count in
                    matchesName(words[index..<(index + count)].joined(separator: " "), name: effect.name)
                }
            }
        }
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
        if intent.replacesSetup {
            remaining = remaining.replacingOccurrences(
                of: AssistantRoutingInterpretationAdapter.replacementPattern, with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        let allowed = Set(("i want to use and on with going through via into out the my i'd id like would "
            + "please route send connect wire patch add include also then followed by only just "
            + "dry wet processed signal in parallel both a an of directly straight "
            + "without except not don't do never exclude")
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
        let operands = maskingEntities(in: text, intent: intent, markSources: true)
        let sourceOperand = #"\b(?:to|into|through|via|then|followed\s+by)\s+"#
            + #"(?:(?:the|my|a|an|both)\s+)*fk_source\b"#
        guard operands.range(of: sourceOperand,
                             options: [.regularExpression, .caseInsensitive]) == nil,
              sourceOperandsCovered(intent, text: text), continuationOperandsCovered(intent, text: text),
              directPathsCovered(intent, text: text) else { return false }
        let operators = maskingEntities(in: text, intent: intent)
        let processing = intent.branches.filter { !$0.effects.isEmpty }.map(\.processingEvidence)
        let dry = intent.branches.filter(\.includesDrySignal).map(\.dryEvidence)
        let allEffects = Set(intent.branches.flatMap(\.effects))
        for branch in intent.branches {
            let evidence = branch.destinationEvidence + " " + branch.processingEvidence + " " + branch.dryEvidence
            guard !allEffects.subtracting(branch.effects).contains(where: {
                AssistantRoutingInterpretationAdapter.contains($0, evidence)
            }) else { return false }
            let operatorEvidence = maskingEntities(in: evidence, intent: intent)
            if branch.effects.isEmpty,
               AssistantRoutingOwnership.word("through|via", in: operatorEvidence) { return false }
            if !branch.includesDrySignal,
               AssistantRoutingOwnership.word("dry|wet|parallel", in: operatorEvidence) { return false }
        }
        let effectChecks = allEffects.map { effect in
            (NSRegularExpression.escapedPattern(for: effect),
             intent.branches.filter { $0.effects.contains(effect) }.map(\.processingEvidence))
        }
        for (pattern, evidence) in [
            ("through|via", processing), ("dry|wet|parallel", dry)
        ] + effectChecks {
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])",
                options: .caseInsensitive) else { return false }
            let covered = (evidence + intent.exclusionEvidence).compactMap { text.range(of: $0) }
            let scanned = ["through|via", "dry|wet|parallel"].contains(pattern) ? operators : text
            let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
            for match in regex.matches(in: scanned, range: range) {
                guard let range = Range(match.range, in: text),
                      covered.contains(where: {
                          $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound
                      })
                else { return false }
            }
        }
        return destinationSpans(in: text, intent: intent).allSatisfy { destination in
            let evidence = intent.branches.filter {
                AssistantRoutingInterpretationAdapter.normalize($0.destination) == destination.name
            }.map(\.destinationEvidence) + intent.exclusionEvidence
            return evidence.compactMap { text.range(of: $0) }.contains {
                $0.lowerBound <= destination.range.lowerBound && $0.upperBound >= destination.range.upperBound
            }
        }
    }

    private static func sourceOperandsCovered(_ intent: AssistantRoutingIntent, text: String) -> Bool {
        let positive = intent.exclusionEvidence.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
        let operands = maskingEntities(in: positive, intent: intent, markSources: true)
            .replacingOccurrences(of: #"(?:[,&+/;:|.]\s*)?\band\b|[,&+/;:|.](?=\s*[\p{L}\p{N}_])"#,
                                  with: " and ",
                                  options: [.regularExpression, .caseInsensitive])
        let words = operands.lowercased().split { !$0.isLetter && $0 != "_" }.map(String.init)
        let verbs = Set("route send use wire connect patch add include".split(separator: " ").map(String.init))
        let fillers = Set("the my a an both only just also then".split(separator: " ").map(String.init))
        let leading = words.prefix { $0 != "fk_source" }
        guard !leading.contains("and") || leading.contains(where: { verbs.contains($0) }) else { return false }
        for (index, word) in words.enumerated() {
            let joined = word == "fk_source" && words.dropFirst(index + 1).first == "and"
            guard verbs.contains(word) || joined else { continue }
            var next = index + (joined ? 2 : 1)
            while next < words.count && fillers.contains(words[next]) { next += 1 }
            guard next < words.count,
                  words[next] == "fk_source" || (joined && verbs.contains(words[next])) else { return false }
        }
        return true
    }

    private static func completeDestinationPhrase(
        _ branch: AssistantRoutingIntent.Branch, intent: AssistantRoutingIntent
    ) -> Bool {
        let prefixes = Set(
            "to on out into through via then the my a an both directly straight and".split(separator: " "))
        return destinationSpans(in: branch.destinationEvidence, intent: intent).allSatisfy { destination in
            let prefix = branch.destinationEvidence[..<destination.range.lowerBound]
                .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last
            return prefix.map { prefixes.contains($0) } ?? false
        }
    }

    static func destinationSpans(
        in text: String, intent: AssistantRoutingIntent, additionalNames: [String] = []
    ) -> [(name: String, range: Range<String.Index>)] {
        let destinations = Set((intent.branches.map(\.destination) + additionalNames)
            .map(AssistantRoutingInterpretationAdapter.normalize))
        let names = Set(intent.branches.flatMap { [$0.source, $0.destination] + $0.effects }
            + intent.excludedMentions + additionalNames).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:" + names + ")(?![\\p{L}\\p{N}_])",
            options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let name = AssistantRoutingInterpretationAdapter.normalize(String(text[range]))
            return destinations.contains(name) ? (name, range) : nil
        }
    }

    static func maskingEntities(
        in text: String, intent: AssistantRoutingIntent, markSources: Bool = false, highlightingSource: String? = nil
    ) -> String {
        let sources = Set(intent.branches.map { AssistantRoutingInterpretationAdapter.normalize($0.source) })
        let mentions = Set(intent.branches.flatMap { [$0.source, $0.destination] + $0.effects }
            + intent.excludedMentions)
        let names = mentions.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:" + names + ")(?![\\p{L}\\p{N}_])",
            options: .caseInsensitive) else { return text }
        let original = text as NSString
        let masked = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let mention = AssistantRoutingInterpretationAdapter.normalize(original.substring(with: match.range))
            let source = sources.contains(mention)
            let marker = mention == highlightingSource.map(AssistantRoutingInterpretationAdapter.normalize)
                ? "fk_same_source" : "fk_source"
            // Spaces retain UTF-16 offsets for copied-evidence coverage against the original text.
            let replacement = markSources && source ? marker : String(repeating: " ", count: match.range.length)
            masked.replaceCharacters(in: match.range, with: replacement)
        }
        return masked as String
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

extension AssistantRoutingPreparation {
    private static func continuationOperandsCovered(_ intent: AssistantRoutingIntent, text: String) -> Bool {
        let mentions = Set(intent.branches.flatMap { [$0.source, $0.destination] + $0.effects })
        let names = mentions.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let positive = intent.exclusionEvidence.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
        let masked = positive.replacingOccurrences(
            of: "(?<![\\p{L}\\p{N}_])(?:" + names + ")(?![\\p{L}\\p{N}_])",
            with: "fk_entity", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\b(?:i want to|i would like to|i['’]d like|id like|would like to)\s+"#,
                                  with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?:[,&+/;:|.]\s*)?\band\b|[,&+/;:|.](?=\s*[\p{L}\p{N}_])"#,
                                  with: " and ",
                                  options: [.regularExpression, .caseInsensitive])
        let words = masked.lowercased().split { !$0.isLetter && $0 != "_" }.map(String.init)
        let fillers = Set("the my a an both also just only".split(separator: " ").map(String.init))
        let operators = Set("and with to on out through via into then".split(separator: " ").map(String.init))
        let operands = Set(("fk_entity route send use wire connect patch with through via into to on out "
            + "directly straight dry wet processed parallel").split(separator: " ").map(String.init))
        for (index, word) in words.enumerated() {
            let followed = word == "followed" && words.dropFirst(index + 1).first == "by"
            guard operators.contains(word) || followed else { continue }
            var next = index + (followed ? 2 : 1)
            while next < words.count && fillers.contains(words[next]) { next += 1 }
            guard next < words.count, operands.contains(words[next]) else { return false }
        }
        return true
    }

    private static func directPathsCovered(_ intent: AssistantRoutingIntent, text: String) -> Bool {
        let continuation = #"(?:(?!\band\b)[\s\p{L},;])*"#
        let coordinator = #"(?:\band\b|[&+/;:|.,])\s*(?:(?:also|just|only)\s+)*"#
        let split = #"\b(?:(?:through|via|into)\b"# + continuation + coordinator + #"(?:directly|straight)"#
            + #"|(?:directly|straight)\b"# + continuation + coordinator + #"(?:through|via|into))\b"#
        return intent.branches.allSatisfy { branch in
            let marked = maskingEntities(in: text, intent: intent, markSources: true,
                highlightingSource: branch.source)
            for occurrence in marked.components(separatedBy: "fk_same_source").dropFirst() {
                let scoped = occurrence.components(separatedBy: "fk_source").first ?? ""
                if !branch.effects.isEmpty, AssistantRoutingOwnership.word("directly|straight", in: scoped),
                   !AssistantRoutingOwnership.word("through|via|into", in: scoped) { return false }
            }
            let clauses = marked.components(separatedBy: "fk_source")
            return clauses.allSatisfy { clause in
                guard let source = clause.range(of: "fk_same_source") else { return true }
                let scoped = clause[source.upperBound...].replacingOccurrences(of: "fk_same_source", with: " ")
                return scoped.range(of: split, options: [.regularExpression, .caseInsensitive]) == nil
            }
        }
    }
}
