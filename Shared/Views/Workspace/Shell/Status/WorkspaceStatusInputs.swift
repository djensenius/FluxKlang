//
//  WorkspaceStatusInputs.swift
//  FluxKlang
//
//  The plain values the workspace status strip is derived from (#99 W3). Every
//  field is a value the caller already owns: nothing here reads a clock, a
//  device or the OS. Names are caller text and are validated, never repaired.
//

/// The engine as one window observes it, and the name of its host.
struct WorkspaceStatusEngine: Hashable, Sendable {
    let lifecycle: EngineLifecycle
    /// The host's display name, for example "Host A".
    let hostName: String
}

/// One device row. The caller sorts the rows; the projection keeps their order.
struct WorkspaceStatusDevice: Hashable, Sendable {
    let name: String
    let presence: DevicePresence
}

/// One peer row. The caller sorts the rows; the projection keeps their order.
struct WorkspaceStatusPeer: Hashable, Sendable {
    let name: String
    /// The reconnect phase. The epoch shown is the connection epoch of the phase's session.
    let phase: PeerReconnectState.Phase
    /// Commands from an older epoch that the host discarded and has not yet reported.
    let discardedStaleCommands: Int
}

/// The clock in whole hertz. The nominal and the measured rate are shown separately.
struct WorkspaceStatusClock: Hashable, Sendable {
    /// The configured rate, in `WorkspaceStatusInputs.sampleRates`.
    let nominalHertz: Int
    /// The measured rate, in `WorkspaceStatusInputs.sampleRates`, or nil while no measurement is available.
    let measuredHertz: Int?
}

/// The OS permissions that change what the strip says.
struct WorkspaceStatusPermissions: Hashable, Sendable {
    let localNetwork: PermissionStatus
    let microphone: PermissionStatus
    let bluetoothMIDI: PermissionStatus
}

/// The diagnostics list's counts by severity. They are carried by the projection, not folded into a segment.
struct WorkspaceStatusDiagnosticCounts: Hashable, Sendable {
    let errors: Int
    let warnings: Int
    let infos: Int

    /// The count for `severity`. Exhaustive: a new severity fails to compile here.
    func count(of severity: DiagnosticSeverity) -> Int {
        switch severity {
        case .error: errors
        case .warning: warnings
        case .info: infos
        }
    }
}

/// What the shell says about the safety controls.
struct WorkspaceStatusShell: Hashable, Sendable {
    let safetyControlsReachable: Bool

    init(safetyControlsReachable: Bool) {
        self.safetyControlsReachable = safetyControlsReachable
    }

    /// The one place the shell's presentation is read for the strip. `WorkspaceShellPresentation` keeps its
    /// initialiser private to the shell, so the strip carries the one Boolean it needs rather than the value.
    init(presentation: WorkspaceShellPresentation) {
        safetyControlsReachable = presentation.safetyControlsReachable
    }
}

/// Everything `WorkspaceStatusProjection.make(_:)` reads.
struct WorkspaceStatusInputs: Hashable, Sendable {
    let engine: WorkspaceStatusEngine
    let devices: [WorkspaceStatusDevice]
    let clock: WorkspaceStatusClock
    let peers: [WorkspaceStatusPeer]
    /// How many drafts await review.
    let draftCount: Int
    let diagnostics: WorkspaceStatusDiagnosticCounts
    let permissions: WorkspaceStatusPermissions
    let shell: WorkspaceStatusShell
    /// The readiness of the setlist about to start, or nil when the caller has none.
    var showReadiness: WorkspaceStatusShowReadiness?
}

// MARK: - Bounds and validation

extension WorkspaceStatusInputs {
    /// The longest name accepted, in UTF-8 bytes. A longer name is refused, never truncated.
    static let maximumNameUTF8Bytes = 128
    /// The largest draft, stale-command or diagnostics count accepted. Three of them cannot overflow `Int`.
    static let maximumCount = 1_000_000
    /// The whole-hertz rates accepted for the nominal and the measured clock (the `MeasuredRateFields` bound).
    static let sampleRates = 1...768_000

    /// Refuses an empty name, then a name of more than `maximumNameUTF8Bytes` bytes. Never trims or truncates.
    static func validate(name: String, field: WorkspaceStatusField) throws(WorkspaceStatusRefusal) {
        guard !name.isEmpty else { throw .emptyName(field) }
        let bytes = name.utf8.count
        guard bytes <= maximumNameUTF8Bytes else { throw .nameTooLong(field, bytes: bytes) }
    }

    /// Refuses a count outside `0...maximumCount`.
    static func validate(count: Int, field: WorkspaceStatusField) throws(WorkspaceStatusRefusal) {
        guard (0...maximumCount).contains(count) else { throw .countOutOfRange(field, value: count) }
    }

    /// Whether the OS has confirmed that the capability is off. Only `denied` and `restricted` are confirmed;
    /// `possiblyDenied` can be an ordinary network fault, and the rest say nothing against use. Exhaustive.
    static func blocksAccess(_ status: PermissionStatus) -> Bool {
        switch status {
        case .denied, .restricted: true
        case .notDetermined, .possiblyDenied, .unreachable, .granted, .unknown, .unsupported: false
        }
    }
}
