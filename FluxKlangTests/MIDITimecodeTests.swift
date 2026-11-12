import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

func smpte(_ hours: Int, _ minutes: Int, _ seconds: Int, _ frames: Int,
           _ rate: SMPTEFrameRate = .fps2997DropFrame) throws -> SMPTETime {
    try SMPTETime(hours: hours, minutes: minutes, seconds: seconds, frames: frames, rate: rate)
}

func parseMIDI1(_ bytes: [UInt8]) -> [MIDI1Event] {
    guard var parser = MIDI1Parser(maximumSysExPayloadBytes: 64) else { return [] }
    return bytes.compactMap { parser.consume($0) }
}

private func quarterFrames(_ dataBytes: [UInt8]) throws -> [MTCQuarterFrame] {
    try dataBytes.map { try MTCQuarterFrame(dataByte: $0) }
}

private func feed(_ assembler: inout MTCAssembler, _ frames: [MTCQuarterFrame]) -> [MTCAssemblerOutput] {
    frames.map { assembler.consume($0) }
}

/// Independent label successor used as the round-trip oracle.
private struct Label: Equatable {
    var hours = 0, minutes = 0, seconds = 0, frames = 0

    mutating func advance(rate: SMPTEFrameRate) {
        frames += 1
        if frames == rate.framesPerSecond { frames = 0; seconds += 1 }
        if seconds == 60 { seconds = 0; minutes += 1 }
        if minutes == 60 { minutes = 0; hours += 1 }
        if rate.isDropFrame, seconds == 0, frames < 2, minutes % 10 != 0 { frames = 2 }
    }
}

/// One corrupted byte in an otherwise valid payload and the refusal it must produce.
struct ByteFault: Sendable {
    let index: Int
    let byte: UInt8
    let error: TimecodeError

    init(_ index: Int, _ byte: UInt8, _ error: TimecodeError) {
        self.index = index
        self.byte = byte
        self.error = error
    }
}

/// Test-side expectation; `MTCPosition` itself can only be built by the assembler.
struct ExpectedPosition: Equatable {
    let encoded: SMPTETime
    let current: SMPTETime
    let direction: MTCDirection
}

func == (output: MTCAssemblerOutput?, expected: ExpectedPosition) -> Bool {
    guard case let .position(position) = output else { return false }
    return ExpectedPosition(encoded: position.encoded, current: position.current, direction: position.direction)
        == expected
}

// 13:45:37;21 at 29.97 drop: frames 0x15, seconds 0x25, minutes 0x2D, hours 0x0D, rate code 2.
private let pinnedPieces: [UInt8] = [0x05, 0x11, 0x25, 0x32, 0x4D, 0x52, 0x6D, 0x74]

#if os(macOS)
@Suite("MIDI timecode", .productionAccessAudit)
#else
@Suite("MIDI timecode")
#endif
struct MIDITimecodeTests {
    @Test func rateCodesMapToTheFourMTCRates() throws {
        #expect(try SMPTEFrameRate(code: 0) == .fps24)
        #expect(try SMPTEFrameRate(code: 1) == .fps25)
        #expect(try SMPTEFrameRate(code: 2) == .fps2997DropFrame)
        #expect(try SMPTEFrameRate(code: 3) == .fps30)
        #expect(throws: TimecodeError.invalidRateCode(4)) { try SMPTEFrameRate(code: 4) }
        #expect(SMPTEFrameRate.allCases.map(\.framesPerSecond) == [24, 25, 30, 30])
        #expect(SMPTEFrameRate.allCases.map(\.isDropFrame) == [false, false, true, false])
        #expect(SMPTEFrameRate.allCases.map(\.framesPerDay) == [2_073_600, 2_160_000, 2_589_408, 2_592_000])
    }

    @Test(arguments: SMPTEFrameRate.allCases)
    func fieldBoundsAcceptNAndRefuseNPlusOne(rate: SMPTEFrameRate) throws {
        let last = rate.framesPerSecond - 1
        _ = try smpte(23, 59, 59, last, rate)
        _ = try smpte(0, 0, 0, 0, rate)
        #expect(throws: TimecodeError.fieldOutOfRange(.hours, value: 24)) { try smpte(24, 0, 0, 0, rate) }
        #expect(throws: TimecodeError.fieldOutOfRange(.minutes, value: 60)) { try smpte(0, 60, 0, 0, rate) }
        #expect(throws: TimecodeError.fieldOutOfRange(.seconds, value: 60)) { try smpte(0, 0, 60, 0, rate) }
        #expect(throws: TimecodeError.fieldOutOfRange(.frames, value: last + 1)) {
            try smpte(0, 0, 1, last + 1, rate)
        }
        #expect(throws: TimecodeError.fieldOutOfRange(.hours, value: -1)) { try smpte(-1, 0, 0, 0, rate) }
        #expect(throws: TimecodeError.fieldOutOfRange(.minutes, value: -1)) { try smpte(0, -1, 0, 0, rate) }
        #expect(throws: TimecodeError.fieldOutOfRange(.seconds, value: -1)) { try smpte(0, 0, -1, 0, rate) }
        #expect(throws: TimecodeError.fieldOutOfRange(.frames, value: -1)) { try smpte(0, 0, 0, -1, rate) }
    }

    @Test func dropFrameLabelsAreRefusedExceptEveryTenthMinute() throws {
        for minutes in 0...59 {
            for frames in 0...1 {
                if minutes % 10 == 0 {
                    _ = try smpte(5, minutes, 0, frames)
                } else {
                    #expect(throws: TimecodeError.droppedFrameLabel(minutes: minutes, frames: frames)) {
                        try smpte(5, minutes, 0, frames)
                    }
                }
                _ = try smpte(5, minutes, 1, frames)
                _ = try smpte(5, minutes, 0, frames, .fps30)
            }
            _ = try smpte(5, minutes, 0, 2)
        }
    }

    @Test func dropFrameBoundaryPins() throws {
        #expect(try smpte(0, 0, 59, 29).frameCount == 1799)
        #expect(try SMPTETime(frameCount: 1800, rate: .fps2997DropFrame) == smpte(0, 1, 0, 2))
        #expect(try smpte(0, 1, 0, 2).frameCount == 1800)
        #expect(try smpte(0, 9, 59, 29).frameCount == 17981)
        #expect(try SMPTETime(frameCount: 17982, rate: .fps2997DropFrame) == smpte(0, 10, 0, 0))
        #expect(try SMPTETime(frameCount: 17983, rate: .fps2997DropFrame) == smpte(0, 10, 0, 1))
        #expect(try SMPTETime(frameCount: 17982 + 1800, rate: .fps2997DropFrame) == smpte(0, 11, 0, 2))
        #expect(try smpte(1, 0, 0, 0).frameCount == 107_892)
        #expect(try smpte(23, 59, 59, 29).frameCount == SMPTEFrameRate.fps2997DropFrame.framesPerDay - 1)
        #expect(try smpte(0, 0, 59, 29).adding(frames: 1) == smpte(0, 1, 0, 2))
        #expect(try smpte(0, 1, 0, 2).adding(frames: -1) == smpte(0, 0, 59, 29))
        #expect(try smpte(0, 1, 0, 0, .fps30).frameCount == 1800)
    }

    @Test(arguments: SMPTEFrameRate.allCases)
    func frameCountOutsideTheDayIsRefused(rate: SMPTEFrameRate) throws {
        let day = rate.framesPerDay
        #expect(throws: TimecodeError.frameCountOutOfRange(-1, framesPerDay: day)) {
            try SMPTETime(frameCount: -1, rate: rate)
        }
        #expect(throws: TimecodeError.frameCountOutOfRange(day, framesPerDay: day)) {
            try SMPTETime(frameCount: day, rate: rate)
        }
        let last = try SMPTETime(frameCount: day - 1, rate: rate)
        #expect(try last == smpte(23, 59, 59, rate.framesPerSecond - 1, rate))
        #expect(try last.adding(frames: 1) == smpte(0, 0, 0, 0, rate))
        #expect(try smpte(0, 0, 0, 0, rate).adding(frames: -1) == last)
        #expect(last.adding(frames: 2 * day) == last)
    }

    /// Every frame of a 24-hour day at each rate, against an independent label successor.
    @Test(arguments: SMPTEFrameRate.allCases)
    func everyFrameOfTheDayRoundTrips(rate: SMPTEFrameRate) throws {
        var label = Label()
        var mismatches = 0
        for count in 0..<rate.framesPerDay {
            let time = try SMPTETime(hours: label.hours, minutes: label.minutes, seconds: label.seconds,
                                     frames: label.frames, rate: rate)
            let decoded = try SMPTETime(frameCount: count, rate: rate)
            if time.frameCount != count || decoded != time { mismatches += 1 }
            label.advance(rate: rate)
        }
        #expect(mismatches == 0)
        #expect(label == Label(hours: 24))
    }

    @Test func quarterFramePiecesPackNibblesLowFirst() throws {
        let pieces = try MTCQuarterFrame.pieces(for: smpte(13, 45, 37, 21))
        #expect(pieces.map(\.dataByte) == pinnedPieces)
        #expect(pieces.map(\.piece) == Array(0...7))
        #expect(pieces[0].bytes == [0xF1, 0x05])
        #expect(pieces[7].event == .systemCommon(status: 0xF1, data1: 0x74, data2: nil))
        #expect(try MTCQuarterFrame.time(fromNibbles: pieces.map(\.nibble)) == smpte(13, 45, 37, 21))
        let highHour = try MTCQuarterFrame.pieces(for: smpte(17, 0, 0, 0, .fps25))
        #expect(highHour[6].dataByte == 0x61)
        #expect(highHour[7].dataByte == 0x73)
        for rate in SMPTEFrameRate.allCases {
            let time = try smpte(23, 59, 58, rate.framesPerSecond - 1, rate)
            #expect(try MTCQuarterFrame.time(fromNibbles: MTCQuarterFrame.pieces(for: time).map(\.nibble)) == time)
        }
    }

    @Test func quarterFrameDecodesParserEventsAndRefusesMalformedInput() throws {
        let events = parseMIDI1(pinnedPieces.flatMap { [0xF1, $0] })
        #expect(try events.map { try MTCQuarterFrame(event: $0).dataByte } == pinnedPieces)
        #expect(throws: TimecodeError.notQuarterFrame) {
            try MTCQuarterFrame(event: .systemCommon(status: 0xF3, data1: 1, data2: nil))
        }
        #expect(throws: TimecodeError.notQuarterFrame) {
            try MTCQuarterFrame(event: .systemCommon(status: 0xF1, data1: 1, data2: 2))
        }
        #expect(throws: TimecodeError.notQuarterFrame) {
            try MTCQuarterFrame(event: .systemCommon(status: 0xF1, data1: nil, data2: nil))
        }
        #expect(throws: TimecodeError.notQuarterFrame) { try MTCQuarterFrame(event: .sysEx(payload: [0x01])) }
        #expect(throws: TimecodeError.dataByteOutOfRange(0x80)) { try MTCQuarterFrame(dataByte: 0x80) }
        #expect(throws: TimecodeError.invalidPiece(piece: 8, nibble: 0)) { try MTCQuarterFrame(piece: 8, nibble: 0) }
        // Highest legal nibble N per piece accepted, next reserved bit refused.
        let limits: [(piece: UInt8, legal: UInt8)] = [(1, 0x1), (3, 0x3), (5, 0x3), (7, 0x7)]
        for (piece, legal) in limits {
            let reserved = legal + 1
            _ = try MTCQuarterFrame(piece: piece, nibble: legal)
            #expect(throws: TimecodeError.reservedBitsSet(piece: piece, nibble: reserved)) {
                try MTCQuarterFrame(piece: piece, nibble: reserved)
            }
        }
        for piece: UInt8 in [0, 2, 4, 6] { _ = try MTCQuarterFrame(piece: piece, nibble: 0xF) }
    }

    @Test func forwardSequenceAddsTwoFramesAndStreamsContinuously() throws {
        var assembler = MTCAssembler()
        let first = try smpte(13, 45, 37, 21)
        let second = first.adding(frames: 2)
        let outputs = feed(&assembler, MTCQuarterFrame.pieces(for: first) + MTCQuarterFrame.pieces(for: second))
        #expect(outputs.filter { $0 == .pending }.count == 14)
        #expect(outputs[7] == ExpectedPosition(encoded: first, current: second, direction: .forward))
        #expect(try outputs[15] == ExpectedPosition(encoded: second, current: smpte(13, 45, 37, 25),
                                                         direction: .forward))
        #expect(assembler.counters == MTCAssemblerCounters())
    }

    @Test func reverseSequenceSubtractsTwoFrames() throws {
        var assembler = MTCAssembler()
        let time = try smpte(0, 10, 0, 1)
        let outputs = feed(&assembler, MTCQuarterFrame.pieces(for: time).reversed())
        #expect(Array(outputs.prefix(7)) == Array(repeating: .pending, count: 7))
        #expect(try outputs[7] == ExpectedPosition(encoded: time, current: smpte(0, 9, 59, 29),
                                                        direction: .reverse))
        #expect(assembler.counters == MTCAssemblerCounters())
    }

    @Test func offsetWrapsAroundMidnightAt24FPS() throws {
        var assembler = MTCAssembler()
        let late = try smpte(23, 59, 59, 23, .fps24)
        #expect(try feed(&assembler, MTCQuarterFrame.pieces(for: late)).last
            == ExpectedPosition(encoded: late, current: smpte(0, 0, 0, 1, .fps24), direction: .forward))
        let early = try smpte(0, 0, 0, 1, .fps24)
        #expect(try feed(&assembler, MTCQuarterFrame.pieces(for: early).reversed()).last
            == ExpectedPosition(encoded: early, current: smpte(23, 59, 59, 23, .fps24), direction: .reverse))
    }

    @Test func joiningMidStreamDetectsDirectionFromPieceOrder() throws {
        let time = try smpte(1, 2, 3, 4, .fps25)
        let pieces = MTCQuarterFrame.pieces(for: time)
        var forward = MTCAssembler()
        let forwardOutputs = feed(&forward, Array(pieces[3...]) + pieces)
        #expect(forwardOutputs.last == ExpectedPosition(encoded: time, current: time.adding(frames: 2),
                                                             direction: .forward))
        #expect(forward.counters == MTCAssemblerCounters(unsynchronized: 4))
        var reverse = MTCAssembler()
        let reverseOutputs = feed(&reverse, Array(pieces[...4].reversed()) + pieces.reversed())
        #expect(reverseOutputs.last == ExpectedPosition(encoded: time, current: time.adding(frames: -2),
                                                             direction: .reverse))
        #expect(reverse.counters == MTCAssemblerCounters(unsynchronized: 4))
    }

    @Test func gapsAndDuplicatesResetWithoutProducingATime() throws {
        let pieces = try MTCQuarterFrame.pieces(for: smpte(2, 3, 4, 5, .fps30))
        var assembler = MTCAssembler()
        let skipped = feed(&assembler, Array(pieces[0...2]) + Array(pieces[4...]))
        #expect(skipped[3] == .reset(.gap(expected: 3, received: 4)))
        #expect(!skipped.contains { if case .position = $0 { true } else { false } })
        let duplicated = feed(&assembler, Array(pieces[0...3]) + Array(pieces[3...]))
        #expect(duplicated[4] == .reset(.gap(expected: 4, received: 3)))
        #expect(!duplicated.contains { if case .position = $0 { true } else { false } })
        #expect(assembler.counters.gaps == 2)
        #expect(assembler.counters.unsynchronized == 5)
        // A restart piece resets the partial sequence and begins a new one.
        let restarted = feed(&assembler, Array(pieces[0...2]) + pieces)
        #expect(restarted[3] == .reset(.gap(expected: 3, received: 0)))
        #expect(try restarted.last == ExpectedPosition(encoded: smpte(2, 3, 4, 5, .fps30),
                                                            current: smpte(2, 3, 4, 7, .fps30), direction: .forward))
        #expect(assembler.counters.gaps == 3)
    }

    @Test func directionChangeMidSequenceResets() throws {
        let pieces = try MTCQuarterFrame.pieces(for: smpte(2, 3, 4, 5, .fps24))
        var assembler = MTCAssembler()
        let forwardThenBack = feed(&assembler, Array(pieces[0...3]) + Array(pieces[0...2].reversed()))
        #expect(forwardThenBack[4] == .reset(.directionChange(from: .forward)))
        var reverse = MTCAssembler()
        let backThenForward = feed(&reverse, Array(pieces[4...].reversed()) + [pieces[5], pieces[6]])
        #expect(backThenForward[4] == .reset(.directionChange(from: .reverse)))
        #expect(!(forwardThenBack + backThenForward).contains { if case .position = $0 { true } else { false } })
        #expect(assembler.counters == MTCAssemblerCounters(directionChanges: 1, unsynchronized: 1))
        #expect(reverse.counters == MTCAssemblerCounters(directionChanges: 1, unsynchronized: 1))
    }

    @Test func invalidAssembledTimesAndExplicitResetProduceNoTime() throws {
        var assembler = MTCAssembler()
        // Frames 30 at 30 fps, then drop-frame label 00:01:00;00.
        let frames30: [UInt8] = [0x0E, 0x11, 0x20, 0x30, 0x40, 0x50, 0x60, 0x76]
        #expect(try feed(&assembler, quarterFrames(frames30)).last
            == .reset(.invalidTime(.fieldOutOfRange(.frames, value: 30))))
        let dropped: [UInt8] = [0x00, 0x10, 0x20, 0x30, 0x41, 0x50, 0x60, 0x74]
        #expect(try feed(&assembler, quarterFrames(dropped)).last
            == .reset(.invalidTime(.droppedFrameLabel(minutes: 1, frames: 0))))
        let hours24: [UInt8] = [0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x68, 0x71]
        #expect(try feed(&assembler, quarterFrames(hours24)).last
            == .reset(.invalidTime(.fieldOutOfRange(.hours, value: 24))))
        #expect(assembler.counters.invalidTimes == 3)
        let pieces = try MTCQuarterFrame.pieces(for: smpte(0, 0, 0, 0, .fps24))
        _ = feed(&assembler, Array(pieces[0...3]))
        assembler.reset()
        #expect(feed(&assembler, Array(pieces[4...])) == [
            .reset(.unsynchronized(piece: 4)), .reset(.unsynchronized(piece: 5)),
            .reset(.unsynchronized(piece: 6)), .pending
        ])
    }

    /// Expected counts are Int.max and Int.min modulo each day length, computed outside Swift.
    @Test func extremeOffsetsWrapWithinTheDayWithoutTrapping() throws {
        let pins: [SMPTEFrameRate: (max: Int, min: Int)] = [
            .fps24: (1_783_807, 289_792), .fps25: (55_807, 2_104_192),
            .fps2997DropFrame: (2_413_663, 175_744), .fps30: (1_783_807, 808_192)
        ]
        for (rate, pin) in pins {
            let start = try smpte(0, 0, 0, 0, rate)
            let last = try SMPTETime(frameCount: rate.framesPerDay - 1, rate: rate)
            #expect(try start.adding(frames: .max) == SMPTETime(frameCount: pin.max, rate: rate))
            #expect(try start.adding(frames: .min) == SMPTETime(frameCount: pin.min, rate: rate))
            #expect(try last.adding(frames: .max) == SMPTETime(frameCount: pin.max - 1, rate: rate))
            #expect(try last.adding(frames: .min) == SMPTETime(frameCount: pin.min - 1, rate: rate))
        }
    }

    @Test func lostPieceSixIsAGapNotAReverseRestart() throws {
        let pieces = MTCQuarterFrame.pieces(for: try smpte(4, 5, 6, 7, .fps25))
        var assembler = MTCAssembler()
        let outputs = feed(&assembler, Array(pieces[0...5]) + [pieces[7]])
        #expect(Array(outputs.prefix(6)) == Array(repeating: .pending, count: 6))
        #expect(outputs[6] == .reset(.gap(expected: 6, received: 7)))
        #expect(assembler.counters == MTCAssemblerCounters(gaps: 1))
    }

    @Test func rateMayChangeBetweenConsecutiveSequences() throws {
        let first = try smpte(1, 0, 0, 28, .fps30)
        let second = try smpte(1, 0, 1, 0, .fps24)
        var assembler = MTCAssembler()
        let outputs = feed(&assembler, MTCQuarterFrame.pieces(for: first) + MTCQuarterFrame.pieces(for: second))
        #expect(try outputs[7] == ExpectedPosition(encoded: first, current: smpte(1, 0, 1, 0, .fps30),
                                                   direction: .forward))
        #expect(try outputs[15] == ExpectedPosition(encoded: second, current: smpte(1, 0, 1, 2, .fps24),
                                                    direction: .forward))
        #expect(assembler.counters == MTCAssemblerCounters())
    }

    // Compile-time fence: MTCPosition's only initializer is fileprivate to MTCAssembler.swift, so no caller
    // can pair an `encoded` time with an inconsistent `current`.
    #if false
    static let zero = try? SMPTETime(frameCount: 0, rate: .fps24)
    static let forgedPosition = MTCPosition(encoded: zero, current: zero, direction: .forward)
    static let derivedPosition = MTCPosition(encoded: zero, direction: .reverse)
    #endif

    @Test func fullFrameDecodesParserPayloadAndEncodesEveryRate() throws {
        // 10:20:30:12 at 25 fps: hr = 0b0_01_01010.
        let wire: [UInt8] = [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x2A, 20, 30, 12, 0xF7]
        let events = parseMIDI1(wire)
        #expect(events == [.sysEx(payload: Array(wire[1...8]))])
        let frame = try MTCFullFrame(event: events[0])
        #expect(frame == MTCFullFrame(deviceID: .allCall, time: try smpte(10, 20, 30, 12, .fps25)))
        #expect(frame.bytes == wire)
        for rate in SMPTEFrameRate.allCases {
            let time = try smpte(23, 59, 59, rate.framesPerSecond - 1, rate)
            let encoded = MTCFullFrame(deviceID: try SysExDeviceID(0x05), time: time)
            #expect(encoded.sysExPayload == [0x7F, 0x05, 0x01, 0x01, rate.rawValue << 5 | 23, 59, 59,
                                             UInt8(rate.framesPerSecond - 1)])
            #expect(try MTCFullFrame(event: encoded.event) == encoded)
        }
    }

    @Test func fullFrameFiltersByDeviceIncludingAllCall() throws {
        let time = try smpte(0, 0, 0, 0, .fps30)
        let receiver = try SysExDeviceID(0x05)
        let direct = MTCFullFrame(deviceID: receiver, time: time)
        let other = MTCFullFrame(deviceID: try SysExDeviceID(0x06), time: time)
        let allCall = MTCFullFrame(deviceID: .allCall, time: time)
        #expect(try MTCFullFrame.decode(direct.event, receiver: receiver) == direct)
        #expect(try MTCFullFrame.decode(other.event, receiver: receiver) == nil)
        #expect(try MTCFullFrame.decode(allCall.event, receiver: receiver) == allCall)
        #expect(try MTCFullFrame.decode(allCall.event, receiver: SysExDeviceID(0x00)) == allCall)
        #expect(try MTCFullFrame(sysExPayload: [0x7F, 0x00, 0x01, 0x01, 0, 0, 0, 0]).deviceID.rawValue == 0)
        #expect(throws: TimecodeError.dataByteOutOfRange(0x80)) {
            try MTCFullFrame(sysExPayload: [0x7F, 0x80, 0x01, 0x01, 0, 0, 0, 0])
        }
    }

    @Test func fullFrameRefusesWrongHeaderLengthAndFields() throws {
        let valid: [UInt8] = [0x7F, 0x7F, 0x01, 0x01, 0x60 | 23, 59, 59, 29]
        _ = try MTCFullFrame(sysExPayload: valid)
        #expect(throws: TimecodeError.lengthMismatch(expected: 8, actual: 7)) {
            try MTCFullFrame(sysExPayload: Array(valid.dropLast()))
        }
        #expect(throws: TimecodeError.lengthMismatch(expected: 8, actual: 9)) {
            try MTCFullFrame(sysExPayload: valid + [0])
        }
        let headers: [[UInt8]] = [[0x7E, 0x7F, 0x01, 0x01], [0x7F, 0x7F, 0x01, 0x02], [0x7F, 0x7F, 0x06, 0x01], [0x7F]]
        for header in headers {
            #expect(throws: TimecodeError.notTimecodeMessage) { try MTCFullFrame(sysExPayload: header + [0, 0, 0, 0]) }
        }
        #expect(throws: TimecodeError.notTimecodeMessage) {
            try MTCFullFrame(event: .systemCommon(status: 0xF1, data1: 0, data2: nil))
        }
        let faults: [ByteFault] = [
            .init(4, 0x60 | 24, .fieldOutOfRange(.hours, value: 24)),
            .init(5, 60, .fieldOutOfRange(.minutes, value: 60)),
            .init(6, 60, .fieldOutOfRange(.seconds, value: 60)), .init(7, 30, .fieldOutOfRange(.frames, value: 30)),
            .init(4, 0x80, .dataByteOutOfRange(0x80)), .init(7, 0x80, .dataByteOutOfRange(0x80))
        ]
        for fault in faults {
            var payload = valid
            payload[fault.index] = fault.byte
            #expect(throws: fault.error) { try MTCFullFrame(sysExPayload: payload) }
        }
        #expect(throws: TimecodeError.droppedFrameLabel(minutes: 1, frames: 1)) {
            try MTCFullFrame(sysExPayload: [0x7F, 0x7F, 0x01, 0x01, 0x40, 1, 0, 1])
        }
    }
}
