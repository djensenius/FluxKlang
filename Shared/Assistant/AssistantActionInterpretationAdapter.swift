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
        let fields = [output.target, output.targetEvidence, output.actionEvidence ?? "",
                      output.amountEvidence ?? "", output.addEvidence ?? ""]
        guard request.text.count <= maximumTextLength, fields.allSatisfy({ $0.count <= 160 }),
              output.clarification.count <= 400 else { return .clarification(invalidOutput) }
        switch output.disposition {
        case .answer:
            guard output.target.isEmpty, output.action == nil, output.amount == nil, !output.addToStudio,
                  fields.allSatisfy(\.isEmpty), output.clarification.isEmpty
            else { return .clarification(invalidOutput) }
            return .answer
        case .clarification:
            guard !output.clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  output.target.isEmpty, output.action == nil, output.amount == nil, !output.addToStudio,
                  fields.allSatisfy(\.isEmpty)
            else { return .clarification(invalidOutput) }
            return .clarification("No changes were made. " + output.clarification)
        case .proposal:
            guard !output.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  output.target == output.targetEvidence,
                  copied(output.targetEvidence, from: request.text), output.clarification.isEmpty,
                  output.action != nil || output.addToStudio,
                  output.action != nil
                    ? copied(output.actionEvidence, from: request.text) : output.actionEvidence == nil,
                  output.addToStudio ? copied(output.addEvidence, from: request.text) : output.addEvidence == nil
            else { return .clarification(invalidOutput) }
            guard validAmount(output) else { return .clarification(invalidOutput) }
            if let amount = output.amount {
                guard let evidence = output.amountEvidence, copied(evidence, from: request.text),
                      numericValue(evidence) == amount else { return .clarification(invalidOutput) }
            } else if output.amountEvidence != nil { return .clarification(invalidOutput) }
            return .proposal(AssistantActionIntent(
                targetMention: output.target, action: output.action, amount: output.amount,
                addToStudio: output.addToStudio,
                evidence: .init(target: output.targetEvidence, action: output.actionEvidence,
                                amount: output.amountEvidence, add: output.addEvidence)))
        }
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

    private static func numericValue(_ evidence: String) -> Double? {
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
        if isReadOnlyQuestion(request.text) { return .answer }
        switch AssistantMixerIntent.parse(request.text) {
        case .command(let command): return exactProposal(command, request: request)
        case .clarification:
            return .clarification(guidance(reason))
        case .notMixerIntent:
            let text = request.text.lowercased()
            if text.range(of: #"\b(volume|fader|quieter|louder|mute|unmute|turn down|turn up)\b"#,
                          options: .regularExpression) != nil {
                return .clarification(guidance(reason))
            }
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
            of: #"^(?:how|what|why|where|which|who|explain|help|list|show|is|are|does|can i)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
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
        var output = AssistantActionModelOutput(disposition: .proposal, target: target,
                                               targetEvidence: target, actionEvidence: actionWord)
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
