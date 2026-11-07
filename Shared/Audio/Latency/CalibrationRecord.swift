//
//  CalibrationRecord.swift
//  FluxKlang
//
//  Provenance and exact configuration binding for one latency measurement.
//

enum DeviceEpochTag {}
enum CalibrationEpochTag {}

/// A local counter for a device or calibration epoch; `Generation` is compared only for equality.
struct LatencyEpoch<Tag>: Hashable, Sendable {
    static var initial: Self { Self(.initial) }

    private(set) var generation: Generation

    init(_ generation: Generation) {
        self.generation = generation
    }

    /// Advances exactly once, preserving the old value if the JSON-safe maximum is reached.
    mutating func advance() throws(RevisionError) {
        let next = try generation.next()
        generation = next
    }
}

typealias DeviceGeneration = LatencyEpoch<DeviceEpochTag>
typealias CalibrationGeneration = LatencyEpoch<CalibrationEpochTag>

/// Both generation domains used by a configuration snapshot.
struct CalibrationGenerations: Hashable, Sendable {
    let device: DeviceGeneration
    let calibration: CalibrationGeneration
}

enum LatencyProducerTag: ContractIDTag {}
typealias LatencyProducerID = ContractID<LatencyProducerTag>

/// An immutable measurement, opaque producer ID, and the configuration under which it was obtained.
struct CalibrationRecord: Hashable, Sendable {
    let measurement: LatencyMeasurement
    let producer: LatencyProducerID
    let configuration: CalibrationConfiguration

    private init(measurement: LatencyMeasurement, producer: LatencyProducerID,
                 configuration: CalibrationConfiguration) {
        self.measurement = measurement
        self.producer = producer
        self.configuration = configuration
    }

    /// Validates an opaque producer identifier and creates a configuration-bound record.
    static func make(measurement: LatencyMeasurement, producer: String,
                     configuration: CalibrationConfiguration) throws(LatencyRefusal) -> Self {
        let id: LatencyProducerID
        do {
            id = try LatencyProducerID(producer)
        } catch {
            throw .invalidProducerID(bytes: producer.utf8.count)
        }
        return Self(measurement: measurement, producer: id, configuration: configuration)
    }

    /// Lists the recorded configuration fields that differ from the current snapshot.
    func staleReasons(against current: CalibrationConfiguration) -> [CalibrationStaleReason] {
        configuration.staleReasons(comparedTo: current)
    }

    /// Whether this record still describes the current configuration exactly.
    func isFresh(for current: CalibrationConfiguration) -> Bool {
        staleReasons(against: current).isEmpty
    }
}
