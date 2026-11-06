//
//  PeerReconnectBackoff.swift
//  FluxKlang
//
//  Pure reconnect backoff math (#97); the caller owns timers and randomness.
//  Attempt 0 has a ceiling of `base`; each attempt multiplies it by `factor`
//  until it saturates at `cap`, so a huge attempt number never overflows. The
//  delay is "equal jitter": half the ceiling plus the caller's jitter unit in
//  [0, 1) times the other half, rounded down, so ceiling/2 <= delay < ceiling.
//  `PeerReconnectAttempts` counts consecutive failed attempts, saturating, and
//  is reset by a successful sync.
//

import Foundation

enum PeerReconnectBackoffError: Error, Hashable, Sendable {
    case negativeAttempt(Int)
    /// The jitter unit is NaN or outside [0, 1).
    case invalidJitterUnit
}

enum PeerReconnectBackoff {
    static let baseMilliseconds = 250
    static let factor = 2
    static let capMilliseconds = 30_000

    /// The ceiling for `attempt` in milliseconds: `min(cap, base * factor^attempt)`.
    static func ceilingMilliseconds(attempt: Int) throws(PeerReconnectBackoffError) -> Int {
        guard attempt >= 0 else { throw .negativeAttempt(attempt) }
        var ceiling = baseMilliseconds
        var step = 0
        while step < attempt, ceiling < capMilliseconds {
            ceiling = ceiling > capMilliseconds / factor ? capMilliseconds : ceiling * factor
            step += 1
        }
        return min(ceiling, capMilliseconds)
    }

    static func delay(attempt: Int, jitterUnit: Double) throws(PeerReconnectBackoffError) -> Duration {
        guard jitterUnit >= 0, jitterUnit < 1 else { throw .invalidJitterUnit }
        let ceiling = try ceilingMilliseconds(attempt: attempt)
        let half = ceiling / 2
        let spread = ceiling - half
        return .milliseconds(half + Int((Double(spread) * jitterUnit).rounded(.down)))
    }
}

/// Consecutive reconnect attempts since the last successful sync.
struct PeerReconnectAttempts: Hashable, Sendable {
    /// Beyond attempt 7 the ceiling is already capped, so saturating here changes no delay.
    static let saturation = 32

    private(set) var count: Int

    init() { count = 0 }

    /// The delay before the next attempt, then counts it. An invalid jitter changes nothing.
    mutating func next(jitter: Double) throws(PeerReconnectBackoffError) -> Duration {
        let delay = try PeerReconnectBackoff.delay(attempt: count, jitterUnit: jitter)
        count = min(count + 1, Self.saturation)
        return delay
    }

    mutating func reset() { count = 0 }
}
