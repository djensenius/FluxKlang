//
//  TakeStopReason.swift
//  FluxKlang
//
//  Why a recording take ended (media-contract.md §8.3), or why it was discarded.
//  Capture emits only the device reasons as `RuntimeCaptureStopReason`; a `user`
//  stop owns no `captureStopped` record; a `discontinuity` stop is set by the
//  ledger itself when a capture record leaves the take nowhere to continue; it stays
//  in memory only until contract v1 gains a value for it (#336).
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

    /// The `captureStopped` reason this stop must own, or nil for `user` and ledger stops.
    var captureReason: RuntimeCaptureStopReason? {
        switch self {
        case .user, .discontinuity: nil
        case .diskFull: .diskFull
        case .deviceLost: .deviceLost
        }
    }

    /// Set by the ledger itself; such a take owns no further record and never blocks a restart.
    var isLedgerStop: Bool {
        if case .discontinuity = self { true } else { false }
    }

    /// The take document's `stopReason` under contract v1 (frozen: `user`, `diskFull`, `deviceLost`).
    /// A ledger stop has no v1 value and is refused, never mapped onto another reason; #336 tracks
    /// the contract revision that will add one.
    func contractV1StopReason() throws(TakeLedgerError) -> String {
        switch self {
        case .user: "user"
        case .diskFull: "diskFull"
        case .deviceLost: "deviceLost"
        case .discontinuity: throw .stopReasonNotInContractV1(self)
        }
    }
}

/// Why an unfinished take was discarded instead of finished.
enum TakeDiscardReason: Hashable, Sendable {
    /// The take holds no captured frame; there is no audio to keep.
    case noCapturedFrames
    /// The operator or the session abandoned the take; its frames stay in the audit history.
    case abandoned
}
