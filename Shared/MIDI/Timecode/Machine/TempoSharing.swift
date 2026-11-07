/// Typed refusal when building a tempo-sharing update.
enum TempoSharingError: Error, Equatable, Hashable, Sendable {
    case tempoOutOfRange(Int)
}

/// Tempo (and optionally position) offered to an optional peer. Tempo is microseconds per quarter note in the
/// MIDI file tempo range 1...16_777_215 (24 bits); no floating point. Position is an untouched `SMPTETime`.
struct TempoSharingUpdate: Equatable, Hashable, Sendable {
    static let tempoRange = 1...16_777_215

    let microsecondsPerQuarter: Int
    let position: SMPTETime?

    private init(microsecondsPerQuarter: Int, position: SMPTETime?) {
        self.microsecondsPerQuarter = microsecondsPerQuarter
        self.position = position
    }

    static func make(microsecondsPerQuarter: Int, position: SMPTETime? = nil) throws(TempoSharingError) -> Self {
        guard tempoRange.contains(microsecondsPerQuarter) else { throw .tempoOutOfRange(microsecondsPerQuarter) }
        return Self(microsecondsPerQuarter: microsecondsPerQuarter, position: position)
    }
}

enum TempoSharingAvailability: Equatable, Hashable, Sendable {
    case unavailable
    case available
}

enum TempoSharingOutcome: Equatable, Hashable, Sendable {
    case unavailable
    case published
}

/// A neutral seam for publishing tempo/position to an optional peer; it names no vendor and no implementation
/// ships in this lane. Calls are synchronous and non-throwing, so a conforming type must answer immediately
/// without blocking the host. Nothing in the MMC authorization or grant path takes a `TempoSharing`.
protocol TempoSharing: Sendable {
    func availability() -> TempoSharingAvailability
    func publish(_ update: TempoSharingUpdate) -> TempoSharingOutcome
}

extension TempoSharing {
    /// Publishes only after `availability()` reports `.available`; otherwise returns `.unavailable` and never
    /// calls `publish`.
    func offer(_ update: TempoSharingUpdate) -> TempoSharingOutcome {
        guard availability() == .available else { return .unavailable }
        return publish(update)
    }
}

/// The default: absent integration. Stateless; every call is a defined no-op that returns `.unavailable`
/// immediately, never blocks, never throws and has no side effects.
struct NoTempoSharing: TempoSharing {
    func availability() -> TempoSharingAvailability { .unavailable }

    func publish(_ update: TempoSharingUpdate) -> TempoSharingOutcome { .unavailable }
}
