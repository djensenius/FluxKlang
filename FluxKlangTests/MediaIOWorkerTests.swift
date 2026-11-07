import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The off-render media I/O worker contract (#109 IO2): limits and faults, validated requests, scripted fakes, the
/// prefetch fill pump and the fault mapping. The topics live in the `MediaIOWorkerTests+...` extensions, which share
/// the builders below. No test touches a file, a clock, a thread or randomness beyond a fixed seed.
@Suite("Media I/O workers")
struct MediaIOWorkerTests {
    /// The refusal a throwing body produced, or nil when it did not throw that type.
    static func refusal<Failure: Error, Value>(_ type: Failure.Type, _ body: () throws -> Value) -> Failure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? Failure
        }
    }

    /// Runs `body` on `pump`; the refusal must equal `expected` and the whole pump must be unchanged.
    static func expectRefusal(
        _ pump: inout PrefetchFillPump,
        _ expected: PrefetchFillRefusal,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (inout PrefetchFillPump) throws -> some Any
    ) {
        let before = pump
        var copy = pump
        let refused = refusal(PrefetchFillRefusal.self) { try body(&copy) }
        #expect(refused == expected, sourceLocation: sourceLocation)
        #expect(copy == before, sourceLocation: sourceLocation)
        pump = copy
    }

    /// One leased block's identity from a real pool; requests only echo it.
    static func lease(slot: Int = 0) throws -> MediaBlockLease {
        let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: 4, headFrames: 64)
        let pool = try MediaBlockPool.make(plan: plan, channelCount: 2)
        var leases: [MediaBlockLease] = []
        for _ in 0...slot { leases.append(try pool.lease()) }
        return try #require(leases.last)
    }

    static func readRequest(
        frames: Int = 8,
        start: Int64 = 0,
        lease: MediaBlockLease? = nil
    ) throws -> MediaReadRequest {
        try MediaReadRequest.make(lease: lease ?? Self.lease(), startFrame: start, frames: frames,
                                  sourceGeneration: 1, readGeneration: 0)
    }

    static func writeRequest(frames: Int = 8, start: Int64 = 0) throws -> MediaWriteRequest {
        try MediaWriteRequest.make(lease: Self.lease(), startFrame: start, frames: frames)
    }

    /// The plan used by the pump tests: 4 blocks of 64 frames, a 128-frame head.
    static func plan() throws -> PrefetchPlan {
        try PrefetchPlan.make(blockFrames: 64, blockCount: 4, headFrames: 128)
    }

    /// A pump over a 1_000-frame source, source generation 1, read generation 5.
    static func pump(
        source: Int64 = 1_000,
        position: Int64 = 0,
        readGeneration: UInt64 = 5
    ) throws -> PrefetchFillPump {
        try PrefetchFillPump.make(plan: plan(), sourceFrames: source, sourceGeneration: 1,
                                  readGeneration: readGeneration, position: position)
    }

    /// Issues the next ticket; fails the test when the pump does not issue one.
    static func issue(
        _ pump: inout PrefetchFillPump,
        position: Int64 = 0,
        resident: Int = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> PrefetchFillTicket {
        let step = try pump.nextRequest(position: position, residentBlocks: resident)
        guard case .request(let ticket) = step else {
            Issue.record("expected a request, got \(step)", sourceLocation: sourceLocation)
            throw IssueRecordedError()
        }
        return ticket
    }

    struct IssueRecordedError: Error {}

    /// Issues a ticket and answers it with `frames` frames; returns the ticket and the outcome.
    static func fill(
        _ pump: inout PrefetchFillPump,
        frames: Int,
        reachedEnd: Bool = false,
        position: Int64 = 0
    ) throws -> (ticket: PrefetchFillTicket, outcome: PrefetchFillOutcome) {
        let ticket = try issue(&pump, position: position)
        let outcome = try pump.receive(ticket.id, .ready(MediaReadResult(frames: frames, reachedEnd: reachedEnd)))
        return (ticket, outcome)
    }

    /// Issues a ticket and fails it with `fault`.
    static func failNext(_ pump: inout PrefetchFillPump, _ fault: MediaReadFault) throws -> PrefetchFillOutcome {
        let ticket = try issue(&pump)
        return try pump.fail(ticket.id, fault)
    }

    /// The delivery inside an outcome, or nil.
    static func delivery(_ outcome: PrefetchFillOutcome) -> PrefetchFillDelivery? {
        if case .delivered(let delivery) = outcome { delivery } else { nil }
    }

    /// A stable name for each discontinuity kind (`RuntimeDiscontinuityKind` is not `Equatable`).
    static func name(_ kind: RuntimeDiscontinuityKind?) -> String {
        kind.map(describe) ?? "nil"
    }

    private static func describe(_ kind: RuntimeDiscontinuityKind) -> String {
        switch kind {
        case .clockRestart(let previous): return "clockRestart(\(previous))"
        case .sampleJump: return "sampleJump"
        case .underrun: return "underrun"
        case .overflow: return "overflow"
        case .sourceLost: return "sourceLost"
        case .sourceRestored: return "sourceRestored"
        case .locate: return "locate"
        case .loopWrap: return "loopWrap"
        case .formatChange: return "formatChange"
        case .captureStopped(let reason): return "captureStopped(\(reason))"
        }
    }
}
