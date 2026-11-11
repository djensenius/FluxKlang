//
//  PerformBindingStatus.swift
//  FluxKlang
//
//  The fixed English words of one row of the perform "Bindings..." list (#102 PBL1): presence, pickup mode and state,
//  and controller feedback. Nothing calls them yet.
//

/// Whether a binding's controller is heard now. The raw value is the text the row shows. Decided by
/// `PerformBindingList.make`: the pickup book first, then the caller's availability report.
enum PerformBindingPresence: String, Hashable, Sendable, CaseIterable {
    /// The origin is in the caller's live set and the book does not hold the binding unavailable.
    case live = "Live"
    /// The book holds the binding unavailable (`ControlPickupBook.sourceLost`), or the origin is not in the caller's
    /// live set (`sourceAbsent`). It says only that the controller is not seen now; never unplugged, lost or muted.
    case stale = "Stale"
    /// The source id is not a canonical MIDI source id, so the live set judges it neither present nor absent
    /// (`notMIDISource`, `malformedSource`). The device is then unknown too.
    case unjudged = "Presence unknown"
}

/// The pickup state the row shows. A stale row always shows `unavailable`, whatever the book holds, so it never reads
/// engaged or waiting. This is deliberately conservative: the list is a display, and the dispatchers read the book,
/// not this list. When the report says `sourceAbsent` but the book still holds engaged or waiting, the row reads
/// unavailable while the book would still apply the controller's input.
enum PerformBindingPickupStatus: String, Hashable, Sendable, CaseIterable {
    /// The book holds `PickupState.engaged`.
    case engaged = "Engaged"
    /// The book holds `PickupState.waiting`: a catch binding waits until the control reaches the value.
    case waiting = "Waiting"
    /// The controller is not seen now, so the list shows no pickup state or feedback for it. Its input is refused
    /// only once the host calls `ControlPickupBook.sourceLost` for the source (as `ControlInputBank.inputLost` does),
    /// which makes the book hold `PickupState.unavailable`. This list refuses nothing itself.
    case unavailable = "Unavailable"

    /// The pickup mode words of a binding with no mode: a relative binding never waits.
    static let relativeModeText = "No pickup (relative)"
}

/// Controller feedback, in the exact words of perform.md "Bindings and controller feedback".
enum PerformBindingFeedback: String, Hashable, Sendable, CaseIterable {
    /// Live, the caller lists the device as accepting feedback, and the MIDI 1 feedback encoder can address this
    /// control on it under the device's dialect.
    case sends = "Sends feedback"
    /// Not stale, and either the caller does not list the device as accepting feedback (an unknown device never is)
    /// or the encoder cannot address this control: a relative profile, RPN or NRPN, a 14-bit pair under the
    /// seven-bit dialect, a width mismatch or an unreadable controller number.
    case unsupportedByDevice = "Unsupported by device"
    /// Stale: the list claims no feedback until the device is seen again, whatever the device supports. This list
    /// sends nothing; withholding feedback bytes from an unseen controller is the host's job.
    case controllerStale = "Unavailable: controller stale"
}

extension PickupMode {
    /// "Catch pickup" or "Jump pickup".
    var performText: String {
        switch self {
        case .catch: "Catch pickup"
        case .jump: "Jump pickup"
        }
    }
}
