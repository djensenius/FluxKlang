/// What to emit: a start time, a direction, where the first quarter frame goes on the host clock and how many
/// frames to cover. A plain carrier; `MTCEmitPlan.make` checks it.
struct MTCEmitRequest: Equatable, Sendable {
    /// The frame being sent when piece 0 (forward) or piece 7 (reverse) of the first sequence goes out.
    let start: SMPTETime
    let direction: MTCDirection
    /// Host tick of the first quarter frame.
    let originTicks: UInt64
    /// Frames covered; the plan accepts even counts from 2 through 256.
    let frameCount: Int
    /// Nanoseconds per host tick is `numer / denom`.
    let timebase: HostTimebase
    /// When non-nil the plan leads with a full frame for this device; nil means no full frame.
    let fullFrameDevice: SysExDeviceID?
}

/// One quarter frame at one host tick.
struct MTCEmitEntry: Equatable, Sendable {
    let tick: UInt64
    let piece: MTCQuarterFrame
}

/// The leading full frame of a plan.
struct MTCEmitFullFrameEntry: Equatable, Sendable {
    let tick: UInt64
    let frame: MTCFullFrame
}

/// A schedule of quarter frames as data. Building one sends nothing and authorizes nothing.
///
/// Quarter frame `q` (0..<4 * frameCount) belongs to sequence `q / 8` at slot `q % 8`. A forward sequence `m`
/// encodes `start` advanced by `2 * m` frames and sends pieces 0...7; a reverse sequence encodes `start` moved back
/// by `2 * m` frames and sends pieces 7...0. Host ticks ascend with `q` in both directions. The first sequence
/// encodes `start` itself: a receiver completing it reports the frame two frames after `start` going forward and
/// two frames before `start` going in reverse.
struct MTCEmitPlan: Equatable, Sendable {
    static let maximumFrames = 256
    static let minimumFrames = 2
    static let entriesPerFrame = 4

    private let storedEntries: [MTCEmitEntry]
    private let storedFullFrame: MTCEmitFullFrameEntry?
    private let storedRequest: MTCEmitRequest

    /// The quarter frames in ascending `q` order; `4 * request.frameCount` of them.
    var entries: [MTCEmitEntry] { storedEntries }
    /// The full frame, listed ahead of the first quarter frame and at the same tick, `request.originTicks`; nil when
    /// none was asked.
    var fullFrame: MTCEmitFullFrameEntry? { storedFullFrame }
    var request: MTCEmitRequest { storedRequest }

    private init(entries: [MTCEmitEntry], fullFrame: MTCEmitFullFrameEntry?, request: MTCEmitRequest) {
        storedEntries = entries
        storedFullFrame = fullFrame
        storedRequest = request
    }

    /// Builds the plan or reports the first failing check (order: see `MTCEmitRefusal`).
    static func make(_ request: MTCEmitRequest) throws(MTCEmitRefusal) -> MTCEmitPlan {
        let frames = request.frameCount
        guard frames <= maximumFrames else { throw .frameCountTooLarge(frames) }
        guard frames >= minimumFrames else { throw .frameCountTooSmall(frames) }
        guard frames % 2 == 0 else { throw .frameCountNotWholeSequences(frames) }
        let timebase = request.timebase
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        guard MTCEmitTimebase.resolvesQuarterFrames(rate: request.start.rate, timebase: timebase) else {
            throw .timebaseTooCoarse
        }
        let entries = try schedule(request)
        let fullFrame = request.fullFrameDevice.map { device in
            MTCEmitFullFrameEntry(tick: request.originTicks, frame: MTCFullFrame(deviceID: device, time: request.start))
        }
        return MTCEmitPlan(entries: entries, fullFrame: fullFrame, request: request)
    }

    private static func schedule(_ request: MTCEmitRequest) throws(MTCEmitRefusal) -> [MTCEmitEntry] {
        let total = request.frameCount * entriesPerFrame
        var entries: [MTCEmitEntry] = []
        entries.reserveCapacity(total)
        for quarter in 0..<total {
            let sequence = quarter / MTCQuarterFrame.pieceCount
            let slot = quarter % MTCQuarterFrame.pieceCount
            let advance = sequence * MTCAssembler.completionFrames
            let encoded = request.start.adding(frames: request.direction == .forward ? advance : -advance)
            let index = request.direction == .forward ? slot : MTCQuarterFrame.pieceCount - 1 - slot
            let tick = try MTCEmitTimebase.tick(
                origin: request.originTicks, quarter: quarter, rate: request.start.rate, timebase: request.timebase)
            entries.append(MTCEmitEntry(tick: tick, piece: MTCQuarterFrame.pieces(for: encoded)[index]))
        }
        return entries
    }
}
