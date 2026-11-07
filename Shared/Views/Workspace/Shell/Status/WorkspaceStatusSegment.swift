//
//  WorkspaceStatusSegment.swift
//  FluxKlang
//
//  One segment of the status strip (#99 W3) and the six factories that derive
//  them. A segment is built only by those factories, in this file, from
//  validated inputs; its label is the full sentence that VoiceOver reads.
//

/// One segment of the status strip: a stable ID, the short strip text, the full-sentence accessibility
/// label, a severity (text and glyph, never colour alone) and what entered a lost or muted state.
struct WorkspaceStatusSegment: Hashable, Sendable {
    /// The most device names, or lost capability names, a label lists before "and N more".
    static let maximumDeviceRows = 4
    /// The most peers the Peers segment lists before "and N more".
    static let maximumPeerRows = 3

    let id: WorkspaceStatusSegmentID
    /// The short text shown in the strip.
    let text: String
    /// "<Title>: <sentence>": what VoiceOver reads for the segment.
    let label: String
    let severity: WorkspaceStatusSeverity
    /// What entered a lost or muted state, in a stable order. Names are kept as they come, duplicates included,
    /// and the announcer compares them as a multiset: an item that occurs more often than before is a new
    /// error to announce.
    let lostItems: [String]

    var title: String { id.title }
    var glyphName: String { severity.glyphName }
    var opensDetailList: Bool { id.opensDetailList }

    /// `detail` replaces `text` in the label when the full sentence says more than the strip does.
    fileprivate init(
        _ id: WorkspaceStatusSegmentID, text: String, detail: String? = nil,
        severity: WorkspaceStatusSeverity, lostItems: [String] = []
    ) {
        self.id = id
        self.text = text
        label = "\(id.title): \(detail ?? text)"
        self.severity = severity
        self.lostItems = lostItems
    }
}

// MARK: - Engine

extension WorkspaceStatusSegment {
    /// The Engine segment. A preparing lifecycle always keeps the strip text `Preparing rev N...`; the `over:`
    /// set it renders meanwhile decides the rest: over an absent or a running set the segment is normal, over a
    /// degraded set it is an error that lists the lost capabilities (see `preparingEngine(revision:over:)`).
    static func engine(_ engine: WorkspaceStatusEngine) throws(WorkspaceStatusRefusal) -> Self {
        try WorkspaceStatusInputs.validate(name: engine.hostName, field: .hostName)
        switch engine.lifecycle {
        case .stopped:
            return Self(.engine, text: "Engine stopped", severity: .normal)
        case .preparing(let revision, over: let base):
            return preparingEngine(revision: revision, over: base)
        case .running:
            return Self(.engine, text: "Running (\(engine.hostName))", severity: .normal)
        case .degraded(let lost):
            return degradedEngine(lost: lost)
        case .recovering:
            return Self(.engine, text: "Recovering engine...", severity: .error, lostItems: ["Engine"])
        case .heldByOther(let project):
            // Follow-up before integration: the raw ProjectID (possibly a UUID) is spoken, not a display name.
            return Self(.engine, text: "Engine in use by \(project.rawValue)", severity: .attention)
        }
    }

    /// A preparing engine. The strip says `Preparing rev N...` over every base. Over an absent or a running set
    /// that is all there is. Over a degraded set the capabilities stay lost while the revision prepares, so the
    /// segment stays an error with the same lost items as a degraded engine (a loss during preparation is a new
    /// error, and an ongoing loss does not read as cleared), and the label continues with the degraded engine's
    /// sentence: `Preparing rev 43... Running: A, B Lost/Muted`.
    private static func preparingEngine(revision: ContractRevision, over base: RunningSetState) -> Self {
        let text = "Preparing rev \(revision.value)..."
        switch base {
        case .absent, .running:
            return Self(.engine, text: text, severity: .normal)
        case .degraded(let lost):
            let names = lost.map(\.rawValue)
            let detail = "\(text) \(lostCapabilitiesSentence(names))"
            return Self(.engine, text: text, detail: detail, severity: .error, lostItems: names)
        }
    }

    private static func degradedEngine(lost: [CapabilityID]) -> Self {
        // Follow-up before integration: raw CapabilityIDs (possibly UUIDs) are spoken, not display names.
        let names = lost.map(\.rawValue)
        return Self(.engine, text: lostCapabilitiesSentence(names), severity: .error, lostItems: names)
    }

    /// `Running: A, B Lost/Muted`, cut off after four names with `, and N more` (every name in it is lost, so
    /// "more" counts only lost ones); `Running: Lost/Muted` when the list is empty. Shared by the degraded
    /// engine and by a preparing engine over a degraded set, so the two cannot disagree.
    private static func lostCapabilitiesSentence(_ names: [String]) -> String {
        let list = WorkspaceStatusFormat.summary(names, limit: maximumDeviceRows)
        return list.isEmpty ? "Running: Lost/Muted" : "Running: \(list) Lost/Muted"
    }
}

// MARK: - Devices

extension WorkspaceStatusSegment {
    /// What the Devices segment says, derived once from the rows and the two input permissions.
    private struct DeviceFacts {
        let missingNames: [String]
        let staleCount: Int
        /// "NAME missing" or "NAME stale" for every problem row, in row order; only a missing row is lost.
        let problems: [WorkspaceStatusListEntry]
        let microphoneOff: Bool
        let bluetoothOff: Bool

        init(rows: [WorkspaceStatusDevice], permissions: WorkspaceStatusPermissions) {
            missingNames = rows.filter { $0.presence == .missing }.map(\.name)
            staleCount = rows.filter { $0.presence == .stale }.count
            problems = rows.compactMap(Self.problem)
            // Follow-up before integration: a permission that is confirmed off raises attention even when no
            // device needs it, against the spec's "Nothing until a Bluetooth controller is added".
            microphoneOff = WorkspaceStatusInputs.blocksAccess(permissions.microphone)
            bluetoothOff = WorkspaceStatusInputs.blocksAccess(permissions.bluetoothMIDI)
        }

        private static func problem(_ row: WorkspaceStatusDevice) -> WorkspaceStatusListEntry? {
            switch row.presence {
            case .present: return nil
            case .missing: return WorkspaceStatusListEntry(text: "\(row.name) missing", isLost: true)
            case .stale: return WorkspaceStatusListEntry(text: "\(row.name) stale", isLost: false)
            }
        }

        var severity: WorkspaceStatusSeverity {
            if !missingNames.isEmpty { return .error }
            return staleCount > 0 || microphoneOff || bluetoothOff ? .attention : .normal
        }

        func stripText(hasRows: Bool) -> String {
            var parts: [String] = []
            if !missingNames.isEmpty { parts.append("\(missingNames.count) missing") }
            if staleCount > 0 { parts.append("\(staleCount) stale") }
            if microphoneOff { parts.append("Microphone off") }
            if bluetoothOff { parts.append("Bluetooth MIDI off") }
            guard !parts.isEmpty else { return hasRows ? "All present" : "No devices" }
            return parts.joined(separator: ", ")
        }

        /// The label sentence, or nil when the strip text already says everything. A list cut off by the row
        /// cap names the number of hidden missing devices, so a new error behind "and N more" is audible.
        var detail: String? {
            var parts: [String] = []
            if !problems.isEmpty {
                let limit = WorkspaceStatusSegment.maximumDeviceRows
                parts.append(WorkspaceStatusFormat.summary(problems, limit: limit, lostWord: "missing"))
            }
            if microphoneOff { parts.append("Microphone access is off") }
            if bluetoothOff { parts.append("Bluetooth MIDI access is off") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    /// The Devices segment: the missing and stale rows, then the input permissions that are confirmed off.
    /// Every name is validated, including the names the label does not list.
    static func devices(
        _ rows: [WorkspaceStatusDevice], permissions: WorkspaceStatusPermissions
    ) throws(WorkspaceStatusRefusal) -> Self {
        for (index, row) in rows.enumerated() {
            try WorkspaceStatusInputs.validate(name: row.name, field: .deviceName(index: index))
        }
        let facts = DeviceFacts(rows: rows, permissions: permissions)
        return Self(
            .devices, text: facts.stripText(hasRows: !rows.isEmpty), detail: facts.detail,
            severity: facts.severity, lostItems: facts.missingNames
        )
    }
}

// MARK: - Clock

extension WorkspaceStatusSegment {
    /// The Clock segment: the nominal and the actual rate, shown separately. An actual that differs from
    /// the nominal is not an error; an unavailable actual is `.attention`.
    static func clock(_ clock: WorkspaceStatusClock) throws(WorkspaceStatusRefusal) -> Self {
        guard WorkspaceStatusInputs.sampleRates.contains(clock.nominalHertz) else {
            throw .nominalRateOutOfRange(clock.nominalHertz)
        }
        let nominal = WorkspaceStatusFormat.kilohertz(clock.nominalHertz)
        guard let measured = clock.measuredHertz else {
            return Self(.clock, text: "\(nominal) nominal, actual Unavailable", severity: .attention)
        }
        guard WorkspaceStatusInputs.sampleRates.contains(measured) else {
            throw .measuredRateOutOfRange(measured)
        }
        let actual = WorkspaceStatusFormat.kilohertz(measured)
        return Self(.clock, text: "\(nominal) nominal, actual \(actual)", severity: .normal)
    }
}

// MARK: - Peers

extension WorkspaceStatusSegment {
    /// One peer as the strip says it.
    private struct PeerLine {
        let name: String
        let text: String
        let severity: WorkspaceStatusSeverity
        /// Whether the peer is lost: its connection is gone.
        let isLost: Bool

        var entry: WorkspaceStatusListEntry { WorkspaceStatusListEntry(text: text, isLost: isLost) }
    }

    /// The Peers segment. A Local Network permission that is confirmed off replaces the rows, because no
    /// peer can be reached; the names and counts are still validated first. The strip says "Peer control
    /// unavailable" and the label adds the cause. A list cut off by the row cap names the number of hidden
    /// disconnected peers (in the strip text too, which is the label's sentence), so a new error behind
    /// "and N more" is audible.
    static func peers(
        _ rows: [WorkspaceStatusPeer], localNetwork: PermissionStatus
    ) throws(WorkspaceStatusRefusal) -> Self {
        for (index, row) in rows.enumerated() {
            try WorkspaceStatusInputs.validate(name: row.name, field: .peerName(index: index))
            try WorkspaceStatusInputs.validate(
                count: row.discardedStaleCommands, field: .discardedCommands(peerIndex: index)
            )
        }
        if WorkspaceStatusInputs.blocksAccess(localNetwork) {
            return Self(
                .peers, text: "Peer control unavailable",
                detail: "Peer control unavailable, Local Network denied; local manual use unaffected",
                severity: .attention
            )
        }
        guard !rows.isEmpty else { return Self(.peers, text: "No peers", severity: .normal) }
        let lines = rows.map(peerLine)
        let text = WorkspaceStatusFormat.summary(
            lines.map(\.entry), limit: maximumPeerRows, lostWord: "disconnected"
        )
        return Self(
            .peers, text: text, severity: lines.map(\.severity).max() ?? .normal,
            lostItems: lines.filter(\.isLost).map(\.name)
        )
    }

    private static func peerLine(_ peer: WorkspaceStatusPeer) -> PeerLine {
        let phase = phaseLine(peer)
        guard peer.discardedStaleCommands > 0 else { return phase }
        let stale = WorkspaceStatusFormat.staleCommands(peer.discardedStaleCommands)
        return PeerLine(
            name: peer.name, text: "\(phase.text), \(peer.name): \(stale)",
            severity: max(phase.severity, .attention), isLost: phase.isLost
        )
    }

    private static func phaseLine(_ peer: WorkspaceStatusPeer) -> PeerLine {
        let name = peer.name
        switch peer.phase {
        case .connected(let session):
            return PeerLine(name: name, text: connected(name, session), severity: .attention, isLost: false)
        case .synced(let session, awaitingResume: let awaitingResume):
            guard !awaitingResume else {
                return PeerLine(name: name, text: "\(name) resyncing", severity: .attention, isLost: false)
            }
            return PeerLine(name: name, text: connected(name, session), severity: .normal, isLost: false)
        case .resyncing:
            return PeerLine(name: name, text: "\(name) resyncing", severity: .attention, isLost: false)
        case .disconnected:
            return PeerLine(name: name, text: "\(name) disconnected", severity: .error, isLost: true)
        }
    }

    /// "NAME connected (epoch E)", E being the connection epoch of the session.
    private static func connected(_ name: String, _ session: PeerSyncSession) -> String {
        "\(name) connected (epoch \(session.connectionEpoch.generation.value))"
    }
}

// MARK: - Draft and Safety

extension WorkspaceStatusSegment {
    /// The Draft segment: how many drafts await review.
    static func draft(count: Int) throws(WorkspaceStatusRefusal) -> Self {
        try WorkspaceStatusInputs.validate(count: count, field: .draftCount)
        guard count > 0 else { return Self(.draft, text: "None awaiting review", severity: .normal) }
        return Self(.draft, text: "\(count) awaiting review", severity: .attention)
    }

    /// The Safety segment. Safe Mute and PANIC are never summarised away: unreachable controls are an error
    /// and the label says so.
    static func safety(_ shell: WorkspaceStatusShell) -> Self {
        guard shell.safetyControlsReachable else {
            return Self(
                .safety, text: "Safe Mute and PANIC unreachable", detail: "Safe Mute and PANIC are unreachable",
                severity: .error, lostItems: ["Safety"]
            )
        }
        return Self(
            .safety, text: "Safe Mute and PANIC", detail: "Safe Mute and PANIC are available", severity: .normal
        )
    }
}
