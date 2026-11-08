//
//  WorkspaceStatusProjection.swift
//  FluxKlang
//
//  The single status projection (#99 W3): every surface on a host reads this
//  one value, so Wiring, Perform and Spatial never disagree. It is a pure
//  function of `WorkspaceStatusInputs`: it reads, never writes, and issues no
//  command (status-diagnostics.md "Contract seams").
//

/// The diagnostics counts after validation. The list header and the detail list are a later lane; the
/// counts are carried here so that every surface reads the same numbers.
struct WorkspaceStatusDiagnosticSummary: Hashable, Sendable {
    let errors: Int
    let warnings: Int
    let infos: Int

    /// All diagnostics. Each count is at most `WorkspaceStatusInputs.maximumCount`, so the sum cannot overflow.
    var total: Int { errors + warnings + infos }

    private init(errors: Int, warnings: Int, infos: Int) {
        self.errors = errors
        self.warnings = warnings
        self.infos = infos
    }

    /// Refuses the first count outside `0...WorkspaceStatusInputs.maximumCount`, in severity order.
    static func make(_ counts: WorkspaceStatusDiagnosticCounts) throws(WorkspaceStatusRefusal) -> Self {
        for severity in DiagnosticSeverity.allCases {
            let count = counts.count(of: severity)
            try WorkspaceStatusInputs.validate(count: count, field: .diagnosticCount(severity))
        }
        return Self(errors: counts.errors, warnings: counts.warnings, infos: counts.infos)
    }
}

/// The status strip: exactly six segments in the fixed order Engine, Devices, Clock, Peers, Draft, Safety.
/// Only `make(_:)` builds one, so a projection is always validated and never forged.
struct WorkspaceStatusProjection: Hashable, Sendable {
    /// Always six, indexed by `WorkspaceStatusSegmentID.position`.
    let segments: [WorkspaceStatusSegment]
    let diagnostics: WorkspaceStatusDiagnosticSummary
    /// Whether Safe Mute and PANIC can be reached, as the shell reports it.
    let safetyControlsReachable: Bool
    /// The show readiness line, or nil when the inputs carry none. It is not a segment.
    let showReadiness: WorkspaceStatusShowReadinessLine?

    private init(
        segments: [WorkspaceStatusSegment], diagnostics: WorkspaceStatusDiagnosticSummary,
        safetyControlsReachable: Bool, showReadiness: WorkspaceStatusShowReadinessLine?
    ) {
        self.segments = segments
        self.diagnostics = diagnostics
        self.safetyControlsReachable = safetyControlsReachable
        self.showReadiness = showReadiness
    }

    /// The segment with this ID.
    func segment(_ id: WorkspaceStatusSegmentID) -> WorkspaceStatusSegment {
        segments[id.position]
    }

    /// Derives the projection. The first failure is reported, in this order: host name; device names by
    /// index; nominal rate; measured rate; for each peer by index its name then its stale-command count;
    /// draft count; diagnostics errors, warnings, infos; then, when present, the show readiness counts.
    /// Nothing is trimmed, truncated or clamped.
    static func make(_ inputs: WorkspaceStatusInputs) throws(WorkspaceStatusRefusal) -> Self {
        let engine = try WorkspaceStatusSegment.engine(inputs.engine)
        let devices = try WorkspaceStatusSegment.devices(inputs.devices, permissions: inputs.permissions)
        let clock = try WorkspaceStatusSegment.clock(inputs.clock)
        let peers = try WorkspaceStatusSegment.peers(inputs.peers, localNetwork: inputs.permissions.localNetwork)
        let draft = try WorkspaceStatusSegment.draft(count: inputs.draftCount)
        let safety = WorkspaceStatusSegment.safety(inputs.shell)
        let diagnostics = try WorkspaceStatusDiagnosticSummary.make(inputs.diagnostics)
        let showReadiness = try inputs.showReadiness.map { counts throws(WorkspaceStatusRefusal) in
            try WorkspaceStatusShowReadinessLine.make(counts)
        }
        return Self(
            segments: [engine, devices, clock, peers, draft, safety], diagnostics: diagnostics,
            safetyControlsReachable: inputs.shell.safetyControlsReachable, showReadiness: showReadiness
        )
    }
}
