//
//  RigWindow.swift
//  FluxKlang
//
//  Injected integer-second instants and half-open reservation windows.
//

/// A point in time as injected integer seconds on any monotone epoch the caller chooses.
/// The ledger never reads a clock.
struct RigInstant: Hashable, Sendable, Comparable {
    let seconds: Int

    /// Requires `0...RigReservationLimits.maximumInstantSeconds`.
    init(seconds: Int) throws(RigReservationRefusal) {
        guard (0...RigReservationLimits.maximumInstantSeconds).contains(seconds) else {
            throw .invalidInstant(seconds: seconds)
        }
        self.seconds = seconds
    }

    static func < (lhs: RigInstant, rhs: RigInstant) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

/// A half-open window `[start, end)` of 1...`maximumWindowSeconds` seconds. Adjacent windows do not overlap.
struct RigWindow: Hashable, Sendable {
    private(set) var start: RigInstant
    private(set) var end: RigInstant

    /// Refusals, in order: `end <= start` is `.windowEmpty`; a longer window (or an overflowing length) is
    /// `.windowTooLong` (carrying `Int.max` on overflow).
    init(start: RigInstant, end: RigInstant) throws(RigReservationRefusal) {
        guard start < end else {
            throw .windowEmpty(start: start.seconds, end: end.seconds)
        }
        let (length, overflow) = end.seconds.subtractingReportingOverflow(start.seconds)
        if overflow {
            throw .windowTooLong(seconds: Int.max)
        }
        guard length <= RigReservationLimits.maximumWindowSeconds else {
            throw .windowTooLong(seconds: length)
        }
        self.start = start
        self.end = end
    }

    /// `start <= instant < end`.
    func contains(_ instant: RigInstant) -> Bool {
        start <= instant && instant < end
    }

    /// `start < other.end && other.start < end`; symmetric, and false for adjacent windows.
    func overlaps(_ other: RigWindow) -> Bool {
        start < other.end && other.start < end
    }
}
