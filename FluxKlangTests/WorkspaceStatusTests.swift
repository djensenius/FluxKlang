//
//  WorkspaceStatusTests.swift
//  FluxKlangTests
//
//  The workspace status strip (#99 W3): the six fixed segments, the quiet and spec words, the severity
//  vocabulary, and the fixtures that every WorkspaceStatusTests+*.swift file shares.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct WorkspaceStatusTests {
    /// The eight permission states in declaration order, so that one loop covers every effect.
    static let allPermissionStatuses: [PermissionStatus] = [
        .notDetermined, .denied, .possiblyDenied, .unreachable, .restricted, .granted, .unknown, .unsupported
    ]

    /// The states the OS confirms are off; the other six say nothing against use.
    static let confirmedOff: [PermissionStatus] = [.denied, .restricted]

    /// Every input of the projection, quiet unless a test changes a field.
    struct Scenario {
        var lifecycle = EngineLifecycle.running
        var hostName = "Host A"
        var devices: [WorkspaceStatusDevice] = []
        var clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: 48_000)
        var peers: [WorkspaceStatusPeer] = []
        var draftCount = 0
        var diagnostics = WorkspaceStatusDiagnosticCounts(errors: 0, warnings: 0, infos: 0)
        var permissions = WorkspaceStatusPermissions(
            localNetwork: .granted, microphone: .granted, bluetoothMIDI: .granted
        )
        var shell = WorkspaceStatusShell(safetyControlsReachable: true)

        var inputs: WorkspaceStatusInputs {
            WorkspaceStatusInputs(
                engine: WorkspaceStatusEngine(lifecycle: lifecycle, hostName: hostName), devices: devices,
                clock: clock, peers: peers, draftCount: draftCount, diagnostics: diagnostics,
                permissions: permissions, shell: shell
            )
        }

        func projection() throws(WorkspaceStatusRefusal) -> WorkspaceStatusProjection {
            try WorkspaceStatusProjection.make(inputs)
        }
    }

    /// The projection of a quiet scenario after `edit`.
    static func projection(_ edit: (inout Scenario) -> Void = { _ in }) throws -> WorkspaceStatusProjection {
        var scenario = Scenario()
        edit(&scenario)
        return try scenario.projection()
    }

    /// One segment of the projection of a quiet scenario after `edit`.
    static func segment(
        _ id: WorkspaceStatusSegmentID, _ edit: (inout Scenario) -> Void
    ) throws -> WorkspaceStatusSegment {
        try projection(edit).segment(id)
    }

    /// Projecting `scenario` must be refused with exactly `expected`.
    static func expectRefusal(
        _ expected: WorkspaceStatusRefusal, _ scenario: Scenario, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: expected, sourceLocation: sourceLocation) { try scenario.projection() }
    }

    /// The exact words, severity and lost items of one segment.
    static func expectSegment(
        _ segment: WorkspaceStatusSegment, text: String, label: String, severity: WorkspaceStatusSeverity,
        lostItems: [String] = [], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(segment.text == text, sourceLocation: sourceLocation)
        #expect(segment.label == label, sourceLocation: sourceLocation)
        #expect(segment.severity == severity, sourceLocation: sourceLocation)
        #expect(segment.lostItems == lostItems, sourceLocation: sourceLocation)
    }

    /// A peer session whose connection epoch is `epoch`: the number a peer's text shows.
    static func session(epoch: Int, hostEpoch hostGeneration: Int = 1) throws -> PeerSyncSession {
        let host = HostID(validated: "host.a")
        let hostEpoch = HostEpoch(host: host, generation: try Generation(hostGeneration))
        let connectionEpoch = ConnectionEpoch(
            connection: ConnectionID(validated: "conn.c"), host: host, generation: try Generation(epoch)
        )
        return try #require(PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: connectionEpoch))
    }

    static func device(_ name: String, _ presence: DevicePresence) -> WorkspaceStatusDevice {
        WorkspaceStatusDevice(name: name, presence: presence)
    }

    static func permissions(
        localNetwork: PermissionStatus = .granted, microphone: PermissionStatus = .granted,
        bluetoothMIDI: PermissionStatus = .granted
    ) -> WorkspaceStatusPermissions {
        WorkspaceStatusPermissions(localNetwork: localNetwork, microphone: microphone, bluetoothMIDI: bluetoothMIDI)
    }

    static func peer(_ name: String, _ phase: PeerReconnectState.Phase, stale: Int = 0) -> WorkspaceStatusPeer {
        WorkspaceStatusPeer(name: name, phase: phase, discardedStaleCommands: stale)
    }

    /// `prefix1`, `prefix2`, ... `prefixN`.
    static func names(_ prefix: String, _ count: Int) -> [String] {
        (0..<count).map { "\(prefix)\($0 + 1)" }
    }

    /// The presentation the navigation state reports for one window: the only way to obtain one.
    static func presentation(compact: Bool) throws -> WorkspaceShellPresentation {
        let window = WindowID(validated: "win.status")
        var state = WorkspaceNavigationState()
        try state.apply(.openWindow(window, project: ProjectID(validated: "prj.status")))
        if compact { try state.apply(.setWidthClass(.compact, window: window)) }
        return try state.presentation(for: window)
    }
}

// MARK: - Order, vocabulary and words

extension WorkspaceStatusTests {
    @Test func segmentsAreSixInTheFixedOrderWithStableIDs() throws {
        let projection = try Self.projection()
        let expected: [WorkspaceStatusSegmentID] = [.engine, .devices, .clock, .peers, .draft, .safety]
        #expect(projection.segments.map(\.id) == expected)
        #expect(WorkspaceStatusSegmentID.allCases == expected)
        #expect(expected.map(\.rawValue) == ["engine", "devices", "clock", "peers", "draft", "safety"])
        #expect(expected.map(\.position) == [0, 1, 2, 3, 4, 5])
        for id in expected { #expect(projection.segment(id).id == id) }
    }

    @Test func segmentTitlesAndDetailListFlagsAreFixed() throws {
        let projection = try Self.projection()
        #expect(projection.segments.map(\.title) == ["Engine", "Devices", "Clock", "Peers", "Draft", "Safety"])
        #expect(projection.segments.map(\.opensDetailList) == [true, true, true, true, true, false])
        #expect(projection.segments.map(\.glyphName) == Array(repeating: "checkmark.circle", count: 6))
        for segment in projection.segments { #expect(segment.label.hasPrefix("\(segment.title): ")) }
    }

    @Test func severityIsOrderedAndAlwaysCarriesAGlyphAndAWord() {
        let all = WorkspaceStatusSeverity.allCases
        #expect(all == [.normal, .attention, .error])
        #expect(all.map(\.rank) == [0, 1, 2])
        #expect(WorkspaceStatusSeverity.normal < .attention)
        #expect(WorkspaceStatusSeverity.attention < .error)
        #expect(WorkspaceStatusSeverity.normal < .error)
        #expect(!(WorkspaceStatusSeverity.error < .attention))
        #expect(!(WorkspaceStatusSeverity.attention < .attention))
        #expect(all.map(\.glyphName) == ["checkmark.circle", "exclamationmark.triangle", "exclamationmark.octagon"])
        #expect(all.map(\.word) == ["Normal", "Attention", "Error"])
        #expect(all.max() == .error)
    }

    @Test func quietBaselineSaysEverySegmentInExactWords() throws {
        let projection = try Self.projection()
        Self.expectSegment(
            projection.segment(.engine), text: "Running (Host A)", label: "Engine: Running (Host A)",
            severity: .normal
        )
        Self.expectSegment(
            projection.segment(.devices), text: "No devices", label: "Devices: No devices", severity: .normal
        )
        Self.expectSegment(
            projection.segment(.clock), text: "48 kHz nominal, actual 48 kHz",
            label: "Clock: 48 kHz nominal, actual 48 kHz", severity: .normal
        )
        Self.expectSegment(
            projection.segment(.peers), text: "No peers", label: "Peers: No peers", severity: .normal
        )
        Self.expectSegment(
            projection.segment(.draft), text: "None awaiting review", label: "Draft: None awaiting review",
            severity: .normal
        )
        Self.expectSegment(
            projection.segment(.safety), text: "Safe Mute and PANIC",
            label: "Safety: Safe Mute and PANIC are available", severity: .normal
        )
        #expect(projection.diagnostics.total == 0)
        #expect(projection.safetyControlsReachable)
    }

    @Test func specStripExampleProjectsTheDocumentedWords() throws {
        let remote = try Self.session(epoch: 4)
        let projection = try Self.projection {
            $0.devices = [Self.device("Interface B", .missing), Self.device("Controller A", .stale)]
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
            $0.peers = [Self.peer("Remote C", .synced(remote, awaitingResume: false))]
            $0.draftCount = 1
        }
        Self.expectSegment(
            projection.segment(.engine), text: "Running (Host A)", label: "Engine: Running (Host A)",
            severity: .normal
        )
        Self.expectSegment(
            projection.segment(.devices), text: "1 missing, 1 stale",
            label: "Devices: Interface B missing, Controller A stale", severity: .error,
            lostItems: ["Interface B"]
        )
        Self.expectSegment(
            projection.segment(.clock), text: "48 kHz nominal, actual Unavailable",
            label: "Clock: 48 kHz nominal, actual Unavailable", severity: .attention
        )
        Self.expectSegment(
            projection.segment(.peers), text: "Remote C connected (epoch 4)",
            label: "Peers: Remote C connected (epoch 4)", severity: .normal
        )
        Self.expectSegment(
            projection.segment(.draft), text: "1 awaiting review", label: "Draft: 1 awaiting review",
            severity: .attention
        )
        Self.expectSegment(
            projection.segment(.safety), text: "Safe Mute and PANIC",
            label: "Safety: Safe Mute and PANIC are available", severity: .normal
        )
    }

    @Test func namedBoundsAreThePinnedConstants() {
        #expect(WorkspaceStatusSegment.maximumDeviceRows == 4)
        #expect(WorkspaceStatusSegment.maximumPeerRows == 3)
        #expect(WorkspaceStatusInputs.maximumNameUTF8Bytes == 128)
        #expect(WorkspaceStatusInputs.maximumCount == 1_000_000)
        #expect(WorkspaceStatusInputs.sampleRates == (1...768_000))
        #expect(WorkspaceStatusAnnouncer.throttleTicks == 4)
    }

    @Test func safetyIsAvailableWhenReachableAndAnErrorWhenNot() throws {
        let reachable = try Self.segment(.safety) { $0.shell = WorkspaceStatusShell(safetyControlsReachable: true) }
        Self.expectSegment(
            reachable, text: "Safe Mute and PANIC", label: "Safety: Safe Mute and PANIC are available",
            severity: .normal
        )
        let unreachable = try Self.segment(.safety) {
            $0.shell = WorkspaceStatusShell(safetyControlsReachable: false)
        }
        Self.expectSegment(
            unreachable, text: "Safe Mute and PANIC unreachable",
            label: "Safety: Safe Mute and PANIC are unreachable", severity: .error, lostItems: ["Safety"]
        )
        #expect(unreachable.severity != .normal)
        #expect(unreachable.glyphName == "exclamationmark.octagon")
        #expect(!unreachable.opensDetailList)
    }

    @Test func shellMirrorsTheNavigationPresentationInWideAndCompactWindows() throws {
        let wide = try Self.presentation(compact: false)
        let compact = try Self.presentation(compact: true)
        #expect(wide.layout != compact.layout)
        let expected = WorkspaceStatusShell(safetyControlsReachable: true)
        #expect(WorkspaceStatusShell(presentation: wide) == expected)
        #expect(WorkspaceStatusShell(presentation: compact) == expected)
        #expect(WorkspaceStatusShell(presentation: compact).safetyControlsReachable)
        #expect(WorkspaceStatusShell(safetyControlsReachable: false) != expected)
    }

    @Test func equalInputsProjectEquallyAndDifferentInputsDiffer() throws {
        let first = try Self.projection { $0.draftCount = 2 }
        let second = try Self.projection { $0.draftCount = 2 }
        let other = try Self.projection { $0.draftCount = 3 }
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        #expect(first != other)
        #expect(first.segments == second.segments)
        #expect(first.segment(.draft).text == "2 awaiting review")
        #expect(other.segment(.draft).text == "3 awaiting review")
    }

    @Test func draftSegmentCountsAwaitingReviewAtAttention() throws {
        let none = try Self.segment(.draft) { $0.draftCount = 0 }
        Self.expectSegment(
            none, text: "None awaiting review", label: "Draft: None awaiting review", severity: .normal
        )
        let one = try Self.segment(.draft) { $0.draftCount = 1 }
        Self.expectSegment(one, text: "1 awaiting review", label: "Draft: 1 awaiting review", severity: .attention)
        let many = try Self.segment(.draft) { $0.draftCount = 1_000_000 }
        Self.expectSegment(
            many, text: "1000000 awaiting review", label: "Draft: 1000000 awaiting review", severity: .attention
        )
    }
}

// MARK: - Lists that hide lost items behind "and N more"

extension WorkspaceStatusTests {
    /// A list whose label shows its first rows and only counts the rest ("and N more"): the places where lost
    /// items can trade places, or one of them be replaced by another, without one word of the label changing.
    enum CappedList: CaseIterable, Sendable {
        case devices
        case peers
        case degradedEngine
        case preparingEngine

        /// The segment that shows the list.
        var id: WorkspaceStatusSegmentID {
            switch self {
            case .devices: .devices
            case .peers: .peers
            case .degradedEngine, .preparingEngine: .engine
            }
        }

        /// As many distinct names as the label lists before "and N more".
        var visible: [String] {
            switch self {
            case .devices: WorkspaceStatusTests.names("D", 4)
            case .peers: WorkspaceStatusTests.names("P", 3)
            case .degradedEngine, .preparingEngine: WorkspaceStatusTests.names("cap.", 4)
            }
        }

        /// The projection in which exactly these names are lost, in this order: missing devices, disconnected
        /// peers, lost capabilities of a degraded engine, or of an engine that prepares revision 43 over it.
        func projection(_ names: [String]) throws -> WorkspaceStatusProjection {
            switch self {
            case .devices, .peers:
                return try WorkspaceStatusTests.lostProjection(names, in: id)
            case .degradedEngine:
                let lost = try names.map { try CapabilityID($0) }
                return try WorkspaceStatusTests.projection { $0.lifecycle = .degraded(lost) }
            case .preparingEngine:
                let lost = try names.map { try CapabilityID($0) }
                let revision = try ContractRevision(43)
                return try WorkspaceStatusTests.projection {
                    $0.lifecycle = .preparing(revision, over: .degraded(lost))
                }
            }
        }

        /// The exact label when `shown` are the names it lists and `hidden` more lost items sit behind
        /// "and N more": the number of items left out, and for devices and peers the number of them that are lost.
        func label(_ shown: [String], hidden: Int) -> String {
            let more = ", and \(hidden) more"
            let joined = shown.joined(separator: ", ")
            switch self {
            case .devices: return "Devices: " + rows(shown, "missing") + more + ", \(hidden) missing"
            case .peers: return "Peers: " + rows(shown, "disconnected") + more + ", \(hidden) disconnected"
            case .degradedEngine: return "Engine: Running: \(joined)\(more) Lost/Muted"
            case .preparingEngine: return "Engine: Preparing rev 43... Running: \(joined)\(more) Lost/Muted"
            }
        }

        /// "D1 missing, D2 missing": each name with the word of its state.
        private func rows(_ names: [String], _ word: String) -> String {
            names.map { "\($0) \(word)" }.joined(separator: ", ")
        }
    }
}
