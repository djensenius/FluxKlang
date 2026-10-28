import Foundation

/// Guided generation constrains shape, not truth. Validate current-utterance evidence again here.
enum AssistantActionIntentValidator {
    // Explicit fail-closed checks for each untrusted optional field.
    // swiftlint:disable:next cyclomatic_complexity
    static func clarification(for intent: AssistantActionIntent, text: String) -> String? {
        guard !text.contains(where: { "\"“”`\n\r".contains($0) }),
            text.range(
                of: #"\b(do not|don't|never|not|if|hypothetical|pretend|imagine|how|why|explain)\b"#,
                options: [.regularExpression, .caseInsensitive]) == nil
        else {
            return "No changes: quoted, negated, hypothetical or multiple mixer actions need a new direct request."
        }
        guard !text.isEmpty, text.count <= 2_000, !intent.targetMention.isEmpty,
            intent.targetMention.count <= 160,
            intent.targetMention.caseInsensitiveCompare(intent.evidence.target) == .orderedSame,
            copied(intent.evidence.target, from: text)
        else {
            return "No changes: the target must be stated in the current request."
        }
        let actionText = text.replacingOccurrences(
            of: evidencePattern(intent.evidence.target), with: " ", options: [.regularExpression, .caseInsensitive])
        guard mixerVerbCount(in: actionText) <= 1 else {
            return "No changes: multiple mixer actions need a new direct request."
        }
        guard intent.action != nil || intent.addToStudio else { return "Which action should I review?" }
        if !intent.addToStudio, hasWord(["add", "include"], in: actionText) {
            return "No changes: the requested live shortcut was omitted. Review both parts of a new request."
        }
        if intent.addToStudio {
            guard let evidence = intent.evidence.add, copied(evidence, from: actionText),
                hasWord(["add", "include", "shortcut"], in: evidence)
            else {
                return "No changes: adding a live shortcut needs explicit current-request evidence."
            }
        } else if intent.evidence.add != nil {
            return "No changes: inconsistent add evidence."
        }
        guard let action = intent.action else {
            return intent.amount == nil && intent.evidence.action == nil && intent.evidence.amount == nil
                ? nil : "No changes: an amount without an action cannot be reviewed."
        }
        guard let evidence = intent.evidence.action, copied(evidence, from: actionText) else {
            return "No changes: the action must be stated in the current request."
        }
        let verbs: [String]
        switch action {
        case .lower: verbs = ["lower", "down", "reduce", "decrease", "quieter"]
        case .raise: verbs = ["raise", "up", "increase", "louder"]
        case .setDB, .setFaderPercent: verbs = ["set", "turn", "to"]
        case .mute: verbs = ["mute"]
        case .unmute: verbs = ["unmute"]
        }
        guard hasWord(verbs, in: evidence) else { return "No changes: the action evidence is inconsistent." }
        if action == .mute || action == .unmute {
            return intent.amount == nil && intent.evidence.amount == nil
                ? nil : "No changes: mute/unmute does not take a numeric amount."
        }
        guard let amount = intent.amount else {
            return (action == .lower || action == .raise) && intent.evidence.amount == nil
                ? nil : "Specify an absolute amount before reviewing this change."
        }
        guard amount.isFinite, let amountEvidence = intent.evidence.amount,
            copied(amountEvidence, from: text), number(in: amountEvidence) == amount
        else {
            return "No changes: the amount must match a finite number in the current request."
        }
        switch action {
        case .lower, .raise:
            guard amount > 0, amount <= 100, hasDBUnit(in: amountEvidence) else {
                return "Specify a positive relative amount in dB."
            }
        case .setDB:
            guard (-90...10).contains(amount), hasDBUnit(in: amountEvidence) else {
                return "Absolute fader levels must be -90...+10 dB."
            }
        case .setFaderPercent:
            guard (0...100).contains(amount), hasAmountUnit(#"(?:%|percent)"#, in: amountEvidence) else {
                return "Specify 0...100% of fader travel (not loudness)."
            }
        case .mute, .unmute: break
        }
        return nil
    }

    private static func mixerVerbCount(in text: String) -> Int {
        let regex = try? NSRegularExpression(
            pattern: #"\b(set|lower|raise|turn|mute|unmute|reduce|decrease|increase)\b"#,
            options: .caseInsensitive)
        return regex?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    private static func copied(_ evidence: String, from text: String) -> Bool {
        guard !evidence.isEmpty, evidence.count <= 300 else { return false }
        return text.range(of: evidencePattern(evidence), options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func evidencePattern(_ evidence: String) -> String {
        "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: evidence) + "(?![\\p{L}\\p{N}])"
    }

    private static func hasWord(_ words: [String], in text: String) -> Bool {
        words.contains { word in
            text.range(
                of: "(?<![\\p{L}\\p{N}])" + word + "(?![\\p{L}\\p{N}])",
                options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func hasDBUnit(in text: String) -> Bool { hasAmountUnit(#"(?:db|decibels?)"#, in: text) }

    private static func hasAmountUnit(_ unit: String, in text: String) -> Bool {
        let pattern = #"^\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*"# + unit + #"\s*$"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func number(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"[+-]?(?:\d+(?:\.\d+)?|\.\d+)"#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first,
            let range = Range(match.range, in: text)
        else { return nil }
        return Double(text[range])
    }
}
