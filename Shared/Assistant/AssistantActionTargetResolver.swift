import Foundation

/// Ranking is a convenience, never permission. Competing units always need selection;
/// explicit numeric identities exclude named alternatives (still requiring final review).
enum AssistantActionTargetResolver {
    enum Target {
        case node(WingNodeRef)
        case invalidIdentity
        case name
    }
    // Ranking and all ambiguity exits remain together; none of these matches is authorization.
    // swiftlint:disable:next cyclomatic_complexity
    static func candidates(
        mention: String, live: AssistantLiveWingContext,
        names: [Int: String], layout: FaderLayout,
        equipment: [Equipment]
    ) -> [AssistantActionCandidate] {
        let requested = AssistantLiveWingContext.normalize(mention)
        let explicit: WingNodeRef?
        switch target(mention) {
        case .node(let node): explicit = node
        case .invalidIdentity: return []
        case .name: explicit = nil
        }
        var result: [AssistantActionCandidate] = []
        let pairs = validPairs(in: layout)
        for observation in live.observations where observation.kind == .channel {
            guard !observation.isStale, !observation.conflict,
                explicit != nil || !observation.label.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let node = WingNodeRef.channel(observation.index)
            let identity = identity(for: observation)
            let paired = layout.strips.contains { $0.rightNode != nil && ($0.node == node || $0.rightNode == node) }
            let linkedName = equipment.first { $0.id == observation.equipmentID }?.name
            let localLabels = live.observations.filter {
                $0.kind == .localInput && !$0.isStale && !$0.conflict
                    && observation.sourceGroup == WingSourceGroup.local.rawValue
                    && $0.index == observation.sourceIndex
            }.map { $0.label.value }
            let match: AssistantActionCandidate.Match?
            if explicit == node {
                match = .explicitIdentity
            } else if explicit != nil {
                match = nil
            } else if requested == AssistantLiveWingContext.normalize(observation.label.value), !paired,
                !looksStereo(observation.label.value) {
                match = .exact
            } else if similar(mention, observation.label.value)
                || localLabels.contains(where: { similar(mention, $0) }) {
                match = .similar
            } else if linkedName.map({ similar(mention, $0) }) == true {
                match = .savedLink
            } else {
                match = nil
            }
            if let match {
                result.append(
                    .init(
                        id: node.id, title: "Channel \(node.index) · \(observation.label.value)",
                        members: [identity], pairStripID: nil, match: match))
            }
        }
        // Explicit channel N can target an unnamed channel, but never by a saved label alone.
        if let explicit, explicit.kind == .channel, result.isEmpty, let name = names[explicit.index], name.isEmpty {
            let observation = live.observations.first { $0.kind == .channel && $0.index == explicit.index }
            if let observation, !observation.conflict, !observation.isStale {
                result.append(
                    .init(
                        id: explicit.id, title: explicit.defaultLabel,
                        members: [identity(for: observation)], pairStripID: nil, match: .explicitIdentity))
            }
        }
        if explicit == nil {
            for strip in pairs {
                guard let right = strip.rightNode,
                    let leftObservation = live.observations.first(where: {
                        $0.kind == .channel && $0.index == strip.node.index
                    }),
                    let rightObservation = live.observations.first(where: {
                        $0.kind == .channel && $0.index == right.index
                    }),
                    !leftObservation.isStale, !rightObservation.isStale,
                    !leftObservation.conflict, !rightObservation.conflict,
                    !leftObservation.label.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !rightObservation.label.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let aliases = [leftObservation.label.value, rightObservation.label.value, strip.customLabel ?? ""]
                guard aliases.contains(where: { similar(mention, $0) }) else { continue }
                result.append(
                    .init(
                        id: "pair-" + strip.id.uuidString,
                        title:
                            "Stereo channels \(strip.node.index)/\(right.index) · "
                                + (strip.customLabel ?? leftObservation.label.value),
                        members: [identity(for: leftObservation), identity(for: rightObservation)],
                        pairStripID: strip.id, match: .similar))
            }
        }
        // Multiple aliases for the same ordered channel unit are not competing targets.
        var units: Set<[WingNodeRef]> = []
        return result.sorted { $0.id < $1.id }.filter { units.insert($0.members.map(\.node)).inserted }
    }

    static func validPairs(in layout: FaderLayout) -> [FaderStrip] {
        layout.strips.filter { strip in
            guard let right = strip.rightNode, strip.node.kind == .channel, right.kind == .channel,
                strip.node != right, (1...40).contains(strip.node.index), (1...40).contains(right.index)
            else { return false }
            return layout.strips.filter {
                $0.node == strip.node || $0.rightNode == strip.node || $0.node == right || $0.rightNode == right
            }.count == 1
        }
    }

    static func target(_ mention: String) -> Target {
        let text = AssistantLiveWingContext.normalize(mention)
        if text == "main" { return .node(.main(1)) }
        guard let range = text.range(of: #"^(channel|main)\s*\d+$"#, options: .regularExpression) else {
            return .name
        }
        let kind: WingNodeKind = text.hasPrefix("channel") ? .channel : .main
        let digits = text[range].dropFirst(kind == .channel ? "channel".count : "main".count)
            .trimmingCharacters(in: .whitespaces)
        guard let index = Int(digits), (1...kind.count).contains(index) else { return .invalidIdentity }
        return .node(.init(kind: kind, index: index))
    }

    private static func identity(for observation: AssistantLiveWingContext.Observation)
        -> AssistantActionChannelIdentity {
        .init(
            node: .channel(observation.index), label: observation.label.value,
            sourceGroup: observation.sourceGroup, sourceIndex: observation.sourceIndex,
            equipmentID: observation.equipmentID)
    }

    private static func looksStereo(_ label: String) -> Bool {
        let text = AssistantLiveWingContext.normalize(label)
        return [" l", " r", " left", " right"].contains { text.hasSuffix($0) }
    }

    private static func similar(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedLetters(lhs)
        let right = normalizedLetters(rhs)
        guard left.count >= 3, right.count >= 3 else { return left == right && !left.isEmpty }
        if left == right || left.contains(right) || right.contains(left) { return true }
        // A bounded one-edit distance ranks typos; it never auto-selects them.
        guard abs(left.count - right.count) <= 1, max(left.count, right.count) <= 160 else { return false }
        let longer = Array(left.count >= right.count ? left : right)
        let shorter = Array(left.count >= right.count ? right : left)
        var first = 0
        var second = 0
        var edits = 0
        while first < longer.count, second < shorter.count {
            if longer[first] == shorter[second] {
                first += 1
                second += 1
            } else {
                edits += 1
                if edits > 1 { return false }
                first += 1
                if longer.count == shorter.count { second += 1 }
            }
        }
        return edits + (longer.count - first) + (shorter.count - second) <= 1
    }

    private static func normalizedLetters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
