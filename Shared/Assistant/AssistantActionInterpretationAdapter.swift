import Foundation

/// Value-only completed output, independently checked before it becomes untrusted domain intent.
struct AssistantActionModelOutput: Sendable {
    enum Disposition: String, Sendable { case answer, clarification, proposal }
    var disposition: Disposition
    var target: String = ""
    var action: AssistantActionIntent.Action?
    var amount: Double?
    var addToStudio = false
    var targetEvidence = ""
    var actionEvidence: String?
    var amountEvidence: String?
    var addEvidence: String?
    var clarification = ""
}

enum AssistantActionInterpretationAdapter {
    static let maximumTextLength = 2_000
    static let invalidOutput = "No changes were made. I couldn't validate that interpretation. "
        + "Specify one instrument and one change, or use the manual mixer controls."

    // All model fields, including apparently well-formed guided output, are untrusted.
    // swiftlint:disable:next cyclomatic_complexity
    static func validate(
        _ output: AssistantActionModelOutput, request: AssistantActionInterpretationRequest
    ) -> AssistantActionInterpretation {
        guard request.text.count <= maximumTextLength else { return .clarification(invalidOutput) }
        // Read-only classification grants no authority; discard any stray generated action fields.
        if output.disposition == .answer { return .answer }
        let fields = [output.target, output.targetEvidence, output.actionEvidence ?? "",
                      output.amountEvidence ?? "", output.addEvidence ?? ""]
        guard fields.allSatisfy({ $0.count <= 160 }),
              output.clarification.count <= 400 else { return .clarification(invalidOutput) }
        switch output.disposition {
        case .answer: return .answer
        case .clarification:
            guard !output.clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  output.target.isEmpty, output.action == nil, output.amount == nil, !output.addToStudio,
                  fields.allSatisfy(\.isEmpty)
            else { return .clarification(invalidOutput) }
            return .clarification("No changes were made. " + output.clarification)
        case .proposal:
            guard !output.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isNonActionSubmission(request.text), output.target == output.targetEvidence,
                  !word("add|include", in: request.text) || output.addToStudio,
                  copied(output.targetEvidence, from: request.text), output.clarification.isEmpty,
                  output.action != nil || output.addToStudio,
                  output.action != nil
                    ? copied(output.actionEvidence, from: request.text) : output.actionEvidence == nil,
                  output.addToStudio ? copied(output.addEvidence, from: request.text) : output.addEvidence == nil
            else { return .clarification(invalidOutput) }
            guard validAmount(output), validActionEvidence(output, text: request.text),
                  !output.addToStudio || word("add|include", in: output.addEvidence ?? "")
            else { return .clarification(invalidOutput) }
            if let amount = output.amount {
                guard let evidence = output.amountEvidence, copied(evidence, from: request.text),
                      numericValue(evidence) == amount, validUnit(evidence, action: output.action)
                else { return .clarification(invalidOutput) }
            } else if output.amountEvidence != nil { return .clarification(invalidOutput) }
            return .proposal(AssistantActionIntent(
                targetMention: output.target, action: output.action, amount: output.amount,
                addToStudio: output.addToStudio,
                evidence: .init(target: output.targetEvidence, action: output.actionEvidence,
                                amount: output.amountEvidence, add: output.addEvidence)))
        }
    }

    private static func validUnit(_ evidence: String, action: AssistantActionIntent.Action?) -> Bool {
        let suffix = evidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case .setFaderPercent: return suffix.hasSuffix("%") || suffix.hasSuffix("percent")
        case .lower, .raise, .setDB: return suffix.hasSuffix("db")
        case .mute, .unmute, .none: return false
        }
    }

    private static func validActionEvidence(_ output: AssistantActionModelOutput, text: String) -> Bool {
        guard let action = output.action else { return output.actionEvidence == nil }
        let evidence = output.actionEvidence ?? ""
        guard containsWholePhrase(evidence, in: text) else { return false }
        let lower = "lower|down|quieter|softer|reduce|decrease|attenuate|cut"
        let raise = "raise|up|louder|boost|increase"
        switch action {
        case .lower: return word(lower, in: evidence) && !word(raise, in: text)
        case .raise: return word(raise, in: evidence) && !word(lower, in: text)
        case .mute: return word("mute|silence", in: evidence) && !word("unmute|unsilence", in: text)
        case .unmute: return word("unmute|unsilence", in: evidence) && !word("mute|silence", in: text)
        case .setDB, .setFaderPercent:
            return word("set|turn|put|bring|adjust|change|volume|level|fader|gain|make", in: evidence)
        }
    }

    private static func word(_ alternatives: String, in text: String) -> Bool {
        text.range(of: "(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return word(NSRegularExpression.escapedPattern(for: phrase), in: text)
    }

    private static func validAmount(_ output: AssistantActionModelOutput) -> Bool {
        if let amount = output.amount, !amount.isFinite { return false }
        switch output.action {
        case .lower, .raise: return output.amount.map { $0 > 0 && $0 <= 100 } ?? true
        case .setDB: return output.amount.map { (-90...10).contains($0) } ?? false
        case .setFaderPercent: return output.amount.map { (0...100).contains($0) } ?? false
        case .mute, .unmute, .none: return output.amount == nil
        }
    }

    static func numericValue(_ evidence: String) -> Double? {
        let pattern = #"^\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*(?:%|percent|dB)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: evidence, range: NSRange(evidence.startIndex..., in: evidence)),
              let range = Range(match.range(at: 1), in: evidence) else { return nil }
        return Double(evidence[range])
    }

    private static func copied(_ evidence: String?, from text: String) -> Bool {
        guard let evidence, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text.range(of: evidence) != nil
    }

    /// Local exact grammar is an explicit degraded mode, never a cloud interpretation fallback.
    static func fallback(
        _ request: AssistantActionInterpretationRequest, reason: String
    ) -> AssistantActionInterpretation {
        if isNonActionSubmission(request.text) { return .answer }
        switch AssistantMixerIntent.parse(request.text) {
        case .command(let command): return exactProposal(command, request: request)
        case .clarification:
            return .clarification(guidance(reason))
        case .notMixerIntent:
            if isPlausibleAction(request.text) { return .clarification(guidance(reason)) }
            // Preserve read-only help/inventory and existing reviewed wiring-draft preflight.
            return .answer
        }
    }

    static func guidance(_ reason: String) -> String {
        "Apple command understanding is unavailable: \(String(reason.prefix(240))). No changes were made. "
            + "Use an exact command for review (for example, ‘lower channel 7 by 3 dB’ or ‘mute channel 7’), "
            + "or select the instrument with the manual mixer controls."
    }

    static func isReadOnlyQuestion(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:how|what|why|where|which|who|explain|describe|help|list|show|is|are|does|can i|"#
                + #"tell me (?:about|how)|(?:can|could|would) you (?:explain|describe|tell me|list|show me))\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Conservative exclusions only; positive conversational actions still require Apple interpretation.
    static func isNonActionSubmission(_ text: String) -> Bool {
        if isReadOnlyQuestion(text) { return true }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:hello|hi|hey|thanks|thank you|good morning|good evening)[.!?\s]*$"#,
            options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        if word("don't|do not|not|never|without|suppose|imagine|hypothetically|if|when", in: normalized) {
            return true
        }
        return text.contains(where: { "\"“”`".contains($0) })
            || text.range(of: #"(?:^|\s)'[^']+'"#, options: .regularExpression) != nil
    }

    /// This does not interpret actions; it prevents unknown action-looking input reaching cloud Q&A.
    static func isPlausibleAction(_ text: String) -> Bool {
        if isNonActionSubmission(text) { return false }
        return word("volume|fader|quieter|louder|softer|mute|unmute|silence|down|up|level|gain|db|percent|"
                    + "boost|cut|reduce|increase|decrease|bring|lower|raise|set|turn|make", in: text)
            || text.contains("%")
            || text.range(of: #"(?:^|\s)[+-]\d+(?:\.\d+)?\s*$"#, options: .regularExpression) != nil
    }

    private static func exactProposal(
        _ command: AssistantMixerCommand, request: AssistantActionInterpretationRequest
    ) -> AssistantActionInterpretation {
        let targetPattern: String
        switch command.target {
        case .channel(let index): targetPattern = #"\bchannel\s*"# + String(index) + #"\b"#
        case .main(let index):
            targetPattern = index == 1 ? #"\bmain(?:\s*1)?\b"# : #"\bmain\s*"# + String(index) + #"\b"#
        case .liveName(let name):
            targetPattern = name.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#)
        }
        guard let target = firstMatch(targetPattern, in: request.text),
              let actionWord = firstMatch(#"^\s*(set|lower|raise|turn|mute|unmute)\b"#, in: request.text)
        else { return .clarification(invalidOutput) }
        var actionEvidence = actionWord
        if case .adjustDB = command.operation, actionWord.lowercased() == "turn",
           let direction = firstMatch(#"\b(down|up)\b"#, in: request.text) {
            actionEvidence = direction
        }
        var output = AssistantActionModelOutput(disposition: .proposal, target: target,
                                               targetEvidence: target, actionEvidence: actionEvidence)
        switch command.operation {
        case .setDB(let amount): output.action = .setDB; output.amount = Double(amount)
        case .adjustDB(let amount):
            output.action = amount < 0 ? .lower : .raise
            output.amount = Double(abs(amount))
        case .mute(let muted): output.action = muted ? .mute : .unmute
        }
        if output.amount != nil {
            output.amountEvidence = firstMatch(#"[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*[dD][bB]$"#, in: request.text)
            // Recover the exact submitted decimal rather than a Float-rounded parser value.
            output.amount = output.amountEvidence.flatMap(numericValue)
        }
        return validate(output, request: request)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }
}
