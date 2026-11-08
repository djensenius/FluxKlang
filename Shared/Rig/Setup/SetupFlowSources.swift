//
//  SetupFlowSources.swift
//  FluxKlang
//
//  Derives the facts of the startup interface setup flow from values the app already has: a permission status, the
//  device lifecycles, the rig choice, the mapping review and its decisions. It reads, prompts, routes, sounds,
//  stores and applies nothing, and it does not call the reducer.
//

/// How many devices are present and how many are lost or muted. Plain counts: `SetupFlowFacts.make` validates them.
struct SetupFlowDeviceCounts: Equatable, Sendable {
    let present: Int
    let lostMuted: Int
}

/// Pure mappers from the app's values to the five facts of `SetupFlowFacts`.
enum SetupFlowSources {
    /// `granted` is granted. `notDetermined` and `unknown` are not determined; the other five are denied.
    static func access(for status: PermissionStatus) -> SetupFlowAccess {
        switch status {
        case .granted: .granted
        case .notDetermined: .notDetermined
        case .unknown: .notDetermined
        case .denied: .denied
        case .possiblyDenied: .denied
        case .unreachable: .denied
        case .restricted: .denied
        case .unsupported: .denied
        }
    }

    /// `present` counts the present devices. `lostMuted` counts the lost, revalidating and muted devices: none of
    /// them is present. The counts are not capped here; `SetupFlowFacts.make` refuses a count above 1_024.
    static func deviceCounts(of lifecycles: [DeviceLifecycle]) -> SetupFlowDeviceCounts {
        var present = 0
        var lostMuted = 0
        for lifecycle in lifecycles {
            switch lifecycle {
            case .present: present += 1
            case .lostMuted: lostMuted += 1
            case .revalidating: lostMuted += 1
            case .muted: lostMuted += 1
            }
        }
        return SetupFlowDeviceCounts(present: present, lostMuted: lostMuted)
    }

    /// A selected rig is offered as one id and is not picked. Ambiguous rigs are offered in the order given, none
    /// resolved by name, recency or position. `.none` and an empty `.ambiguous` offer no rig. Duplicates are kept
    /// for `make` to refuse.
    static func offeredRigs(for choice: RigChoice) throws(SetupFlowSourceRefusal) -> [SetupFlowRigID] {
        switch choice {
        case .selected(let rig):
            return [try flowRig(rig)]
        case .ambiguous(let rigs):
            var offered: [SetupFlowRigID] = []
            for rig in rigs {
                offered.append(try flowRig(rig))
            }
            return offered
        case .none:
            return []
        }
    }

    /// The pending roles of `review` that `decisions` neither chooses, nor leaves unmapped, nor binds by a replace.
    /// A decision for a role that is not pending is not counted. Decisions are not validated here; `apply` does.
    static func undecidedRoles(review: RigMappingReview, decisions: RigMappingDecisions) -> Int {
        var decided = Set(decisions.roles.keys)
        decided.formUnion(decisions.routes.values.compactMap(\.replacementRole))
        let undecided = review.pendingChoices.filter { !decided.contains($0) }
        return undecided.count
    }

    /// The facts for `SetupFlowFacts.make`; a refusal of `make` is returned as `.facts` with its order unchanged.
    static func facts(
        permission: PermissionStatus,
        lifecycles: [DeviceLifecycle],
        choice: RigChoice,
        review: RigMappingReview,
        decisions: RigMappingDecisions
    ) throws(SetupFlowSourceRefusal) -> SetupFlowFacts {
        let access = access(for: permission)
        let counts = deviceCounts(of: lifecycles)
        let rigs = try offeredRigs(for: choice)
        let undecided = undecidedRoles(review: review, decisions: decisions)
        do throws(SetupFlowRefusal) {
            return try SetupFlowFacts.make(
                access: access, presentDevices: counts.present, lostMuted: counts.lostMuted,
                offeredRigs: rigs, undecidedRoles: undecided
            )
        } catch {
            throw .facts(error)
        }
    }

    private static func flowRig(_ rig: RigProfileID) throws(SetupFlowSourceRefusal) -> SetupFlowRigID {
        guard let converted = SetupFlowRigID(rawValue: rig.rawValue) else { throw .rigIDRejected(rig.rawValue) }
        return converted
    }
}
