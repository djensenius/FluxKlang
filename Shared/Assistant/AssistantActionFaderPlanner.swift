import Foundation

/// Pure position policy. Percent always means normalized fader travel, never acoustic loudness.
enum AssistantActionFaderPlanner {
    // Keep finite/off/bounds checks beside the operation they constrain.
    // swiftlint:disable:next cyclomatic_complexity
    static func changes(intent: AssistantActionIntent, target: AssistantActionTargetEvidence)
        -> [AssistantActionFaderChange]? {
        guard (1...2).contains(target.members.count),
            target.members.count == 1 || target.pairStripID != nil,
            target.members.allSatisfy({ $0.position.isFinite && (0...1).contains($0.position) })
        else { return nil }
        guard let action = intent.action else { return [] }
        let amount = Float(intent.amount ?? 3)
        guard amount.isFinite else { return nil }
        let delta: Float = target.members.count == 2 ? target.members[1].position - target.members[0].position : 0
        var result: [AssistantActionFaderChange] = []
        for (index, member) in target.members.enumerated() {
            var afterPosition = member.position
            var afterMuted = member.muted
            switch action {
            case .mute: afterMuted = true
            case .unmute: afterMuted = false
            case .lower, .raise:
                guard !FaderMath.isOff(position: member.position), amount > 0 else { return nil }
                let decibels = FaderMath.decibels(fromPosition: member.position) + (action == .lower ? -amount : amount)
                guard decibels.isFinite, (-90...10).contains(decibels) else { return nil }
                afterPosition = FaderMath.position(fromDecibels: decibels)
            case .setDB, .setFaderPercent:
                guard intent.amount != nil else { return nil }
                let desiredPosition: Float
                if action == .setDB {
                    guard (-90...10).contains(amount) else { return nil }
                    desiredPosition = FaderMath.position(fromDecibels: amount)
                } else {
                    guard (0...100).contains(amount) else { return nil }
                    desiredPosition = amount / 100
                }
                afterPosition = desiredPosition + (index == 0 ? -delta / 2 : delta / 2)
            }
            guard afterPosition.isFinite, (0...1).contains(afterPosition) else { return nil }
            result.append(
                .init(
                    node: member.identity.node, beforePosition: member.position,
                    afterPosition: afterPosition, beforeMuted: member.muted, afterMuted: afterMuted,
                    changesMute: action == .mute || action == .unmute))
        }
        return result
    }
}
