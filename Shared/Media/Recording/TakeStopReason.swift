//
//  TakeStopReason.swift
//  FluxKlang
//
//  Why a recording take ended (media-contract.md §8.3), or why it was discarded.
//  Capture emits only the device reasons as `RuntimeCaptureStopReason`; a `user`
//  stop owns no `captureStopped` record; a `discontinuity` stop is set by the
//  ledger itself when a capture record leaves the take nowhere to continue, and
//  exports as the contract's `discontinuity` stop reason (#336).
//

/// A discontinuity that ended a take at its last good frame.
enum TakeDiscontinuityStop: String, Hashable, Sendable {
    /// A `sampleJump` to a frame before the take's start, in the take's start generation.
    case jumpBeforeTakeStart
}

enum TakeStopReason: Hashable, Sendable {
    case user, diskFull, deviceLost
    case discontinuity(TakeDiscontinuityStop)

    init(_ reason: RuntimeCaptureStopReason) {
        switch reason {
        case .diskFull: self = .diskFull
        case .deviceLost: self = .deviceLost
        }
    }

    /// The device's `captureStopped` reason this stop must own, or nil for `user` and ledger stops: capture
    /// never reports a ledger stop. The exported record's reason is `contractV1CaptureStoppedReason`.
    var captureReason: RuntimeCaptureStopReason? {
        switch self {
        case .user, .discontinuity: nil
        case .diskFull: .diskFull
        case .deviceLost: .deviceLost
        }
    }

    /// Set by the ledger itself; such a take owns no further record, and its stop never blocks a
    /// restart (its segments still do, §8.3).
    var isLedgerStop: Bool {
        if case .discontinuity = self { true } else { false }
    }

    /// The `captureStopped` reason the take document must own for this stop (§8.3), or nil for `user`, which
    /// owns none. A ledger stop is `discontinuity`, never a device reason. The sub-cause
    /// (`TakeDiscontinuityStop`) is not part of the contract and is dropped here.
    var contractV1CaptureStoppedReason: DiscontinuityV1Record.CaptureStoppedReason? {
        switch self {
        case .user: nil
        case .diskFull: .diskFull
        case .deviceLost: .deviceLost
        case .discontinuity: .discontinuity
        }
    }

    /// The take document's `stopReason` under contract v1 (§8.3): `user`, or the name of the
    /// `captureStopped` reason the take owns. Every stop has a value, so none is refused or remapped.
    func contractV1StopReason() -> String {
        contractV1CaptureStoppedReason?.contractV1Name ?? "user"
    }
}

/// Why an unfinished take was discarded instead of finished.
enum TakeDiscardReason: Hashable, Sendable {
    /// The take holds no captured frame; there is no audio to keep.
    case noCapturedFrames
    /// The operator or the session abandoned the take; its frames stay in the audit history.
    case abandoned
}
