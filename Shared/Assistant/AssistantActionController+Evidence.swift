import Foundation

extension AssistantActionController {
    static var discoveryAddresses: [String] {
        (1...40).flatMap {
            [WingAddress.name(.channel, $0), WingAddress.channelSourceGroup($0), WingAddress.channelSourceIndex($0)]
        } + StudioHomeConnections.inputRange.map { WingAddress.inputName($0) }
    }

    static func channelNames(_ values: [String: WingValue]) -> [Int: String]? {
        var names: [Int: String] = [:]
        for channel in 1...40 {
            guard let name = values[WingAddress.name(.channel, channel)]?.stringValue,
                values[WingAddress.channelSourceGroup(channel)]?.stringValue != nil,
                values[WingAddress.channelSourceIndex(channel)]?.intValue != nil
            else { return nil }
            names[channel] = name
        }
        return names
    }

    static func candidates(
        intent: AssistantActionIntent, wing: WingController, discovery: [String: WingValue],
        scope: AssistantActionScope, strips: [FaderStrip]
    )
        -> [AssistantActionCandidate] {
        var live = AssistantLiveWingContext.project(
            wing.confirmedSnapshot(), equipment: scope.equipment,
            connections: scope.connections)
        // Blank scribbles never enter named alias/pair resolution, including LOCAL aliases.
        let names = channelNames(discovery) ?? [:]
        if case .node(let node) = AssistantActionTargetResolver.target(intent.targetMention), node.kind == .channel,
            let label = names[node.index], label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let index = node.index
            live.observations.append(
                .init(
                    kind: .channel, index: index, label: AssistantUntrustedText(label),
                    receivedAt: Date(), sourceGroup: discovery[WingAddress.channelSourceGroup(index)]?.stringValue,
                    sourceIndex: discovery[WingAddress.channelSourceIndex(index)]?.intValue.map(Int.init)))
        }
        return AssistantActionTargetResolver.candidates(
            mention: intent.targetMention, live: live,
            names: names, layout: FaderLayout(strips: strips), equipment: scope.equipment)
    }

    static func memberAddresses(_ identities: [AssistantActionChannelIdentity]) -> [String] {
        identities.flatMap { identity in
            let node = identity.node
            var addresses = [
                WingAddress.name(node.kind, node.index), WingAddress.fader(node.kind, node.index),
                WingAddress.mute(node.kind, node.index)
            ]
            if node.kind == .channel {
                addresses += [WingAddress.channelSourceGroup(node.index), WingAddress.channelSourceIndex(node.index)]
            }
            return addresses
        }
    }

    static func discoveryUnchanged(_ original: [String: WingValue], snapshot: WingConfirmedSnapshot) -> Bool {
        original.allSatisfy { snapshot.freshValue($0.key) == $0.value }
    }

    static func targetEvidence(
        _ candidate: AssistantActionCandidate, session: UUID,
        fresh: [String: WingValue]
    ) -> AssistantActionTargetEvidence? {
        guard (1...2).contains(candidate.members.count),
            candidate.members.count == 1 || candidate.pairStripID != nil,
            Set(candidate.members.map(\.node)).count == candidate.members.count
        else { return nil }
        var members: [AssistantActionMemberEvidence] = []
        for identity in candidate.members {
            let node = identity.node
            guard node.kind == .channel || node.kind == .main, (1...node.kind.count).contains(node.index),
                fresh[WingAddress.name(node.kind, node.index)]?.stringValue == identity.label,
                let position = fresh[WingAddress.fader(node.kind, node.index)]?.floatValue,
                position.isFinite, (0...1).contains(position),
                let muted = fresh[WingAddress.mute(node.kind, node.index)]?.intValue,
                muted == 0 || muted == 1
            else { return nil }
            if node.kind == .channel {
                guard let group = identity.sourceGroup, let index = identity.sourceIndex,
                    fresh[WingAddress.channelSourceGroup(node.index)]?.stringValue == group,
                    fresh[WingAddress.channelSourceIndex(node.index)]?.intValue == Int32(exactly: index)
                else { return nil }
            }
            members.append(.init(identity: identity, position: position, muted: muted == 1))
        }
        return .init(sessionID: session, members: members, pairStripID: candidate.pairStripID)
    }

    static func summary(intent: AssistantActionIntent, candidate: AssistantActionCandidate?, suggested: Float?)
        -> String {
        guard let candidate else {
            return "Select the exact live channel or saved stereo unit to review. No changes made."
        }
        var components: [String] = []
        if intent.addToStudio {
            components.append("Add \(candidate.title) as a live canvas shortcut (not Equipment or routing).")
        }
        if let action = intent.action {
            switch action {
            case .lower, .raise:
                let direction = action == .lower ? "lower" : "raise"
                components.append(
                    suggested != nil
                        ? "Suggested change: \(direction) by 3 dB (amount not specified)."
                        : "\(direction.capitalized) by \(intent.amount ?? 0) dB.")
            case .setFaderPercent:
                components.append("Set existing fader to \(intent.amount ?? 0)% of fader travel (not loudness).")
            case .setDB: components.append("Set existing fader master to \(intent.amount ?? 0) dB.")
            case .mute: components.append("Mute existing channel(s).")
            case .unmute: components.append("Unmute existing channel(s).")
            }
        }
        return components.joined(separator: " ")
    }

    static func warnings(intent: AssistantActionIntent, target: AssistantActionTargetEvidence?) -> [String] {
        var warnings = ["Explicit confirmation is required. No routing, cables, Home or Equipment changes."]
        if intent.addToStudio, intent.action != nil {
            warnings.append(
                "Non-atomic: shortcut is added first. A failed or uncertain send can leave the shortcut; "
                    + "no automatic retry or rollback."
            )
        }
        if target?.members.contains(where: { $0.identity.equipmentID == nil }) == true {
            warnings.append("Not linked to saved Equipment; live labels are untrusted operator metadata.")
        }
        if target?.members.count == 2 {
            warnings.append(
                "Stereo uses two independent SETs, not an atomic gang. "
                    + "Absolute position preserves normalized position balance; relative dB applies per side. "
                    + "Bounds are rejected, never clamped."
            )
        }
        return warnings
    }
}
