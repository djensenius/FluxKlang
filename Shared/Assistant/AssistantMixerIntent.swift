import Foundation

/// Parsed only from the current, explicitly submitted user text. This type is
/// intentionally not an AssistantTool and cannot contain arbitrary OSC paths.
struct AssistantMixerCommand: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case main(Int)
        case channel(Int)
        case liveName(String)
    }
    enum Operation: Equatable, Sendable {
        case setDB(Float)
        case adjustDB(Float)
        case mute(Bool)
    }
    var target: Target
    var operation: Operation
}

enum AssistantMixerParseResult: Equatable, Sendable {
    case notMixerIntent
    case clarification(String)
    case command(AssistantMixerCommand)
}

enum AssistantMixerIntent {
    static let syntax = "Use one explicit mixer command: set main or channel N or an exact unique live channel name "
        + "to X dB; lower/raise or turn that target down/up by X dB; or mute/unmute that target. "
        + "Specify the target and amount; no default target or step is assumed."

    static func parse(_ text: String) -> AssistantMixerParseResult {
        let normalized = AssistantLiveWingContext.normalize(text)
        let classificationText = AssistantLiveWingContext.normalize(
            text.replacingOccurrences(of: "\n", with: ";").replacingOccurrences(of: "\r", with: ";"))
        guard resemblesMixerRequest(classificationText) else { return .notMixerIntent }
        // Never partially execute quoted, negated, informational, hypothetical,
        // compound or routing/mixer requests. Unknown syntax also fails closed.
        guard text.count <= 200, !text.contains(where: { "\"'“”‘’`;\n\r?!".contains($0) }),
            normalized.range(
                of: #"\b(and|then|also|but|not|never|dont|don't|do|if|when|how|what|why|explain|"#
                    + #"route|routing|patch|connect|wire|through|send)\b"#,
                options: .regularExpression) == nil
        else {
            return .clarification(
                "No mixer changes were made. Submit a single direct, unquoted mixer command "
                    + "separately from routing or questions. " + syntax)
        }
        let number = #"([+-]?(?:\d+(?:\.\d+)?|\.\d+))"#
        if let match = groups(#"^set (.+) to "# + number + #"\s*db$"#, in: normalized),
            let amount = Float(match[1]), amount.isFinite {
            guard (-90...10).contains(amount) else {
                return .clarification("No changes: fader levels must be finite and within -90...+10 dB.")
            }
            return command(target: match[0], operation: .setDB(amount))
        }
        if let match = groups(#"^(lower|raise) (.+) by\s*"# + number + #"\s*db$"#, in: normalized),
            let amount = Float(match[2]), amount.isFinite, amount > 0 {
            return command(target: match[1], operation: .adjustDB(match[0] == "lower" ? -amount : amount))
        }
        if let match = groups(#"^turn (.+) (down|up) by\s*"# + number + #"\s*db$"#, in: normalized),
           let amount = Float(match[2]), amount.isFinite, amount > 0 {
            return command(target: match[0], operation: .adjustDB(match[1] == "down" ? -amount : amount))
        }
        if let match = groups(#"^turn (down|up) (.+) by\s*"# + number + #"\s*db$"#, in: normalized),
           let amount = Float(match[2]), amount.isFinite, amount > 0 {
            return command(target: match[1], operation: .adjustDB(match[0] == "down" ? -amount : amount))
        }
        if let match = groups(#"^(mute|unmute) (.+)$"#, in: normalized) {
            return command(target: match[1], operation: .mute(match[0] == "mute"))
        }
        return .clarification("No mixer changes were made. " + syntax)
    }

    private static func resemblesMixerRequest(_ text: String) -> Bool {
        let verb = #"(?:set(?!\s+up\b)|lower|raise|turn|mute|unmute)\b"#
        let quote = #"[\"'“”‘’`]*"#
        let prefix = #"(?:please |don't |do not |never |not |if |when |how (?:do i |to |can i )?|"#
            + #"what is |why |explain |can you |could you )?"#
        let clause = #"(?:^|[,;\n]\s*|\b(?:and|then|also|but)\s+)"#
        return text.range(of: clause + quote + prefix + quote + verb, options: .regularExpression) != nil
    }

    private static func command(
        target: String, operation: AssistantMixerCommand.Operation
    ) -> AssistantMixerParseResult {
        let resolved: AssistantMixerCommand.Target
        if target == "main" {
            resolved = .main(1)
        } else if let groups = groups(#"^(channel|main)\s*(\d+)$"#, in: target), let index = Int(groups[1]) {
            guard (1...(groups[0] == "channel" ? 40 : 4)).contains(index) else {
                return .clarification("No changes: channels are 1...40 and mains are 1...4.")
            }
            resolved = groups[0] == "channel" ? .channel(index) : .main(index)
        } else {
            guard target.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} _-]*$"#, options: .regularExpression) != nil,
                !["volume", "the volume", "fader", "channel", "speakers", "it", "that", "this"].contains(target),
                !target.hasPrefix("channel "), !target.hasPrefix("main ")
            else {
                return .clarification("Which channel or main do you mean? " + syntax)
            }
            resolved = .liveName(target)
        }
        return .command(AssistantMixerCommand(target: resolved, operation: operation))
    }

    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.range.length == (text as NSString).length
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

@MainActor
protocol AssistantMixerExecuting: AnyObject {
    func execute(_ command: AssistantMixerCommand, sessionID: UUID?) async -> String
}

/// Pure name resolution, deliberately limited to exact current live channel
/// names. Saved library/fader labels alone are not authorization for a target.
enum AssistantMixerTargetResolver {
    enum Result: Equatable { case node(WingNodeRef), clarification(String) }
    static func resolve(_ target: AssistantMixerCommand.Target, names: [Int: String], layout: FaderLayout) -> Result {
        switch target {
        case .channel(let index):
            guard (1...40).contains(index) else { return .clarification("Invalid channel.") }
            return .node(.channel(index))
        case .main(let index):
            guard (1...4).contains(index) else { return .clarification("Invalid main.") }
            return .node(.main(index))
        case .liveName(let name):
            let normalized = AssistantLiveWingContext.normalize(name)
            let matches = names.filter { AssistantLiveWingContext.normalize($0.value) == normalized }.map(\.key)
            let stereo = layout.strips.contains { strip in
                guard strip.rightNode != nil else { return false }
                return matches.contains(strip.node.index) && strip.node.kind == .channel
                    || (strip.rightNode?.kind == .channel && matches.contains(strip.rightNode!.index))
                    || strip.customLabel.map { AssistantLiveWingContext.normalize($0) == normalized } == true
            }
            let suffixed = names.values.contains {
                let value = AssistantLiveWingContext.normalize($0)
                return [" l", " r", " left", " right"].contains { value == normalized + $0 || normalized.hasSuffix($0) }
            }
            guard !stereo, !suffixed else {
                return .clarification(
                    "That name may identify a stereo pair. Specify an individual channel number; "
                        + "no left-only or ganged change was assumed."
                )
            }
            guard matches.count == 1, let index = matches.first, (1...40).contains(index) else {
                return .clarification(
                    "Use an exact unique current live channel name or specify channel N. No changes were made.")
            }
            return .node(.channel(index))
        }
    }
}
