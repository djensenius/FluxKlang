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
        guard preservesMeaning(intent, in: text) else {
            return "No changes: the interpretation omitted or changed the requested operation or amount."
        }
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
        guard matchesActionEvidence(evidence, action: action, in: actionText) else {
            return "No changes: the action evidence is inconsistent."
        }
        if action == .mute || action == .unmute {
            return intent.amount == nil && intent.evidence.amount == nil
                ? nil : "No changes: mute/unmute does not take a numeric amount."
        }
        guard let amount = intent.amount else {
            return (action == .lower || action == .raise) && intent.evidence.amount == nil
                ? nil : "Specify an absolute amount before reviewing this change."
        }
        guard amount.isFinite, let amountEvidence = intent.evidence.amount,
            copiedAmount(amountEvidence, from: text), number(in: amountEvidence) == amount
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

    /// Copied spans alone do not prove that the model preserved the current clause's meaning.
    static func preservesMeaning(_ intent: AssistantActionIntent, in text: String) -> Bool {
        // A numeric suffix belongs to the target, not to an abbreviated model mention.
        let completeTarget = evidencePattern(intent.evidence.target)
            + #"(?!\s*[+-]?(?:\d|\.\d)|[.+-][\p{L}\p{N}])"#
        guard text.range(of: completeTarget, options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }
        let clause = text.replacingOccurrences(
            of: evidencePattern(intent.evidence.target), with: " ", options: [.regularExpression, .caseInsensitive])
        guard !hasUnsupportedControl(in: clause), !hasUnrepresentedTargets(in: clause),
              mixerVerbCount(in: clause) <= 1 else { return false }
        // Multiple source/destination numbers cannot be bound safely by copied spans alone.
        if let amount = intent.amount, number(in: clause) != amount { return false }
        let lower = hasWord(actionWords(.lower), in: clause)
        let raise = hasWord(actionWords(.raise), in: clause)
        let mute = hasWord(actionWords(.mute), in: clause)
        let unmute = hasWord(actionWords(.unmute), in: clause)
        if intent.amount == nil,
           clause.contains("%") || hasWord(["by", "db", "decibel", "decibels", "percent"], in: clause)
            || clause.range(of: #"[+-]?(?:\d+(?:\.\d+)?|\.\d+)"#, options: .regularExpression) != nil { return false }
        let destination = clause.range(
            of: #"\b(?:to|at)\s*[+-]?(?:\d|\.)"#, options: [.regularExpression, .caseInsensitive]) != nil
        switch intent.action {
        case .none:
            return !lower && !raise && !mute && !unmute && !hasWord(
                ["set", "turn", "put", "bring", "adjust", "change", "make", "mute", "unmute", "silence"], in: clause)
        case .lower: return lower && !raise && !destination && !mute && !unmute
        case .raise: return raise && !lower && !destination && !mute && !unmute
        case .setDB, .setFaderPercent:
            return !lower && !raise && !mute && !unmute && !hasWord(["by"], in: clause)
        case .mute: return !lower && !raise && !unmute
        case .unmute: return !lower && !raise && !mute
        }
    }

    static func matchesActionEvidence(
        _ evidence: String, action: AssistantActionIntent.Action, in text: String
    ) -> Bool {
        copied(evidence, from: text) && hasWord(actionWords(action), in: evidence)
    }

    static func copiedAmount(_ evidence: String, from text: String) -> Bool {
        guard copied(evidence, from: text) else { return false }
        let token = NSRegularExpression.escapedPattern(for: evidence.trimmingCharacters(in: .whitespacesAndNewlines))
        let pattern = #"(?<![\p{L}\p{N}_.+\-−])"# + token + #"(?![\p{L}\p{N}_.%])"#
        return !token.isEmpty && text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func actionWords(_ action: AssistantActionIntent.Action) -> [String] {
        switch action {
        case .lower: return ["lower", "down", "quieter", "softer", "reduce", "decrease", "attenuate", "cut"]
        case .raise: return ["raise", "up", "louder", "boost", "increase"]
        case .mute: return ["mute", "silence"]
        case .unmute: return ["unmute", "unsilence"]
        case .setDB, .setFaderPercent:
            return ["set", "turn", "to", "put", "bring", "adjust", "change", "volume", "level", "fader", "gain", "make"]
        }
    }

    private static func hasUnrepresentedTargets(in clause: String) -> Bool {
        // Removing the complete represented alias also preserves saved pair names containing "and".
        // A remaining conjunction may introduce another represented action, but not another target.
        let actions = ["add", "include", "turn", "set", "make", "put", "bring", "adjust", "change",
                       "lower", "raise", "reduce", "decrease", "increase", "boost", "attenuate",
                       "cut", "mute", "unmute", "silence", "unsilence"].joined(separator: "|")
        let pattern = #"(?:\b(?:and|plus|along with|as well as)\b|[,&/])\s*+(?!(?:"# + actions + #")\b)"#
        return hasWord(
            ["both", "except", "excepting", "exclude", "excludes", "excluding", "without", "besides", "but",
             "omit", "omitting", "other than", "apart from", "save for", "leave out"], in: clause)
            || clause.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasUnsupportedControl(in clause: String) -> Bool {
        hasWord(
            ["preamp", "preamplifier", "headamp", "trim", "pan", "balance", "eq", "equalizer", "equaliser",
             "compressor", "compression", "threshold", "ratio", "attack", "release", "gate", "filter",
             "frequency", "hpf", "lpf", "phantom", "48v", "send", "sends", "bus", "aux", "routing", "route", "patch",
             "wire", "connect", "rewire", "reroute", "solo", "unsolo"],
            in: clause)
            || clause.range(of: #"\binput\s+(?:gain|level|trim)\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func mixerVerbCount(in text: String) -> Int {
        let regex = try? NSRegularExpression(
            pattern: #"\b(set|lower|raise|turn|mute|unmute|reduce|decrease|increase|silence|unsilence|"#
                + #"boost|attenuate|cut|put|bring|adjust|change|make)\b"#,
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
