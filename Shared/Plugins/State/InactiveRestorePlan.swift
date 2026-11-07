//
//  InactiveRestorePlan.swift
//  FluxKlang
//
//  The ordered steps that restore an opaque state snapshot into an instance that is
//  NOT rendering (#77, slice PLG4). The plan is a value: it lists steps and executes
//  nothing, so state I/O can never be planned on the render path. A plan exists only
//  for a snapshot the qualification accepted and an instance that is not active.
//

/// What the instance that would receive the state is doing now.
enum InstanceActivity: String, Hashable, Sendable, CaseIterable {
    case unprepared
    case prepared
    case active
    case rendering

    var isRunning: Bool { self == .active || self == .rendering }
}

/// One step of an inactive restore, always in the order the plan lists them.
enum RestoreStep: String, Hashable, Sendable, CaseIterable {
    case prepareInstance
    case loadState
    case verifyDigest
    case activateInstance
}

enum InactiveRestoreError: Error, Hashable, Sendable {
    /// The instance is active or rendering. Checked before qualification.
    case instanceActive(InstanceActivity)
    /// The qualification refused the snapshot; the refusals are in their fixed order.
    case notQualified([StateRefusal])
}

/// Steps to restore `snapshot` while the instance is idle. `steps` is
/// `[prepareInstance,] loadState, verifyDigest, activateInstance`: the first step
/// is omitted when the instance is already prepared, and activation is always last,
/// so the state is loaded and verified before the instance can render.
struct InactiveRestorePlan: Hashable, Sendable {
    let snapshot: PluginStateSnapshot
    let purpose: StatePurpose
    let steps: [RestoreStep]
    /// The digest `verifyDigest` must find after loading (the snapshot's own).
    let expectedDigest: StateDigest

    private init(snapshot: PluginStateSnapshot, purpose: StatePurpose, steps: [RestoreStep]) {
        self.snapshot = snapshot
        self.purpose = purpose
        self.steps = steps
        expectedDigest = snapshot.digest
    }

    /// Qualifies the snapshot itself (it accepts no caller-built qualification) and
    /// refuses an active or rendering instance first.
    static func plan(
        snapshot: PluginStateSnapshot?, target: PluginStateTarget, purpose: StatePurpose,
        evidence: QualifiedVersionEvidence, instance: InstanceActivity
    ) throws(InactiveRestoreError) -> InactiveRestorePlan {
        guard !instance.isRunning else { throw .instanceActive(instance) }
        let qualification = StateQualification.evaluate(
            snapshot: snapshot, target: target, purpose: purpose, evidence: evidence
        )
        guard qualification.isQualified, let snapshot else { throw .notQualified(qualification.refusals) }
        let load: [RestoreStep] = [.loadState, .verifyDigest, .activateInstance]
        return InactiveRestorePlan(
            snapshot: snapshot, purpose: purpose, steps: instance == .unprepared ? [.prepareInstance] + load : load
        )
    }
}
