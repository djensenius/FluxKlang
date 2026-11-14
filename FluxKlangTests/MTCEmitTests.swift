import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Structure, ordering, origin and full frame of `MTCEmitPlan`. Goldens, refusals and wraps are in the extensions of
/// this suite.
@Suite(.productionAccessAudit)
struct MTCEmitTests {
    static let unitTimebase = HostTimebase(numer: 1, denom: 1)

    static func time(_ hours: Int, _ minutes: Int, _ seconds: Int, _ frames: Int,
                     _ rate: SMPTEFrameRate) throws -> SMPTETime {
        try SMPTETime(hours: hours, minutes: minutes, seconds: seconds, frames: frames, rate: rate)
    }

    static func request(
        _ start: SMPTETime, frames: Int, timebase: HostTimebase = unitTimebase, direction: MTCDirection = .forward
    ) -> MTCEmitRequest {
        MTCEmitRequest(start: start, direction: direction, originTicks: 0, frameCount: frames, timebase: timebase,
                       fullFrameDevice: nil)
    }

    static func plan(_ request: MTCEmitRequest) throws -> MTCEmitPlan {
        try MTCEmitPlan.make(request)
    }

    static func refusal(_ request: MTCEmitRequest) -> MTCEmitRefusal? {
        do {
            _ = try MTCEmitPlan.make(request)
            return nil
        } catch {
            return error
        }
    }

    static func dataBytes(_ plan: MTCEmitPlan) -> [UInt8] {
        plan.entries.map { $0.piece.dataByte }
    }

    static func pieceIndices(_ plan: MTCEmitPlan) -> [UInt8] {
        plan.entries.map { $0.piece.piece }
    }

    static func ticks(_ plan: MTCEmitPlan) -> [UInt64] {
        plan.entries.map { $0.tick }
    }

    /// Feeds every quarter frame to a fresh assembler and returns the completed positions in order.
    static func positions(_ plan: MTCEmitPlan) -> [MTCPosition] {
        var assembler = MTCAssembler()
        var found: [MTCPosition] = []
        for entry in plan.entries {
            if case let .position(position) = assembler.consume(entry.piece) { found.append(position) }
        }
        return found
    }

    @Test func theFirstForwardSequenceEncodesTheStartFrameAndTheReceiverReportsTwoFramesLater() throws {
        let start = try Self.time(1, 0, 0, 0, .fps24)
        let found = Self.positions(try Self.plan(Self.request(start, frames: 2)))
        let position = try #require(found.first)
        let reported = try Self.time(1, 0, 0, 2, .fps24)
        #expect(found.count == 1)
        #expect(position.encoded == start)
        #expect(position.current == reported)
        #expect(position.direction == .forward)
    }

    @Test func theFirstReverseSequenceStartsAtPieceSevenEncodesTheStartFrameAndTheReceiverReportsTwoFramesEarlier()
        throws {
        let start = try Self.time(1, 0, 0, 0, .fps24)
        let plan = try Self.plan(Self.request(start, frames: 2, direction: .reverse))
        let first = try #require(plan.entries.first)
        let found = Self.positions(plan)
        let position = try #require(found.first)
        let reported = try Self.time(0, 59, 59, 22, .fps24)
        #expect(first.piece.piece == 7)
        #expect(position.encoded == start)
        #expect(position.current == reported)
        #expect(position.direction == .reverse)
    }

    @Test func aForwardPlanSendsPiecesZeroThroughSevenInEachOfTwoSequences() throws {
        let plan = try Self.plan(Self.request(try Self.time(1, 0, 0, 0, .fps24), frames: 4))
        let expected: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7]
        #expect(Self.pieceIndices(plan) == expected)
    }

    @Test func aReversePlanSendsPiecesSevenThroughZeroInEachOfTwoSequences() throws {
        let plan = try Self.plan(Self.request(try Self.time(1, 0, 0, 0, .fps24), frames: 4, direction: .reverse))
        let expected: [UInt8] = [7, 6, 5, 4, 3, 2, 1, 0, 7, 6, 5, 4, 3, 2, 1, 0]
        #expect(Self.pieceIndices(plan) == expected)
    }

    @Test func aPlanHasFourEntriesPerFrameForTwoFramesAndForTwoHundredFiftySixFrames() throws {
        let start = try Self.time(0, 0, 0, 0, .fps25)
        let small = try Self.plan(Self.request(start, frames: 2))
        let large = try Self.plan(Self.request(start, frames: 256))
        #expect(small.entries.count == 8)
        #expect(large.entries.count == 1_024)
        #expect(small.fullFrame == nil)
    }

    @Test func ticksStrictlyAscendOverTwoHundredFiftySixFramesAtEachRateInBothDirections() throws {
        let starts = [try Self.time(0, 0, 0, 0, .fps24), try Self.time(0, 0, 0, 0, .fps25),
                      try Self.time(0, 0, 0, 0, .fps2997DropFrame), try Self.time(0, 0, 0, 0, .fps30)]
        for start in starts {
            for direction in [MTCDirection.forward, MTCDirection.reverse] {
                let plan = try Self.plan(Self.request(start, frames: 256, direction: direction))
                let ticks = Self.ticks(plan)
                var ascending = true
                for index in ticks.indices.dropFirst() where ticks[index] <= ticks[index - 1] { ascending = false }
                #expect(ticks.count == 1_024, "\(start.rate) \(direction)")
                #expect(ascending, "\(start.rate) \(direction)")
            }
        }
    }

    @Test func forwardAndReversePlansFromTheSameStartAtThirtyFpsHaveTheSameTicks() throws {
        let start = try Self.time(5, 6, 7, 8, .fps30)
        let forward = try Self.plan(Self.request(start, frames: 8))
        let reverse = try Self.plan(Self.request(start, frames: 8, direction: .reverse))
        #expect(Self.ticks(forward) == Self.ticks(reverse))
    }

    @Test func theOriginTickOfOneThousandIsAddedToEachOfTheEightEntryTicksOfATwoFramePlan() throws {
        let start = try Self.time(1, 0, 0, 0, .fps24)
        let request = MTCEmitRequest(start: start, direction: .forward, originTicks: 1_000, frameCount: 2,
                                     timebase: Self.unitTimebase, fullFrameDevice: nil)
        let expected: [UInt64] = [1_000, 10_417_666, 20_834_333, 31_251_000, 41_667_666, 52_084_333, 62_501_000,
                                  72_917_666]
        let plan = try Self.plan(request)
        #expect(Self.ticks(plan) == expected)
    }

    @Test func aRequestWithoutADeviceHasNoFullFrame() throws {
        let plan = try Self.plan(Self.request(try Self.time(1, 0, 0, 0, .fps25), frames: 2))
        #expect(plan.fullFrame == nil)
    }

    @Test func aDeviceAddsAFullFrameAtTheOriginTickAndLeavesTheEntryCountUnchanged() throws {
        let start = try Self.time(1, 0, 0, 0, .fps25)
        let request = MTCEmitRequest(start: start, direction: .forward, originTicks: 1_000, frameCount: 2,
                                     timebase: Self.unitTimebase, fullFrameDevice: try SysExDeviceID(0x10))
        let plan = try Self.plan(request)
        let fullFrame = try #require(plan.fullFrame)
        let first = try #require(plan.entries.first)
        #expect(plan.entries.count == 8)
        #expect(fullFrame.tick == 1_000)
        #expect(first.tick == 1_000)
        #expect(fullFrame.frame.deviceID.rawValue == 0x10)
        #expect(fullFrame.frame.time == start)
    }

    @Test func theFullFrameBytesAreTheHandWrittenMessageForTheStartTime() throws {
        let start = try Self.time(1, 0, 0, 0, .fps25)
        let request = MTCEmitRequest(start: start, direction: .reverse, originTicks: 5, frameCount: 4,
                                     timebase: Self.unitTimebase, fullFrameDevice: SysExDeviceID.allCall)
        let plan = try Self.plan(request)
        let fullFrame = try #require(plan.fullFrame)
        let expected: [UInt8] = [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x21, 0x00, 0x00, 0x00, 0xF7]
        #expect(fullFrame.frame.bytes == expected)
    }

    @Test func aPlanKeepsTheRequestItWasBuiltFrom() throws {
        let start = try Self.time(23, 59, 58, 3, .fps2997DropFrame)
        let request = MTCEmitRequest(start: start, direction: .reverse, originTicks: 77, frameCount: 6,
                                     timebase: HostTimebase(numer: 125, denom: 3),
                                     fullFrameDevice: try SysExDeviceID(9))
        let plan = try Self.plan(request)
        #expect(plan.request == request)
    }

    @Test func aPlanFromADifferentOriginIsNotEqualToThePlanFromTheFirstOrigin() throws {
        let start = try Self.time(2, 3, 4, 5, .fps24)
        let request = Self.request(start, frames: 6)
        let moved = MTCEmitRequest(start: start, direction: .forward, originTicks: 1, frameCount: 6,
                                   timebase: Self.unitTimebase, fullFrameDevice: nil)
        let first = try Self.plan(request)
        let other = try Self.plan(moved)
        #expect(first != other)
    }
}
