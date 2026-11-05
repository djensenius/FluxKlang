//
//  MeterDisplay.swift
//  FluxKlang
//
//  Display vocabulary of the truthful meter model (#102 M1). Every
//  unavailable display carries a typed reason; measured silence (a level at
//  the floor) is a measurement and never "unavailable".
//

/// Why a reading cannot be displayed. Invalid readings never feed the level or peak hold.
enum MeterInvalidReading: Equatable, Sendable {
    /// NaN: changes nothing, not even the clip latch.
    case notANumber
    /// +∞: an overflow, so it latches the clip, but it has no level to show.
    case positiveInfinity

    /// Nil for a displayable reading: any finite value, or −∞ (digital silence, shown at the floor).
    init?(peakDBFS: Double) {
        if peakDBFS.isNaN {
            self = .notANumber
        } else if peakDBFS == .infinity {
            self = .positiveInfinity
        } else {
            return nil
        }
    }
}

/// Why a meter or channel shows "Unavailable". There is no reasonless blank or zero state.
enum MeterUnavailableReason: Equatable, Sendable {
    /// The source is the strip's own fader travel, which is never signal.
    case faderTravelOnly
    /// The source cannot be measured.
    case gated(MeterSourceGate)
    /// The telemetry slot has never been published (`TelemetryUnavailable.neverPublished`).
    case neverPublished
    /// The telemetry slot does not exist (`TelemetryUnavailable.invalidSlot`).
    case invalidSlot
    /// The sample is from another clock generation (`TelemetryUnavailable.staleGeneration`).
    case staleGeneration
    /// The sample is older than the kernel's frame-age rule (`TelemetryUnavailable.tooOld`).
    case tooOld
    /// The earliest classification of the sample that this channel has consumed is more than the injected staleness
    /// window before the update: the producer stalled, or a read was consumed late.
    case stale(ageNanoseconds: UInt64)
    /// The latest sample is NaN or +∞.
    case invalidReading(MeterInvalidReading)

    /// Maps each telemetry reason to its own display reason.
    init(_ telemetry: TelemetryUnavailable) {
        switch telemetry {
        case .neverPublished: self = .neverPublished
        case .invalidSlot: self = .invalidSlot
        case .staleGeneration: self = .staleGeneration
        case .tooOld: self = .tooOld
        }
    }
}

/// One channel's display signal.
enum MeterChannelSignal: Equatable, Sendable {
    /// A measured level and peak hold in dBFS, with `floorDBFS <= levelDBFS <= peakHoldDBFS <= ceilingDBFS`. A
    /// level at the floor is measured silence.
    case measured(levelDBFS: Double, peakHoldDBFS: Double)
    case unavailable(MeterUnavailableReason)
}

/// What a meter shows at one update.
enum MeterDisplay: Equatable, Sendable {
    /// The source is not a measured tap, so the whole meter is unavailable.
    case unavailable(MeterUnavailableReason)
    /// One display per tap channel, in channel order. Only `MeterDisplayModel` builds channel displays.
    case channels([MeterChannelDisplay])
}
