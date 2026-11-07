//
//  RigLockPort.swift
//  FluxKlang
//
//  The injected process-level lock behind the rig reservation ledger.
//

/// Which rig a lock is for and which reservation holds it.
struct RigLockRequest: Hashable, Sendable {
    let rig: RigToken
    let holder: RigToken
}

/// The answer to an acquire request.
enum RigLockAcquisition: Hashable, Sendable {
    case acquired
    case busy
    case unavailable
}

/// The answer to a release request.
enum RigLockReleaseOutcome: Hashable, Sendable {
    case released
    case notHeld
    case unavailable
}

/// The machine-wide rig lock, injected into the ledger.
///
/// This is a seam, not a lock: the ledger is a MODEL and does not itself exclude other processes. The real lock is
/// the coordinator-owned flock harness, whose adapter conforms to this protocol outside this slice. A GitHub issue
/// claim is NOT a lock. Implementations must return immediately; never wait. Production code ships no conforming type.
protocol RigLockPort: Sendable {
    /// Try to take the lock for `request.rig`; must return immediately.
    mutating func acquire(_ request: RigLockRequest) -> RigLockAcquisition
    /// Give the lock back; must return immediately.
    mutating func release(_ request: RigLockRequest) -> RigLockReleaseOutcome
}
