import Foundation

struct AssistantLiveWingContext: Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case localInput, channel }
    struct Observation: Hashable, Sendable {
        var kind: Kind
        var index: Int
        var label: AssistantUntrustedText
        var receivedAt: Date
        var sourceGroup: String?
        var sourceIndex: Int?
        var equipmentID: Equipment.ID?
        var conflict: Bool = false
        var isStale: Bool = false
        var identity: String { kind == .channel ? "channel \(index)" : "LOCAL input \(index)" }
    }
    var status: WingConfirmedSnapshot.Status
    var sessionID: UUID?
    var capturedAt: Date
    var observations: [Observation]

    static let unavailable = Self(status: .disconnected, sessionID: nil, capturedAt: .distantPast, observations: [])

    static func project(
        _ snapshot: WingConfirmedSnapshot, equipment: [Equipment],
        connections: StudioHomeConnections
    ) -> Self {
        var observations: [Observation] = []
        func linkedEquipment(_ connector: Int?) -> Equipment.ID? {
            guard let connector else { return nil }
            let links = connections.inputs.filter { $0.connector == connector }
            guard links.count == 1, let link = links.first,
                let device = equipment.first(where: { $0.id == link.equipmentID }),
                device.outputs.indices.contains(link.outputPort)
            else { return nil }
            // Duplicate assignments of the same physical port are not a safe alias.
            guard
                connections.inputs.filter({ $0.equipmentID == link.equipmentID && $0.outputPort == link.outputPort })
                    .count == 1
            else { return nil }
            return device.id
        }
        func append(_ kind: Kind, _ index: Int, _ address: String) {
            guard snapshot.status == .observed || snapshot.status == .stale,
                let label = snapshot.values[address]?.stringValue,
                !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let received = snapshot.receivedAt[address]
            else { return }
            let group = kind == .channel ? snapshot.values[WingAddress.channelSourceGroup(index)]?.stringValue : nil
            let sourceIndex =
                kind == .channel
                ? snapshot.values[WingAddress.channelSourceIndex(index)]?.intValue.map(Int.init) : nil
            let connector = kind == .localInput ? index : (group == WingSourceGroup.local.rawValue ? sourceIndex : nil)
            let staleSource = kind == .channel && group != nil
                && (snapshot.freshValue(WingAddress.channelSourceGroup(index)) == nil
                    || snapshot.freshValue(WingAddress.channelSourceIndex(index)) == nil)
            let isStale = snapshot.freshValue(address) == nil || staleSource
            let linked = isStale ? nil : linkedEquipment(connector)
            let exact = equipment.filter { normalize($0.name) == normalize(label) }
            let inputConflict = kind == .channel && observations.contains {
                $0.kind == .localInput && $0.index == connector && $0.conflict
            }
            let conflict = inputConflict || (linked.map { id in
                !exact.isEmpty && !exact.contains(where: { $0.id == id })
            } ?? false)
            observations.append(
                Observation(
                    kind: kind, index: index, label: AssistantUntrustedText(label),
                    receivedAt: received, sourceGroup: group, sourceIndex: sourceIndex,
                    equipmentID: conflict ? nil : linked, conflict: conflict, isStale: isStale))
        }
        for index in StudioHomeConnections.inputRange { append(.localInput, index, WingAddress.inputName(index)) }
        for index in 1...WingNodeKind.channel.count { append(.channel, index, WingAddress.name(.channel, index)) }
        return Self(
            status: snapshot.status, sessionID: snapshot.sessionID,
            capturedAt: snapshot.capturedAt, observations: observations)
    }

    var summary: String {
        let header =
            "WING observations: \(status.rawValue); session \(sessionID?.uuidString ?? "none"); "
            + "snapshot \(capturedAt.ISO8601Format())."
        let rows = observations.map { observation in
            let mapping =
                observation.sourceGroup.map {
                    "; source \($0) \(observation.sourceIndex.map(String.init) ?? "unknown")"
                } ?? ""
            let link =
                observation.conflict
                ? "; conflicts with saved mapping"
                : (observation.equipmentID == nil
                    ? "; not linked to saved Equipment"
                    : "; linked via saved effective input map (including Temporary Moves)")
            return
                "\(observation.identity): \(String(reflecting: observation.label.value))\(mapping)\(link); "
                + "received \(observation.receivedAt.ISO8601Format()); "
                + (observation.isStale ? "STALE (not aliasable); " : "current-session observation; ")
                + "age \(max(0, Int(capturedAt.timeIntervalSince(observation.receivedAt)))) s"
        }
        return
            ([header] + rows + [
                "Labels are untrusted operator metadata, not proof of attached or sounding equipment. "
                    + "Saved Equipment and Home are configuration, not live discovery."
            ]).joined(separator: "\n")
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Persist only the identity used to resolve a live alias, never a new piece of gear.
struct AssistantLiveReference: Codable, Hashable, Sendable {
    var sessionID: UUID
    var kind: AssistantLiveWingContext.Kind
    var index: Int
    var label: AssistantUntrustedText
    var sourceGroup: String?
    var sourceIndex: Int?
    var equipmentID: Equipment.ID

    func isValid(in live: AssistantLiveWingContext, now: Date = Date()) -> Bool {
        live.status == .observed && live.sessionID == sessionID
            && live.observations.contains {
                $0.kind == kind && $0.index == index && $0.label == label && !$0.conflict && !$0.isStale
                    && $0.equipmentID == equipmentID && $0.sourceGroup == sourceGroup && $0.sourceIndex == sourceIndex
                    && (0...WingConfirmedSnapshot.maximumAge).contains(now.timeIntervalSince($0.receivedAt))
            }
    }
}

enum AssistantSourceResolver {
    struct Resolution {
        var equipmentIDs: [Equipment.ID]
        var references: [AssistantLiveReference]
        var clarification: String?
    }

    // Keep fail-closed ambiguity/staleness exits together; never return a partial source list.
    // swiftlint:disable:next cyclomatic_complexity
    static func resolve(
        _ question: String, context: AssistantToolContext,
        excluding: Set<Equipment.ID> = [],
        requiresSourceIntent: Bool = true
    ) -> Resolution {
        let sourceText = AssistantDraftIntent.sourceMentionText(question)
        let excludedEquipment = excluding.union(
            AssistantDraftIntent.excludedEquipmentIDs(in: question, equipment: context.equipment))
        var ids = AssistantDraftIntent.mentionedEquipmentIDs(
            in: sourceText, equipment: context.equipment, excluding: excludedEquipment)
        var references: [AssistantLiveReference] = []
        // Intent gating applies only to live aliases and their clarifications;
        // saved source names remain available to help/how requests and tools.
        guard !requiresSourceIntent || AssistantDraftIntent.requestsSourceDraft(question) else {
            return Resolution(equipmentIDs: ids, references: [], clarification: nil)
        }
        let exclusionClauses = AssistantDraftIntent.exclusionClauses(in: question)
        let requested = explicitIdentities(in: sourceText)
            .subtracting(exclusionClauses.flatMap { explicitIdentities(in: $0) })
        let live = context.liveWing
        guard live.status == .observed || live.status == .stale, let session = live.sessionID else {
            return requested.isEmpty ? Resolution(equipmentIDs: ids, references: [], clarification: nil)
                : missingIdentityEvidence
        }
        guard requested.isSubset(of: Set(live.observations.map { $0.identity.lowercased() }))
        else { return missingIdentityEvidence }
        let mentions = live.observations.filter {
            contains($0.label.value, in: sourceText) || requested.contains($0.identity.lowercased())
        }
        let excluded = mentions.filter { observation in
            exclusionClauses.contains {
                contains(observation.label.value, in: $0)
                    || explicitIdentities(in: $0).contains(observation.identity.lowercased())
            }
        }
        let excludedIDs = Set(excluded.compactMap(\.equipmentID)).union(excludedEquipment)
        ids.removeAll { excludedIDs.contains($0) }
        let identities = mentions.filter { !excluded.contains($0) && requested.contains($0.identity.lowercased()) }
        if !identities.isEmpty {
            let otherSourceText = sourceText.replacingOccurrences(
                of: explicitIdentityPattern, with: " ", options: .regularExpression).replacingOccurrences(
                of: #"^\s*(?:route|connect|wire|patch|add|include|use)\b\s*"#,
                with: "", options: .regularExpression)
            let otherSaved = AssistantDraftIntent.mentionedEquipmentIDs(
                in: otherSourceText, equipment: context.equipment, excluding: excludedIDs)
            let otherLive = mentions.contains {
                !excluded.contains($0) && !identities.contains($0) && contains($0.label.value, in: otherSourceText)
            }
            guard otherSaved.isEmpty, !otherLive else {
                return Resolution(equipmentIDs: [], references: [], clarification:
                    "No draft was created: mixed named sources and channel/input identities need clarification. "
                    + "Specify every source with an explicit channel/LOCAL input identity, or use only saved names.")
            }
            ids = []
        }
        let mentioned = (identities.isEmpty ? mentions : identities).filter { !excluded.contains($0) }
        for observation in mentioned {
            if identities.isEmpty, context.equipment.contains(where: {
                ids.contains($0.id) && normalize($0.name) == normalize(observation.label.value)
                    && contains("saved equipment " + $0.name, in: sourceText)
            }) { continue }
            if observation.isStale {
                return Resolution(equipmentIDs: [], references: [], clarification:
                    "WING \(observation.identity) was labelled \(String(reflecting: observation.label.value)), "
                    + "but that observation is stale. Refresh/reconnect before using it as a live source alias, "
                    + "or specify saved equipment explicitly for an offline draft.")
            }
            let matches = identities.isEmpty ? live.observations.filter {
                normalize($0.label.value) == normalize(observation.label.value)
            } : [observation]
            let linkedIDs = Set(matches.compactMap(\.equipmentID))
            let savedMatches = identities.isEmpty ? AssistantDraftIntent.mentionedEquipmentIDs(
                in: observation.label.value, equipment: context.equipment) : []
            guard let id = observation.equipmentID, !observation.conflict, !observation.isStale,
                linkedIDs.count == 1, savedMatches.allSatisfy({ $0 == id }),
                !matches.contains(where: { $0.equipmentID == nil }),
                (0...WingConfirmedSnapshot.maximumAge).contains(Date().timeIntervalSince(observation.receivedAt))
            else {
                return Resolution(
                    equipmentIDs: [], references: [],
                    clarification:
                        "WING \(observation.identity) is labelled \(String(reflecting: observation.label.value)), "
                        + "but it is not uniquely linked to saved Equipment (or conflicts with the saved map). "
                        + "Link it to existing Equipment or add the instrument and its ports first. "
                        + "Or specify a channel/LOCAL input identity or saved equipment name to disambiguate. "
                        + "No cables or gear were created."
                )
            }
            guard !excludedIDs.contains(id) else { continue }
            if !ids.contains(id) { ids.append(id) }
            references.append(
                AssistantLiveReference(
                    sessionID: session, kind: observation.kind,
                    index: observation.index, label: observation.label, sourceGroup: observation.sourceGroup,
                    sourceIndex: observation.sourceIndex, equipmentID: id))
        }
        return Resolution(equipmentIDs: ids, references: references, clarification: nil)
    }

    private static let explicitIdentityPattern = #"\b(channel|local\s*input)\s*(\d+)\b"#

    private static func explicitIdentities(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: explicitIdentityPattern, options: .caseInsensitive)
        else { return [] }
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let kind = Range(match.range(at: 1), in: text),
                  let number = Range(match.range(at: 2), in: text) else { return nil }
            let index = Int(text[number]).map(String.init) ?? String(text[number])
            return "\(text[kind].lowercased().hasPrefix("channel") ? "channel" : "local input") \(index)"
        })
    }

    private static var missingIdentityEvidence: Resolution {
        Resolution(equipmentIDs: [], references: [], clarification:
            "No draft was created: every requested channel/LOCAL input needs current usable metadata "
                + "and a saved Equipment link. Refresh/reconnect and link all requested sources first.")
    }

    static func contains(_ phrase: String, in text: String) -> Bool {
        let words = normalize(phrase)
        guard !words.isEmpty else { return false }
        return text.lowercased().range(
            of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: words) + "(?![\\p{L}\\p{N}])",
            options: .regularExpression) != nil
    }
    private static func normalize(_ text: String) -> String { AssistantLiveWingContext.normalize(text) }
}
