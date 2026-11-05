//
//  MeterSource.swift
//  FluxKlang
//
//  What a meter is bound to (#102 M1). Only a measured tap publishes
//  readings; a fader's own travel is a control value and never signal
//  (perform.md: `par.mains.gain` telemetry is `faderTravelOnly`).
//

/// The value a meter tap publishes through `TelemetrySlots`: one channel's peak level in dBFS since its
/// previous publish. −∞ is digital silence; NaN and +∞ are invalid and never displayed (+∞ still latches clip);
/// finite values above `MeterBallistics.ceilingDBFS` are shown at the ceiling.
struct MeterTapValue: BitwiseCopyable, Sendable, Equatable {
    let peakDBFS: Double
}

/// Why a meter's source cannot be measured, in the vocabulary of perform.md and `session.json` `telemetry`.
enum MeterSourceGate: Equatable, Sendable, CaseIterable {
    /// The control has no signal route ("Signal: no route").
    case noRoute
    /// The route exists but no tap measures it on this host.
    case notMeasured
    /// The role is not mapped to a device route on this host.
    case unmapped
    /// The device behind the route is missing.
    case deviceMissing
    /// The route is Lost/Muted.
    case lostMuted
    /// The measured source was removed from the active graph.
    case sourceRemoved
    /// An OS permission needed to measure the source is not granted.
    case permissionDenied
    /// The hardware that would measure the source is unavailable.
    case hardwareUnavailable
}

/// What a meter is bound to. A tap's channel count is validated, so a source is built only through `tap(channels:)`,
/// `faderTravelOnly` or `gated(_:)`.
struct MeterSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Measured telemetry, one read per channel per update.
        case tap(channels: Int)
        /// The only activity is the strip's own fader travel, which is never signal; the meter is unavailable.
        case faderTravelOnly
        /// The source cannot be measured; the meter is unavailable with the gate as its reason.
        case gated(MeterSourceGate)
    }

    /// Largest tap channel count (inclusive), matching the 64-speaker spatial layout limit.
    static let maximumChannels = 64

    static let faderTravelOnly = MeterSource(kind: .faderTravelOnly)

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    static func tap(channels: Int) throws(MeterDisplayRefusal) -> MeterSource {
        guard channels >= 1, channels <= maximumChannels else { throw .channelCountOutOfRange(channels) }
        return MeterSource(kind: .tap(channels: channels))
    }

    static func gated(_ gate: MeterSourceGate) -> MeterSource {
        MeterSource(kind: .gated(gate))
    }

    /// Tap channels; 0 for a source that is not measured.
    var channelCount: Int {
        if case .tap(let channels) = kind { return channels }
        return 0
    }

    /// Why the whole meter is unavailable, or nil for a measured tap.
    var unavailableReason: MeterUnavailableReason? {
        switch kind {
        case .tap: nil
        case .faderTravelOnly: .faderTravelOnly
        case .gated(let gate): .gated(gate)
        }
    }
}
