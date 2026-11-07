import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Quarter-frame stream builders and shared helpers for the MTC follower suites.
extension MTCFollowerTests {
    typealias Stamped = (frame: MTCQuarterFrame, ticks: UInt64)
    typealias Event = MTCFollowerEvent

    /// One tick is a third of a nanosecond: every rate's frame and quarter frame is a whole number of ticks.
    static let exactTimebase = HostTimebase(numer: 1, denom: 3)
    static let nanosecondTimebase = HostTimebase(numer: 1, denom: 1)
    static let appleTimebase = HostTimebase(numer: 125, denom: 3)
    static let boundaryFrames = [0, 1, 1799, 1800, 17981, 17982, 2_589_407]
    static let streamStart: UInt64 = 1_000_000_000

    /// Ticks per frame under `exactTimebase`.
    static func ticksPerFrame(_ rate: SMPTEFrameRate) -> UInt64 {
        switch rate {
        case .fps24: 125_000_000
        case .fps25: 120_000_000
        case .fps2997DropFrame: 100_100_000
        case .fps30: 100_000_000
        }
    }

    static func thrown<Value>(_ body: () throws -> Value) -> MTCFollowerError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? MTCFollowerError
        }
    }

    static func policy(lock: Int = 2, tolerance: Int = 1, dropout: Int = 2,
                       freewheel: Int64 = 1_000_000_000) throws(MTCFollowerError) -> MTCFollowerPolicy {
        try MTCFollowerPolicy.make(lockPositions: lock, toleranceFrames: tolerance, dropoutFrames: dropout,
                                   freewheelNanoseconds: freewheel)
    }

    static func follower(_ policy: MTCFollowerPolicy = .standard,
                         timebase: HostTimebase = exactTimebase) throws(MTCFollowerError) -> MTCFollower {
        try MTCFollower.make(policy: policy, timebase: timebase)
    }

    static func label(_ count: Int, _ rate: SMPTEFrameRate) throws -> SMPTETime {
        try SMPTETime(frameCount: count, rate: rate)
    }

    static func wrapped(_ count: Int, _ rate: SMPTEFrameRate) -> Int {
        ((count % rate.framesPerDay) + rate.framesPerDay) % rate.framesPerDay
    }

    /// The eight pieces of `encoded`, the first one sent at `start`, a quarter frame apart; reverse sends 7...0.
    static func sequence(encoded: Int, rate: SMPTEFrameRate, direction: MTCDirection = .forward,
                         start: UInt64 = streamStart, ticksPerFrame: UInt64? = nil) throws -> [Stamped] {
        let frameTicks = ticksPerFrame ?? Self.ticksPerFrame(rate)
        let pieces = MTCQuarterFrame.pieces(for: try label(wrapped(encoded, rate), rate))
        let ordered = direction == .forward ? pieces : Array(pieces.reversed())
        return ordered.enumerated().map { (frame: $0.element, ticks: start + UInt64($0.offset) * frameTicks / 4) }
    }

    /// `count` consecutive sequences: sequence k encodes `firstEncoded` +/- 2k and starts two frames after the last.
    static func stream(rate: SMPTEFrameRate, direction: MTCDirection = .forward, firstEncoded: Int = 1000,
                       count: Int, start: UInt64 = streamStart,
                       ticksPerFrame: UInt64? = nil) throws -> [[Stamped]] {
        let frameTicks = ticksPerFrame ?? Self.ticksPerFrame(rate)
        let step = direction == .forward ? 2 : -2
        return try (0..<count).map { index in
            try sequence(encoded: firstEncoded + step * index, rate: rate, direction: direction,
                         start: start + UInt64(index) * 2 * frameTicks, ticksPerFrame: frameTicks)
        }
    }

    @discardableResult
    static func feed(_ follower: inout MTCFollower, _ items: [Stamped]) throws -> [Event] {
        var events: [Event] = []
        for item in items {
            events += try follower.consume(item.frame, at: HostStamp(ticks: item.ticks))
        }
        return events
    }

    static func feed(_ follower: inout MTCFollower, _ sequences: [[Stamped]]) throws -> [Event] {
        try sequences.flatMap { try feed(&follower, $0) }
    }

    /// A follower fed `lock` forward positions; `last` is the stamp of the final piece, `current` the frame it reports.
    struct Locked {
        var follower: MTCFollower
        let last: UInt64
        let current: Int
        let events: [Event]
    }

    static func locked(rate: SMPTEFrameRate = .fps25, direction: MTCDirection = .forward, positions: Int = 2,
                       firstEncoded: Int = 1000, timebase: HostTimebase = exactTimebase,
                       ticksPerFrame: UInt64? = nil, policy: MTCFollowerPolicy? = nil) throws -> Locked {
        var subject = try follower(policy ?? .standard, timebase: timebase)
        let sequences = try stream(rate: rate, direction: direction, firstEncoded: firstEncoded, count: positions,
                                   ticksPerFrame: ticksPerFrame)
        let events = try feed(&subject, sequences)
        let offset = direction == .forward ? 2 : -2
        let encoded = firstEncoded + (direction == .forward ? 2 : -2) * (positions - 1)
        return Locked(follower: subject, last: sequences[positions - 1][7].ticks,
                      current: wrapped(encoded + offset, rate), events: events)
    }

    static func fullFrame(_ time: SMPTETime, device: UInt8 = 0x10) throws -> MIDI1Event {
        MTCFullFrame(deviceID: try SysExDeviceID(device), time: time).event
    }

    static var receiver: SysExDeviceID { get throws { try SysExDeviceID(0x10) } }

    static func stamp(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }
}
