//
//  LibraryRigStatus.swift
//  FluxKlang
//
//  The status of one Library rig row (#99 LIB3): the matcher's operating mode, without its payload. It is taken from
//  `RigMatchReport.mode` and never recomputed from the counts. A status does not say that a rig is or can be
//  activated. Pure values: no view, no I/O. Nothing calls it yet.
//

/// What a rig row says about the rig against the devices the host currently observes.
enum LibraryRigStatus: Hashable, Sendable, CaseIterable {
    /// Every required device is matched or renumbered (also a rig with no required device).
    case full
    /// Some, not all, required devices are matched or renumbered.
    case partial
    /// No required device is matched or renumbered.
    case manualRemote

    init(mode: RigOperatingMode) {
        switch mode {
        case .full: self = .full
        case .partial: self = .partial
        case .manualRemote: self = .manualRemote
        }
    }
}
