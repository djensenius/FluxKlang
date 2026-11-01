import Foundation

struct MeterFields: ControlFields {
    static let knownKeys: Set<String> = ["numerator", "denominator"]
    let numerator: Int
    let denominator: Int

    func validate() throws {
        guard (1...64).contains(numerator), [1, 2, 4, 8, 16, 32].contains(denominator) else {
            throw ControlValidationError.invalid("Invalid musical meter")
        }
    }
}
typealias MusicalMeter = ControlRecord<MeterFields>

/// A host-local clock snapshot. No absolute host-tick stamps are serializable.
struct TransportFields: ControlPayloadFields {
    static let contract = "fluxklang.transport"
    static let knownKeys: Set<String> = [
        "host", "primaryClock", "sampleGeneration", "nominalRate", "musicalClock",
        "transportGeneration", "musicalMapRevision", "segments", "meter", "loop"
    ]
    let host: HostEpoch
    let primaryClock: ClockID
    let sampleGeneration: Generation
    let nominalRate: Int
    let musicalClock: ClockID?
    let transportGeneration: Generation?
    let musicalMapRevision: Generation?
    let segments: [TempoSegment]
    let meter: MusicalMeter?
    let loop: LoopRange?

    func validate() throws {
        guard MediaNominalRate.isValid(nominalRate) else { throw ClockMapError.invalidRate(nominalRate) }
        if let musicalClock {
            guard musicalClock != primaryClock, transportGeneration != nil,
                  let musicalMapRevision, meter != nil else {
                throw ControlValidationError.invalid("Musical clock requires separate identity, counters and meter")
            }
            _ = try MusicalMap(clock: musicalClock, revision: musicalMapRevision, segments: segments)
        } else {
            guard transportGeneration == nil, musicalMapRevision == nil, segments.isEmpty,
                  meter == nil, loop == nil else {
                throw ControlValidationError.invalid("Musical state requires a declared musical clock")
            }
        }
    }
}
typealias TransportDocument = ControlEnvelope<ControlRecord<TransportFields>>
