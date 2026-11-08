//
//  SetupFlowFacts.swift
//  FluxKlang
//
//  The facts a startup interface setup flow is judged against. The caller derives plain integers and a list of
//  offered rig ids from the permission state, the device registry, the rig selection and the mapping review, and
//  passes them in. Nothing here asks for permission, reads a device, routes audio or makes a sound.
//

/// Phantom tag of the rig ids the flow handles.
enum SetupFlowRigTag: ContractIDTag {}

/// A rig the flow may offer. Its characters are ASCII only, so equality agrees with byte equality.
typealias SetupFlowRigID = ContractID<SetupFlowRigTag>

/// Whether the app may use the audio interface. Only `granted` passes the access gate.
enum SetupFlowAccess: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

/// Plain facts, built only through `make`. Present and lost devices are counted apart: a lost device is muted and is
/// not a present device.
struct SetupFlowFacts: Equatable, Sendable {
    static let maximumDevices = 1_024
    static let maximumRigs = 16
    static let maximumRoles = 4_096

    let access: SetupFlowAccess
    let presentDevices: Int
    let lostMuted: Int
    let offeredRigs: [SetupFlowRigID]
    let undecidedRoles: Int

    private init(
        access: SetupFlowAccess,
        presentDevices: Int,
        lostMuted: Int,
        offeredRigs: [SetupFlowRigID],
        undecidedRoles: Int
    ) {
        self.access = access
        self.presentDevices = presentDevices
        self.lostMuted = lostMuted
        self.offeredRigs = offeredRigs
        self.undecidedRoles = undecidedRoles
    }

    /// Refusal order: the rig count, `presentDevices`, `lostMuted`, `undecidedRoles`, then the first offered rig that
    /// equals an earlier one. The counts are checked before any set or loop is built from the list. There is no cap on
    /// present plus lost devices.
    static func make(
        access: SetupFlowAccess,
        presentDevices: Int,
        lostMuted: Int,
        offeredRigs: [SetupFlowRigID],
        undecidedRoles: Int
    ) throws(SetupFlowRefusal) -> Self {
        guard offeredRigs.count <= maximumRigs else { throw .tooManyRigs(offeredRigs.count) }
        guard (0...maximumDevices).contains(presentDevices) else {
            throw .factOutOfRange(.presentDevices, presentDevices)
        }
        guard (0...maximumDevices).contains(lostMuted) else { throw .factOutOfRange(.lostMuted, lostMuted) }
        guard (0...maximumRoles).contains(undecidedRoles) else {
            throw .factOutOfRange(.undecidedRoles, undecidedRoles)
        }
        var seen = Set<SetupFlowRigID>()
        for rig in offeredRigs {
            guard seen.insert(rig).inserted else { throw .duplicateRig(rig) }
        }
        return Self(
            access: access, presentDevices: presentDevices, lostMuted: lostMuted,
            offeredRigs: offeredRigs, undecidedRoles: undecidedRoles
        )
    }

    /// True when `other` has the same access, present devices, lost devices, offered rigs (as an ordered list) and
    /// undecided roles, checked in that order.
    func matches(_ other: Self) -> Bool {
        guard access == other.access else { return false }
        guard presentDevices == other.presentDevices else { return false }
        guard lostMuted == other.lostMuted else { return false }
        guard offeredRigs == other.offeredRigs else { return false }
        guard undecidedRoles == other.undecidedRoles else { return false }
        return true
    }
}
