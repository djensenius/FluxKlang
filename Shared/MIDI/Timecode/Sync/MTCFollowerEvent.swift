/// What one call changed, in the order the changes happened.
enum MTCFollowerEvent: Equatable, Hashable, Sendable {
    case locked(frameCount: Int)
    case reacquired
    case relocated(frameCount: Int)
    case directionChanged(from: MTCDirection, to: MTCDirection)
    case rateChanged(from: SMPTEFrameRate, to: SMPTEFrameRate)
    case located(frameCount: Int)
    case pieceDiscarded(MTCAssemblerDiagnostic)
    case freewheelStarted
    case lost
}

enum MTCFollowerState: Equatable, Hashable, Sendable {
    /// Nothing has been received.
    case absent
    /// Pieces are arriving but fewer than `lockPositions` continuous positions have been seen.
    case acquiring
    case locked
    /// Quarter frames stopped; the position is extrapolated.
    case freewheeling
    /// Silence outlasted the freewheel; no position is offered.
    case lost
    /// A full frame placed a stationary position.
    case located
}

struct MTCFollowerCounters: Equatable, Hashable, Sendable {
    /// Locked followers that started freewheeling.
    var dropouts = 0
    /// Followers that gave up after silence.
    var losses = 0
    /// Partial sequences the assembler discarded.
    var discards = 0
}

enum MTCFollowerError: Error, Equatable, Hashable, Sendable {
    case policyOutOfRange(field: MTCFollowerPolicy.Field, value: Int64)
    case invalidTimebase
    case overflow
    case hostTimeRegressed(last: UInt64, received: UInt64)
    case malformedFullFrame(TimecodeError)
    case noPosition
    case stationary
    case queryPrecedesAnchor(anchor: UInt64, received: UInt64)
    case behindDirectionOfTravel(frameCount: Int, anchor: Int)
    case frameCountOutOfRange(frameCount: Int, framesPerDay: Int)
}
