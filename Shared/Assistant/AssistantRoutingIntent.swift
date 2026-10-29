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

/// Validates the bounded completed model representation, before configuration lookup.
enum AssistantRoutingInterpretationAdapter {
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
        if intent.replacesSetup {
            guard copied(intent.modeEvidence, text),
                  intent.modeEvidence.range(
                    of: #"\breplace\s+(?:(?:my|the|entire|whole|current)\s+)*(?:setup|studio|graph)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil else { return invalid }
        } else if !intent.modeEvidence.isEmpty
                    || AssistantRoutingOwnership.word("replace|remove|delete|clear", in: text) { return invalid }
        for (mention, evidence) in zip(intent.excludedMentions, intent.exclusionEvidence) {
            guard validMention(mention, text), copied(evidence, text), contains(mention, evidence),
                  isNegative(evidence)
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
                  !isNegative(branch.destinationEvidence),
                  !intent.excludedMentions.contains(where: { excluded in
                      contains(excluded, branch.source) || branch.effects.contains(where: { contains(excluded, $0) })
                  }) else { return invalid }
            if branch.effects.isEmpty {
                guard branch.processingEvidence.isEmpty, !branch.includesDrySignal, branch.dryEvidence.isEmpty
                else { return invalid }
            } else {
                guard copied(branch.processingEvidence, text), contains(branch.source, branch.processingEvidence),
                      branch.effects.allSatisfy({ contains($0, branch.processingEvidence) }),
                      !isNegative(branch.processingEvidence),
                      AssistantRoutingOwnership.word("through|via|into", in: branch.processingEvidence)
                else { return invalid }
                if branch.effects.count > 1 {
                    guard AssistantRoutingOwnership.word("then|followed by", in: branch.processingEvidence),
                          ordered(branch.effects, in: branch.processingEvidence) else { return invalid }
                }
                if branch.includesDrySignal {
                    guard copied(branch.dryEvidence, text), contains(branch.source, branch.dryEvidence),
                          AssistantRoutingOwnership.word("dry", in: branch.dryEvidence),
                          AssistantRoutingOwnership.word("wet|processed", in: branch.dryEvidence),
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
    private static func ordered(_ mentions: [String], in text: String) -> Bool {
        var remaining = text[...]
        for mention in mentions {
            guard let range = remaining.range(of: mention) else { return false }
            remaining = remaining[range.upperBound...]
        }
        return true
    }
}
