//
//  CaptureOverflowCoalescer.swift
//  FluxKlang
//
//  Merges touching capture overflow intervals into one ledger discontinuity
//  (#109 CDB1, media-contract.md section 8.3). A stalled writer pads every block, so
//  the pump reports one touching interval per block; the ledger takes each as
//  a separate record and refuses past 4_096. One coalescer is one ledger
//  segment: it reads no ledger, pump or clock and decides no stop. Each call
//  does constant work (by code reading). `offer` checks the interval first and assigns
//  after its last throw, so a refusal leaves the coalescer `==` its copy.
//  Invariant after each call: `offeredFrames == emittedFrames + pendingFrames
//  + unrecordedFrames` and `recordsUsed <= recordLimit`.
//

struct CaptureOverflowCoalescer: Equatable, Sendable {
    let clock: UInt32
    let generation: UInt64
    let stream: UInt32
    let recordLimit: Int
    /// Records emitted, plus one while a run is held.
    private(set) var recordsUsed = 0
    private(set) var heldStart: Int64?
    private(set) var heldFrames: Int64 = 0
    /// The end of the last interval offered, recorded or not.
    private(set) var frontier: Int64?
    private(set) var offeredFrames: UInt64 = 0
    private(set) var emittedFrames: UInt64 = 0
    private(set) var unrecordedFrames: UInt64 = 0
    private(set) var isSaturated = false

    var hasPending: Bool { heldStart != nil }
    var pendingFrames: UInt64 { UInt64(heldFrames) }

    private init(clock: UInt32, generation: UInt64, stream: UInt32, recordLimit: Int) {
        self.clock = clock
        self.generation = generation
        self.stream = stream
        self.recordLimit = recordLimit
    }

    /// Refuses a record limit outside `1...maximumRecords`.
    static func make(clock: UInt32, generation: UInt64, stream: UInt32,
                     recordLimit: Int = CaptureOverflowLimits.maximumRecords) throws(CaptureOverflowRefusal) -> Self {
        let maximum = CaptureOverflowLimits.maximumRecords
        guard (1...maximum).contains(recordLimit) else {
            throw .recordLimitOutOfRange(limit: recordLimit, maximum: maximum)
        }
        return Self(clock: clock, generation: generation, stream: stream, recordLimit: recordLimit)
    }

    /// Takes one overflow interval. Refusals, first failure wins: frames outside `1...maximumRecordFrames`, a
    /// negative start, an end that overflows `Int64`, a start before the frontier. A touching interval joins the
    /// held run while the run stays within the 32-bit width; a gap is not bridged and a run is split, not clamped.
    mutating func offer(_ interval: CaptureDrainOverflow) throws(CaptureOverflowRefusal) -> CaptureOverflowStep {
        let end = try check(interval)
        let frames = Int64(interval.frames)
        if absorbs(interval) {
            offeredFrames = Self.add(offeredFrames, frames)
            heldFrames += frames
            frontier = end
            return .held
        }
        if recordsUsed >= recordLimit {
            offeredFrames = Self.add(offeredFrames, frames)
            unrecordedFrames = Self.add(unrecordedFrames, frames)
            isSaturated = true
            frontier = end
            return .saturated(interval)
        }
        let closed = try closedRecord()
        offeredFrames = Self.add(offeredFrames, frames)
        if closed != nil { emittedFrames = Self.add(emittedFrames, heldFrames) }
        heldStart = interval.startFrame
        heldFrames = frames
        recordsUsed += 1
        frontier = end
        if let record = closed { return .record(record) }
        return .held
    }

    /// Closes the held run (nil when none). The frontier, the record count and the counters are kept, so a
    /// touching interval offered afterwards starts a new record.
    mutating func flush() throws(CaptureOverflowRefusal) -> RuntimeDiscontinuity? {
        guard let record = try closedRecord() else { return nil }
        emittedFrames = Self.add(emittedFrames, heldFrames)
        heldStart = nil
        heldFrames = 0
        return record
    }

    private func check(_ interval: CaptureDrainOverflow) throws(CaptureOverflowRefusal) -> Int64 {
        let maximum = CaptureOverflowLimits.maximumRecordFrames
        guard (1...maximum).contains(interval.frames) else {
            throw .framesOutOfRange(frames: interval.frames, maximum: maximum)
        }
        guard interval.startFrame >= 0 else { throw .negativeStartFrame(interval.startFrame) }
        let (end, overflow) = interval.startFrame.addingReportingOverflow(Int64(interval.frames))
        guard !overflow else { throw .frameOverflow(startFrame: interval.startFrame, frames: interval.frames) }
        if let previous = frontier, interval.startFrame < previous {
            throw .overlapsPrevious(startFrame: interval.startFrame, frontier: previous)
        }
        return end
    }

    /// True when the interval touches the held run and the merged run stays within the 32-bit width.
    private func absorbs(_ interval: CaptureDrainOverflow) -> Bool {
        guard let start = heldStart, start + heldFrames == interval.startFrame else { return false }
        return heldFrames + Int64(interval.frames) <= Int64(CaptureOverflowLimits.maximumRecordFrames)
    }

    private func closedRecord() throws(CaptureOverflowRefusal) -> RuntimeDiscontinuity? {
        guard let start = heldStart else { return nil }
        let sample = RuntimeSampleStamp(clock: clock, generation: generation, frame: start)
        do throws(MediaIOMappingRefusal) {
            return try MediaIOFaultMapping.discontinuity(MediaIOFaultMapping.writerBackpressureKind, at: sample,
                                                         stream: stream, frames: heldFrames)
        } catch {
            throw .mapping(error)
        }
    }

    private static func add(_ value: UInt64, _ frames: Int64) -> UInt64 {
        PrefetchFillCounters.saturatingSum(value, UInt64(frames))
    }
}
