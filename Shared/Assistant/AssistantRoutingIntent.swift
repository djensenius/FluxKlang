import Foundation

/// Untrusted, value-only interpretation. Names and copied clauses confer no configuration authority.
struct AssistantRoutingIntent: Equatable, Sendable {
    struct Branch: Equatable, Sendable {
        var source: String
        var effects: [String] = []
        var destination: String
        /// Copied clause supporting this source's destination, including inherited group destinations.
        var destinationEvidence: String
        /// Copied source-specific processing clause; empty for a direct path.
        var processingEvidence: String = ""
        var includesDrySignal = false
        var dryEvidence = ""
    }

    var branches: [Branch]
    var replacesSetup = false
    var modeEvidence = ""
    var excludedMentions: [String] = []
    var exclusionEvidence: [String] = []
}

enum AssistantRoutingOwnership {
    static let clarification = "No draft was changed. Apple routing understanding could not validate the whole request."
        + " Specify each instrument, its ordered effects and configured speaker destination,"
        + " or use the Studio wiring form. "
        + "Routing requires a separate draft review and Listen."

    /// Safety ownership only. This never extracts names, destinations or topology.
    static func owns(_ text: String) -> Bool {
        if AssistantActionInterpretationAdapter.isReadOnlyQuestion(text) { return false }
        if text.range(of: #"^\s*(?:please\s+)?(?:inputs\s+and\s+outputs|ins\s+and\s+outs)[.!?]*\s*$"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if case .command = AssistantMixerIntent.parse(text) { return false }
        return word("route|routing|wire|wired|wiring|patch|patching|connect|through|into|towards|mains|"
                    + "speaker|speakers|monitor|monitors|desktop|desk|feed|feeds|feeding|output|outputs|"
                    + "outboard|parallel|serial|dry|wet|setup|try again|connected now", in: text)
            || text.range(of: #"\b(?:use|send|going|goes|go)\b.+\b(?:on|to|out|into)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"\b(?:add|include)\b.+\b(?:to|into|on)\s+(?![+-]?(?:\d|\.\d))\S"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func word(_ alternatives: String, in text: String) -> Bool {
        text.range(of: "(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct AssistantRoutingNameReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case source, effect, excludedSource, excludedEffect }
    var mention: String
    var id: UUID
    var kind: Kind

    func isValid(in context: AssistantToolContext) -> Bool {
        AssistantRoutingPreparation.isValidNameReference(self, context: context)
    }
}

/// Validates the bounded completed model representation, before configuration lookup.
enum AssistantRoutingInterpretationAdapter {
    static let replacementPattern = #"\breplace\s+(?:(?:my|the|entire|whole|current)\s+)*"#
        + #"(?:studio(?:\s+graph)?|setup|graph)\b"#
    static let maximumBranches = 8
    static let maximumEffects = 3

    // Independent evidence and topology guards intentionally fail closed together.
    // swiftlint:disable:next cyclomatic_complexity
    static func validate(_ intent: AssistantRoutingIntent, text: String) -> AssistantActionInterpretation {
        guard text.count <= 2_000, text.utf8.count <= 2_000,
              (1...maximumBranches).contains(intent.branches.count),
              intent.excludedMentions.count <= 8,
              intent.excludedMentions.count == intent.exclusionEvidence.count,
              intent.modeEvidence.count <= 160,
              !AssistantActionInterpretationAdapter.isReadOnlyQuestion(text),
              !AssistantRoutingOwnership.word("suppose|imagine|hypothetically|if|maybe|perhaps", in: text),
              !text.contains(where: { "\"“”`".contains($0) }) else { return invalid }
        let operators = AssistantRoutingPreparation.maskingEntities(in: text, intent: intent)
        if intent.replacesSetup {
            let modeOperators = AssistantRoutingPreparation.maskingEntities(in: intent.modeEvidence, intent: intent)
            guard copied(intent.modeEvidence, text),
                  operators.range(of: replacementPattern, options: [.regularExpression, .caseInsensitive]) != nil,
                  modeOperators.range(
                    of: replacementPattern,
                    options: [.regularExpression, .caseInsensitive]) != nil else { return invalid }
        } else if !intent.modeEvidence.isEmpty
                    || AssistantRoutingOwnership.word("replace|remove|delete|clear", in: operators) { return invalid }
        for (mention, evidence) in zip(intent.excludedMentions, intent.exclusionEvidence) {
            guard validMention(mention, text), copied(evidence, text), contains(mention, evidence),
                  validExclusion(mention, evidence: evidence, mentions: intent.excludedMentions)
            else { return invalid }
        }
        for branch in intent.branches {
            guard validMention(branch.source, text), validMention(branch.destination, text),
                  branch.effects.count <= maximumEffects,
                  Set(branch.effects.map(normalize)).count == branch.effects.count,
                  branch.effects.allSatisfy({ validMention($0, text) }),
                  copied(branch.destinationEvidence, text),
                  contains(branch.source, branch.destinationEvidence),
                  contains(branch.destination, branch.destinationEvidence),
                  occursOnce(branch.destination, in: branch.destinationEvidence),
                  sourceScopedDestination(branch),
                  !isNegative(branch.destinationEvidence),
                  !intent.excludedMentions.contains(where: { excluded in
                      contains(excluded, branch.source) || branch.effects.contains(where: { contains(excluded, $0) })
                  }) else { return invalid }
            if branch.effects.isEmpty {
                guard branch.processingEvidence.isEmpty, !branch.includesDrySignal, branch.dryEvidence.isEmpty
                else { return invalid }
            } else {
                guard copied(branch.processingEvidence, text), contains(branch.source, branch.processingEvidence),
                      branch.effects.allSatisfy({ occursOnce($0, in: branch.processingEvidence) }),
                      !isNegative(branch.processingEvidence),
                      sourcePrecedesProcessing(branch)
                else { return invalid }
                if branch.effects.count > 1 {
                    guard seriallyOrdered(branch) else { return invalid }
                }
                if branch.includesDrySignal {
                    let operators = operatorEvidence(branch.dryEvidence, branch: branch)
                    guard copied(branch.dryEvidence, text), contains(branch.source, branch.dryEvidence),
                          AssistantRoutingOwnership.word("dry", in: operators),
                          AssistantRoutingOwnership.word("wet|processed", in: operators),
                          !isNegative(branch.dryEvidence) else { return invalid }
                } else if !branch.dryEvidence.isEmpty { return invalid }
            }
        }
        return .routing(intent)
    }

    static func contains(_ phrase: String, _ text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return AssistantRoutingOwnership.word(NSRegularExpression.escapedPattern(for: phrase), in: text)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static var invalid: AssistantActionInterpretation {
        .clarification(AssistantRoutingOwnership.clarification)
    }
    private static func validMention(_ mention: String, _ text: String) -> Bool {
        !mention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && mention.count <= 100 && copied(mention, text)
    }
    private static func copied(_ evidence: String, _ text: String) -> Bool {
        !evidence.isEmpty && evidence.count <= 400 && text.range(of: evidence) != nil
    }
    private static func isNegative(_ text: String) -> Bool {
        AssistantRoutingOwnership.word("without|except|not|don't|do not|never|exclude",
                                       in: text.replacingOccurrences(of: "’", with: "'"))
    }
    private static func validExclusion(_ mention: String, evidence: String, mentions: [String]) -> Bool {
        var neutral = evidence.replacingOccurrences(of: "’", with: "'")
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: mention)
            + "(?![\\p{L}\\p{N}_])"
        guard let operand = neutral.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              let negation = neutral.range(
                of: #"\b(?:without|except|not|don't|do not|never|exclude)\b"#,
                options: [.regularExpression, .caseInsensitive]),
              negation.upperBound <= operand.lowerBound else { return false }
        for excluded in mentions.sorted(by: { $0.count > $1.count }) {
            neutral = neutral.replacingOccurrences(
                of: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: excluded)
                    + "(?![\\p{L}\\p{N}_])", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let allowed = Set(
            "without except not don't do never exclude use include and or the my please".split(separator: " "))
        return neutral.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .allSatisfy { allowed.contains($0) }
    }
    private static func occursOnce(_ mention: String, in text: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: mention)
            + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) == 1
    }
    private static func sourceScopedDestination(_ branch: AssistantRoutingIntent.Branch) -> Bool {
        let evidence = branch.destinationEvidence
        let range: (String) -> Range<String.Index>? = { mention in
            evidence.range(of: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: mention)
                + "(?![\\p{L}\\p{N}_])", options: [.regularExpression, .caseInsensitive])
        }
        guard let source = range(branch.source), let destination = range(branch.destination) else { return false }
        return source.upperBound <= destination.lowerBound
    }

    private static func sourcePrecedesProcessing(_ branch: AssistantRoutingIntent.Branch) -> Bool {
        let evidence = branch.processingEvidence
        guard let first = branch.effects.first,
              occursOnce(branch.source, in: evidence),
              let source = evidence.range(of: branch.source, options: .caseInsensitive),
              let effect = evidence.range(of: first, options: .caseInsensitive),
              source.upperBound <= effect.lowerBound else { return false }
        let relationship = String(evidence[source.upperBound..<effect.lowerBound])
        return AssistantRoutingOwnership.word("through|via|into", in: relationship)
            && !AssistantRoutingOwnership.word("from", in: relationship)
            && !contains(branch.destination, relationship)
    }

    private static func operatorEvidence(_ text: String, branch: AssistantRoutingIntent.Branch) -> String {
        ([branch.source, branch.destination] + branch.effects).sorted { $0.count > $1.count }
            .reduce(text) { remaining, mention in
                remaining.replacingOccurrences(
                    of: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: mention)
                        + "(?![\\p{L}\\p{N}_])", with: " ", options: [.regularExpression, .caseInsensitive])
            }
    }

    private static func seriallyOrdered(_ branch: AssistantRoutingIntent.Branch) -> Bool {
        var topology = branch.processingEvidence
        for mention in [branch.source] + branch.effects {
            topology = topology.replacingOccurrences(of: mention, with: " ", options: .caseInsensitive)
        }
        guard !AssistantRoutingOwnership.word("parallel", in: topology) else { return false }
        var remaining = branch.processingEvidence[...]
        var hasPrevious = false
        for mention in branch.effects {
            guard let range = remaining.range(of: mention) else { return false }
            if hasPrevious,
               !AssistantRoutingOwnership.word("then|followed by", in: String(remaining[..<range.lowerBound])) {
                return false
            }
            if hasPrevious, contains(branch.destination, String(remaining[..<range.lowerBound])) { return false }
            remaining = remaining[range.upperBound...]
            hasPrevious = true
        }
        return true
    }
}
