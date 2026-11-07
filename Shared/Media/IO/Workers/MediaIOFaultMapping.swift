//
//  MediaIOFaultMapping.swift
//  FluxKlang
//
//  The sole mapping of worker faults and pump outcomes onto the existing
//  runtime vocabulary (#109 IO2, media-contract.md §8.2, §8.3). Pure static
//  functions; every switch is exhaustive with no `default`, so a new fault or
//  outcome case fails to compile until it is mapped.
//

/// Why a discontinuity could not be built.
enum MediaIOMappingRefusal: Error, Equatable, Sendable {
    /// The frame count must lie in `0...Int64(UInt32.max)`.
    case framesOutOfRange(frames: Int64)
}

/// Maps worker faults and fill-pump outcomes to `RuntimeDiscontinuityKind`. Never instantiated.
enum MediaIOFaultMapping {
    /// A writer that cannot keep up pads with silence and reports `overflow` (§8.3). The recorder decides when;
    /// the pump does not.
    static let writerBackpressureKind: RuntimeDiscontinuityKind = .overflow

    /// A TERMINAL reader fault. Transient faults reach this mapping only after the pump's retry budget is spent.
    static func discontinuityKind(for fault: MediaReadFault) -> RuntimeDiscontinuityKind {
        switch fault {
        case .unavailable, .ioFailure, .interrupted: .sourceLost
        }
    }

    /// Contract v1 has two stop reasons. `diskFull` maps to itself; every other writer fault is approximated as
    /// `deviceLost` ("the destination went away or failed"), a documented approximation until the contract gains
    /// a file-failure reason (#336-style revision).
    static func captureStopReason(for fault: MediaWriteFault) -> RuntimeCaptureStopReason {
        switch fault {
        case .diskFull: .diskFull
        case .unavailable, .ioFailure, .interrupted: .deviceLost
        }
    }

    static func discontinuityKind(for fault: MediaWriteFault) -> RuntimeDiscontinuityKind {
        .captureStopped(reason: captureStopReason(for: fault))
    }

    /// Only a latched source loss and the first delivery after `resume` are discontinuities. Retries, stale
    /// discards, slow reads and early ends are counted by the pump, not reported.
    static func discontinuityKind(for outcome: PrefetchFillOutcome) -> RuntimeDiscontinuityKind? {
        switch outcome {
        case .sourceLost: .sourceLost
        case .delivered(let delivery): delivery.restoredSource ? .sourceRestored : nil
        case .endedWithoutData, .stillPending, .retryScheduled, .discardedStale: nil
        }
    }

    /// Builds the record: `frames` must lie in `0...4_294_967_295` (no clamping); `host` is always nil.
    static func discontinuity(_ kind: RuntimeDiscontinuityKind, at sample: RuntimeSampleStamp, stream: UInt32,
                              frames: Int64) throws(MediaIOMappingRefusal) -> RuntimeDiscontinuity {
        guard let count = UInt32(exactly: frames) else {
            throw .framesOutOfRange(frames: frames)
        }
        return RuntimeDiscontinuity(kind: kind, sample: sample, frames: count, stream: stream, host: nil)
    }
}
