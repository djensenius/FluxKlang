//
//  WorkspaceStatusFocusOrder.swift
//  FluxKlang
//
//  The keyboard focus order of the status strip (#99 W3), as pure values: the
//  five detail segments in strip order, then Safe Mute, then PANIC as the last
//  two stops, in every layout. Left/Right, Return/Space and Escape belong to
//  the view; this is only the order and what each stop says.
//

/// What a focus stop activates.
enum WorkspaceStatusFocusTarget: Hashable, Sendable {
    /// A segment that opens its detail list.
    case segment(WorkspaceStatusSegmentID)
    case safeMute
    case panic
}

/// One stop in the focus order.
struct WorkspaceStatusFocusStop: Hashable, Sendable {
    let target: WorkspaceStatusFocusTarget
    /// What VoiceOver reads for the stop.
    let label: String
    /// True when the shell reports the safety controls as unreachable. The stop stays, flagged, never dropped.
    let isUnreachable: Bool

    fileprivate init(_ target: WorkspaceStatusFocusTarget, label: String, isUnreachable: Bool) {
        self.target = target
        self.label = label
        self.isUnreachable = isUnreachable
    }
}

enum WorkspaceStatusFocusOrder {
    /// The seven stops: Engine, Devices, Clock, Peers, Draft, Safe Mute, PANIC. The order has no layout
    /// input, so it is the same in wide and compact (wrapped) layouts and when the safety controls are
    /// unreachable. Safe Mute and PANIC are always the last two stops.
    static func stops(for projection: WorkspaceStatusProjection) -> [WorkspaceStatusFocusStop] {
        var stops = projection.segments.filter(\.opensDetailList).map {
            WorkspaceStatusFocusStop(.segment($0.id), label: $0.label, isUnreachable: false)
        }
        let reachable = projection.safetyControlsReachable
        stops.append(safetyStop(.safeMute, name: "Safe Mute", isReachable: reachable))
        stops.append(safetyStop(.panic, name: "PANIC", isReachable: reachable))
        return stops
    }

    private static func safetyStop(
        _ target: WorkspaceStatusFocusTarget, name: String, isReachable: Bool
    ) -> WorkspaceStatusFocusStop {
        WorkspaceStatusFocusStop(
            target, label: isReachable ? name : "\(name) (unreachable)", isUnreachable: !isReachable
        )
    }
}
