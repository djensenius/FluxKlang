import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private let simpleCommands: [(UInt8, MMCCommand)] = [
    (0x01, .stop), (0x02, .play), (0x03, .deferredPlay), (0x04, .fastForward),
    (0x05, .rewind), (0x06, .recordStrobe), (0x07, .recordExit), (0x09, .pause)
]

private func locate(_ fields: [UInt8], device: UInt8 = 0x7F) -> [UInt8] {
    [0x7F, device, 0x06, 0x44, 0x06, 0x01] + fields
}

@Suite("MIDI machine control", .productionAccessAudit)
struct MIDIMachineControlTests {
    @Test func simpleCommandCodesEncodeAndDecode() throws {
        let device = try SysExDeviceID(0x10)
        for (code, command) in simpleCommands {
            let message = MMCMessage(deviceID: device, command: command)
            #expect(command.code == code)
            #expect(message.bytes == [0xF0, 0x7F, 0x10, 0x06, code, 0xF7])
            let events = parseMIDI1(message.bytes)
            #expect(events == [message.event])
            #expect(try MMCMessage(event: events[0]) == message)
        }
    }

    @Test func unsupportedCommandsAndLengthsAreRefused() throws {
        for code: UInt8 in [0x00, 0x08, 0x0A, 0x0D, 0x40, 0x45, 0x7F] {
            #expect(throws: TimecodeError.unsupportedMMCCommand(code)) {
                try MMCMessage(sysExPayload: [0x7F, 0x7F, 0x06, code])
            }
        }
        #expect(throws: TimecodeError.lengthMismatch(expected: 1, actual: 0)) {
            try MMCMessage(sysExPayload: [0x7F, 0x7F, 0x06])
        }
        #expect(throws: TimecodeError.dataByteOutOfRange(0x81)) {
            try MMCMessage(sysExPayload: [0x7F, 0x7F, 0x06, 0x81])
        }
    }

    @Test func nonCommandMessagesAreNotMMC() throws {
        let payloads: [[UInt8]] = [
            [0x7F, 0x7F, 0x07, 0x01], [0x7E, 0x7F, 0x06, 0x01], [0x7F, 0x7F, 0x01, 0x01, 0, 0, 0, 0], [0x7F], []
        ]
        for payload in payloads {
            #expect(throws: TimecodeError.notMMCCommand) { try MMCMessage(sysExPayload: payload) }
        }
        #expect(throws: TimecodeError.notMMCCommand) { try MMCMessage(event: .realTime(status: 0xFA)) }
        #expect(throws: TimecodeError.notTimecodeMessage) {
            try MTCFullFrame(sysExPayload: [0x7F, 0x7F, 0x06, 0x01])
        }
    }

    @Test func locateCarriesItsTargetTimecode() throws {
        // 01:02:03;04.99 at 29.97 drop, hr = 0b0_10_00001.
        let wire: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x44, 0x06, 0x01, 0x41, 2, 3, 4, 99, 0xF7]
        let events = parseMIDI1(wire)
        let message = try MMCMessage(event: events[0])
        let target = try MMCLocateTarget(time: smpte(1, 2, 3, 4), subframes: 99)
        #expect(message == MMCMessage(deviceID: .allCall, command: .locate(target)))
        #expect(message.bytes == wire)
        #expect(message.command.code == 0x44)
        for rate in SMPTEFrameRate.allCases {
            let time = try smpte(23, 59, 59, rate.framesPerSecond - 1, rate)
            let command = MMCCommand.locate(try MMCLocateTarget(time: time))
            let encoded = MMCMessage(deviceID: try SysExDeviceID(0), command: command)
            #expect(encoded.sysExPayload == [0x7F, 0x00, 0x06, 0x44, 0x06, 0x01, rate.rawValue << 5 | 23, 59, 59,
                                             UInt8(rate.framesPerSecond - 1), 0])
            #expect(try MMCMessage(sysExPayload: encoded.sysExPayload) == encoded)
        }
    }

    @Test func locateRefusesOutOfRangeFieldsFlagsAndForms() throws {
        let valid: [UInt8] = [0x60 | 23, 59, 59, 29, 99]
        _ = try MMCMessage(sysExPayload: locate(valid))
        #expect(throws: TimecodeError.fieldOutOfRange(.subframes, value: 100)) {
            try MMCLocateTarget(time: smpte(0, 0, 0, 0), subframes: 100)
        }
        #expect(throws: TimecodeError.fieldOutOfRange(.subframes, value: -1)) {
            try MMCLocateTarget(time: smpte(0, 0, 0, 0), subframes: -1)
        }
        let faults: [ByteFault] = [
            .init(0, 0x60 | 24, .fieldOutOfRange(.hours, value: 24)),
            .init(1, 60, .fieldOutOfRange(.minutes, value: 60)),
            .init(2, 60, .fieldOutOfRange(.seconds, value: 60)), .init(3, 30, .fieldOutOfRange(.frames, value: 30)),
            .init(4, 100, .fieldOutOfRange(.subframes, value: 100)), .init(4, 0x80, .dataByteOutOfRange(0x80)),
            .init(1, 0x40 | 60, .fieldOutOfRange(.minutes, value: 60)),
            .init(2, 0x40, .reservedFlagsSet(byte: 0x40)),
            .init(3, 0x40, .reservedFlagsSet(byte: 0x40)), .init(3, 0x20, .reservedFlagsSet(byte: 0x20)),
            .init(0, 0x80, .dataByteOutOfRange(0x80))
        ]
        for fault in faults {
            var target = valid
            target[fault.index] = fault.byte
            #expect(throws: fault.error) { try MMCMessage(sysExPayload: locate(target)) }
        }
        #expect(throws: TimecodeError.droppedFrameLabel(minutes: 1, frames: 0)) {
            try MMCMessage(sysExPayload: locate([0x40, 1, 0, 0, 0]))
        }
        #expect(throws: TimecodeError.unsupportedLocateForm(0x00)) {
            try MMCMessage(sysExPayload: [0x7F, 0x7F, 0x06, 0x44, 0x02, 0x00, 0x01])
        }
        #expect(throws: TimecodeError.lengthMismatch(expected: 6, actual: 5)) {
            try MMCMessage(sysExPayload: [0x7F, 0x7F, 0x06, 0x44, 0x05, 0x01, 0, 0, 0, 0])
        }
        #expect(throws: TimecodeError.lengthMismatch(expected: 8, actual: 7)) {
            try MMCMessage(sysExPayload: locate(Array(valid.dropLast())))
        }
        #expect(throws: TimecodeError.lengthMismatch(expected: 8, actual: 2)) {
            try MMCMessage(sysExPayload: [0x7F, 0x7F, 0x06, 0x44, 0x06])
        }
    }

    @Test func deviceIDBoundsAndAddressing() throws {
        for raw in UInt8(0)...0x7F { #expect(try SysExDeviceID(raw).rawValue == raw) }
        #expect(throws: TimecodeError.deviceIDOutOfRange(0x80)) { try SysExDeviceID(0x80) }
        #expect(SysExDeviceID.allCall.rawValue == 0x7F)
        #expect(SysExDeviceID.allCall.isAllCall)
        #expect(try !SysExDeviceID(0x7E).isAllCall)
        let receiver = try SysExDeviceID(0x7E)
        let play = MMCMessage(deviceID: receiver, command: .play)
        let toOther = MMCMessage(deviceID: try SysExDeviceID(0x7D), command: .play)
        let toAll = MMCMessage(deviceID: .allCall, command: .stop)
        #expect(try MMCMessage.decode(play.event, receiver: receiver) == play)
        #expect(try MMCMessage.decode(toOther.event, receiver: receiver) == nil)
        #expect(try MMCMessage.decode(toAll.event, receiver: receiver) == toAll)
        #expect(try MMCMessage.decode(toAll.event, receiver: SysExDeviceID(0)) == toAll)
        let toFive = MMCMessage(deviceID: try SysExDeviceID(0x05), command: .play)
        #expect(try MMCMessage.decode(toFive.event, receiver: .allCall) == nil)
        let fullFrame = MTCFullFrame(deviceID: try SysExDeviceID(0x05), time: try smpte(0, 0, 0, 0, .fps25))
        #expect(try MTCFullFrame.decode(fullFrame.event, receiver: .allCall) == nil)
        for raw in UInt8(0)...0x7F {
            let other = try SysExDeviceID(raw)
            #expect(SysExDeviceID.allCall.addresses(other))
            #expect(other.addresses(.allCall) == (raw == 0x7F))
        }
        #expect(try SysExDeviceID(0x7E).addresses(receiver))
        #expect(try !SysExDeviceID(0x00).addresses(receiver))
    }

    @Test func locateColorFrameFlagIsPreservedSeparatelyFromTheTime() throws {
        let time = try smpte(1, 2, 3, 4)
        for colorFrame in [false, true] {
            let target = try MMCLocateTarget(time: time, subframes: 7, colorFrame: colorFrame)
            let message = MMCMessage(deviceID: .allCall, command: .locate(target))
            #expect(message.sysExPayload == locate([0x41, colorFrame ? 0x42 : 0x02, 3, 4, 7]))
            let decoded = try MMCMessage(event: parseMIDI1(message.bytes)[0])
            #expect(decoded == message)
            guard case let .locate(decodedTarget) = decoded.command else {
                Issue.record("expected locate")
                continue
            }
            #expect(decodedTarget.colorFrame == colorFrame)
            #expect(decodedTarget.time == time)
            #expect(decodedTarget.subframes == 7)
        }
        #expect(try MMCLocateTarget(time: time).colorFrame == false)
    }

    @Test func multipleCommandsInOneMessageAreRefusedWhole() throws {
        let locateBytes: [UInt8] = [0x44, 0x06, 0x01, 0x41, 2, 3, 4, 0]
        let cases: [(bytes: [UInt8], error: TimecodeError)] = [
            ([0x02, 0x01], .multipleMMCCommands(firstCommandLength: 1, totalLength: 2)),
            ([0x01, 0x01, 0x01], .multipleMMCCommands(firstCommandLength: 1, totalLength: 3)),
            ([0x02] + locateBytes, .multipleMMCCommands(firstCommandLength: 1, totalLength: 9)),
            (locateBytes + [0x01], .multipleMMCCommands(firstCommandLength: 8, totalLength: 9)),
            (locateBytes + locateBytes, .multipleMMCCommands(firstCommandLength: 8, totalLength: 16))
        ]
        for (bytes, error) in cases {
            let event = MIDI1Event.sysEx(payload: [0x7F, 0x05, 0x06] + bytes)
            #expect(throws: error) { try MMCMessage(event: event) }
            #expect(throws: error) { try MMCMessage.decode(event, receiver: SysExDeviceID(0x05)) }
            #expect(throws: error) { try MMCMessage.decode(event, receiver: SysExDeviceID(0x06)) }
        }
    }
}
