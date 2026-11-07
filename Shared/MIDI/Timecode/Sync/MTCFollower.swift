/// Everything a refused call must leave untouched, comparable in tests.
struct MTCFollowerSnapshot: Equatable, Sendable {
    var state: MTCFollowerState
    var counters: MTCFollowerCounters
    var rate: SMPTEFrameRate?
    var consecutivePositions: Int
    var anchor: MTCFollowerAnchor?
    var lastStamp: UInt64?
    var lastQuarterStamp: UInt64?
}

/// Follows MIDI time code on injected host stamps. Pure value: no clock, timer or thread; silence is a state
/// that `poll` and every later call report. A call that throws changes nothing.
struct MTCFollower: Sendable {
    let policy: MTCFollowerPolicy
    let timebase: HostTimebase
    private(set) var state = MTCFollowerState.absent
    private(set) var counters = MTCFollowerCounters()
    private(set) var rate: SMPTEFrameRate?
    private(set) var consecutivePositions = 0
    private(set) var anchor: MTCFollowerAnchor?
    private(set) var lastStamp: UInt64?
    private(set) var lastQuarterStamp: UInt64?
    private var assembler = MTCAssembler()

    var direction: MTCDirection? { anchor?.direction }

    var snapshot: MTCFollowerSnapshot {
        MTCFollowerSnapshot(state: state, counters: counters, rate: rate, consecutivePositions: consecutivePositions,
                            anchor: anchor, lastStamp: lastStamp, lastQuarterStamp: lastQuarterStamp)
    }

    private init(policy: MTCFollowerPolicy, timebase: HostTimebase) {
        self.policy = policy
        self.timebase = timebase
    }

    static func make(policy: MTCFollowerPolicy, timebase: HostTimebase) throws(MTCFollowerError) -> MTCFollower {
        try MTCRealRate.validate(timebase)
        return MTCFollower(policy: policy, timebase: timebase)
    }

    @discardableResult
    mutating func consume(
        _ frame: MTCQuarterFrame, at stamp: HostStamp
    ) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        var next = self
        try next.accept(stamp)
        var events = try next.silence(at: stamp.ticks)
        events += next.begin()
        next.lastQuarterStamp = stamp.ticks
        events += try next.handle(next.assembler.consume(frame), at: stamp.ticks)
        self = next
        return events
    }

    @discardableResult
    mutating func consume(
        fullFrame event: MIDI1Event, receiver: SysExDeviceID, at stamp: HostStamp
    ) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        var next = self
        try next.accept(stamp)
        let decoded: MTCFullFrame?
        do {
            decoded = try MTCFullFrame.decode(event, receiver: receiver)
        } catch {
            throw .malformedFullFrame(error)
        }
        guard let frame = decoded else { return [] }
        var events = try next.silence(at: stamp.ticks)
        next.assembler.reset()
        next.consecutivePositions = 0
        next.rate = frame.time.rate
        next.anchor = MTCFollowerAnchor(frameCount: frame.time.frameCount, stamp: stamp.ticks, rate: frame.time.rate,
                                        direction: nil)
        next.state = .located
        events.append(.located(frameCount: frame.time.frameCount))
        self = next
        return events
    }

    @discardableResult
    mutating func poll(at stamp: HostStamp) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        var next = self
        try next.accept(stamp)
        let events = try next.silence(at: stamp.ticks)
        self = next
        return events
    }

    private mutating func accept(_ stamp: HostStamp) throws(MTCFollowerError) {
        if let last = lastStamp, stamp.ticks < last { throw .hostTimeRegressed(last: last, received: stamp.ticks) }
        lastStamp = stamp.ticks
    }

    /// The first quarter frame after silence or before any position: reacquire or start acquiring.
    private mutating func begin() -> [MTCFollowerEvent] {
        switch state {
        case .freewheeling, .lost:
            state = .acquiring
            anchor = nil
            return [.reacquired]
        case .absent, .located:
            state = .acquiring
            return []
        case .acquiring, .locked:
            return []
        }
    }

    /// Dropout and loss events for the quiet time since the last quarter frame. Thresholds are rounded up to a tick.
    private mutating func silence(at ticks: UInt64) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        guard state == .acquiring || state == .locked || state == .freewheeling, let last = lastQuarterStamp else {
            return []
        }
        let real = MTCRealRate(rate ?? .fps24)
        let dropout = try real.ticks(forFrames: Int128(policy.dropoutFrames), timebase: timebase)
        let freewheel = ExactMath.ceilDiv(Int128(policy.freewheelNanoseconds) * Int128(timebase.denom),
                                          Int128(timebase.numer))
        let elapsed = Int128(ticks) - Int128(last)
        var events: [MTCFollowerEvent] = []
        if state == .locked, elapsed > dropout {
            state = .freewheeling
            counters.dropouts += 1
            events.append(.freewheelStarted)
        }
        let lossLimit = state == .acquiring ? dropout : dropout + freewheel
        if state == .acquiring || state == .freewheeling, elapsed > lossLimit {
            state = .lost
            counters.losses += 1
            events.append(.lost)
        }
        if !events.isEmpty {
            assembler.reset()
            consecutivePositions = 0
        }
        return events
    }

    private mutating func handle(_ output: MTCAssemblerOutput, at ticks: UInt64) throws(MTCFollowerError)
        -> [MTCFollowerEvent] {
        switch output {
        case .pending:
            return []
        case let .reset(diagnostic):
            counters.discards += 1
            consecutivePositions = 0
            if state == .locked { state = .acquiring }
            return [.pieceDiscarded(diagnostic)]
        case let .position(position):
            let next = MTCFollowerAnchor(frameCount: position.current.frameCount, stamp: ticks,
                                         rate: position.current.rate, direction: position.direction)
            return try advance(to: next)
        }
    }

    private mutating func advance(to next: MTCFollowerAnchor) throws(MTCFollowerError) -> [MTCFollowerEvent] {
        var events: [MTCFollowerEvent] = []
        var continuous = true
        if consecutivePositions >= 1, let previous = anchor, previous.direction != nil {
            events = try previous.deviations(to: next, toleranceFrames: policy.toleranceFrames, timebase: timebase)
            continuous = events.isEmpty
        }
        anchor = next
        rate = next.rate
        if continuous {
            consecutivePositions = min(consecutivePositions + 1, policy.lockPositions)
        } else {
            consecutivePositions = 1
            if state == .locked { state = .acquiring }
        }
        if consecutivePositions >= policy.lockPositions, state != .locked {
            state = .locked
            events.append(.locked(frameCount: next.frameCount))
        }
        return events
    }
}
