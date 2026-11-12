//
//  MIDI1WireTests+RunningStatus.swift
//  FluxKlangTests
//
//  MIDI1RunningStatusWriter (#81, slice MWB1): which status bytes are left out, what ends running status, the
//  state after a refusal, reset, equality, a hand-written mixed stream and a fixed-seed pseudo-random stream, both
//  read back through MIDI1Parser. Part of the MIDI1WireTests suite.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDI1WireTests {
    func on(_ channel: UInt8, _ note: UInt8, _ velocity: UInt8 = 100) -> MIDI1Semantic {
        .noteOn(channel: channel, note: note, velocity: velocity)
    }

    func refusalOfWrite(_ writer: inout MIDI1RunningStatusWriter, _ message: MIDI1Semantic) -> MIDI1WireRefusal? {
        do {
            _ = try writer.write(message)
            return nil
        } catch {
            return error
        }
    }

    func refusalOfWrite(_ writer: inout MIDI1RunningStatusWriter, event: MIDI1Event) -> MIDI1WireRefusal? {
        do {
            _ = try writer.write(event: event)
            return nil
        } catch {
            return error
        }
    }

    @Test func aFreshWriterSendsTheFirstMessageInFull() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(writer.runningStatus == nil)
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(writer.runningStatus == 0x90)
    }

    @Test func theSameStatusIsLeftOut() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(try writer.write(on(1, 62)) == [0x3E, 0x64])
        #expect(try writer.write(on(1, 64)) == [0x40, 0x64])
        #expect(writer.runningStatus == 0x90)
    }

    @Test func aDifferentChannelOrKindIsSentInFull() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(try writer.write(on(2, 60)) == [0x91, 0x3C, 0x64])
        #expect(writer.runningStatus == 0x91)
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(try writer.write(.noteOff(channel: 1, note: 60, velocity: 64)) == [0x80, 0x3C, 0x40])
        #expect(writer.runningStatus == 0x80)
        #expect(try writer.write(on(1, 62)) == [0x90, 0x3E, 0x64])
    }

    @Test func oneDataByteKindsLeaveOutTheirStatusToo() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(.programChange(channel: 1, program: 5)) == [0xC0, 0x05])
        #expect(try writer.write(.programChange(channel: 1, program: 6)) == [0x06])
        #expect(try writer.write(.channelPressure(channel: 5, pressure: 0x40)) == [0xD4, 0x40])
        #expect(try writer.write(.channelPressure(channel: 5, pressure: 0x41)) == [0x41])
        #expect(writer.runningStatus == 0xD4)
    }

    @Test func pitchBendUsesRunningStatusUntilTheChannelChanges() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(.pitchBend(channel: 1, value: 8192)) == [0xE0, 0x00, 0x40])
        #expect(try writer.write(.pitchBend(channel: 1, value: 8193)) == [0x01, 0x40])
        #expect(try writer.write(.pitchBend(channel: 2, value: 8192)) == [0xE1, 0x00, 0x40])
    }

    @Test func aDifferentControllerOnTheSameChannelKeepsTheStatus() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(.controlChange(channel: 1, controller: 7, value: 100)) == [0xB0, 0x07, 0x64])
        #expect(try writer.write(.controlChange(channel: 1, controller: 10, value: 64)) == [0x0A, 0x40])
    }

    @Test func realTimeInsideTheStreamLeavesTheStateAlone() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(try writer.write(.realTime(status: 0xF8)) == [0xF8])
        #expect(writer.runningStatus == 0x90)
        #expect(try writer.write(on(1, 62)) == [0x3E, 0x64])
        for status: UInt8 in [0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF] {
            #expect(try writer.write(.realTime(status: status)) == [status])
            #expect(writer.runningStatus == 0x90)
            var fresh = MIDI1RunningStatusWriter()
            #expect(try fresh.write(.realTime(status: status)) == [status])
            #expect(fresh.runningStatus == nil)
        }
    }

    @Test func aRepeatedRealTimeByteIsNeverLeftOut() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(.realTime(status: 0xF8)) == [0xF8])
        #expect(try writer.write(.realTime(status: 0xF8)) == [0xF8])
        #expect(try writer.write(event: .realTime(status: 0xFE)) == [0xFE])
        #expect(try writer.write(event: .realTime(status: 0xFE)) == [0xFE])
    }

    @Test func systemCommonEndsRunningStatus() throws {
        let messages: [(message: MIDI1Semantic, bytes: [UInt8])] = [
            (.systemCommon(status: 0xF1, data1: 0x77, data2: nil), [0xF1, 0x77]),
            (.systemCommon(status: 0xF2, data1: 0, data2: 0), [0xF2, 0x00, 0x00]),
            (.systemCommon(status: 0xF3, data1: 5, data2: nil), [0xF3, 0x05]),
            (.systemCommon(status: 0xF6, data1: nil, data2: nil), [0xF6])
        ]
        for item in messages {
            var writer = MIDI1RunningStatusWriter()
            #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
            #expect(try writer.write(item.message) == item.bytes)
            #expect(writer.runningStatus == nil)
            #expect(try writer.write(on(1, 62)) == [0x90, 0x3E, 0x64])
        }
    }

    @Test func sysExEndsRunningStatusEvenWhenEmpty() throws {
        for (payload, bytes) in [([UInt8]([1, 2]), [UInt8]([0xF0, 1, 2, 0xF7])), ([], [0xF0, 0xF7])] {
            var writer = MIDI1RunningStatusWriter()
            #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
            #expect(try writer.write(.sysEx(payload: payload)) == bytes)
            #expect(writer.runningStatus == nil)
            #expect(try writer.write(on(1, 62)) == [0x90, 0x3E, 0x64])
        }
    }

    @Test func realTimeThenSystemCommonStillEndsIt() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(try writer.write(.realTime(status: 0xF8)) == [0xF8])
        #expect(try writer.write(.systemCommon(status: 0xF6, data1: nil, data2: nil)) == [0xF6])
        #expect(try writer.write(on(1, 62)) == [0x90, 0x3E, 0x64])
    }

    @Test func theEventFormSharesOneStateWithTheSemanticForm() throws {
        var events = MIDI1RunningStatusWriter()
        #expect(try events.write(event: .channel(status: 0x90, data1: 60, data2: 0)) == [0x90, 0x3C, 0x00])
        #expect(try events.write(event: .channel(status: 0x90, data1: 62, data2: 0)) == [0x3E, 0x00])
        var mixed = MIDI1RunningStatusWriter()
        #expect(try mixed.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        #expect(try mixed.write(event: .channel(status: 0x90, data1: 62, data2: 100)) == [0x3E, 0x64])
        #expect(try mixed.write(on(1, 64)) == [0x40, 0x64])
        var other = MIDI1RunningStatusWriter()
        #expect(try other.write(event: .channel(status: 0xC2, data1: 1, data2: nil)) == [0xC2, 0x01])
        #expect(try other.write(.programChange(channel: 3, program: 2)) == [0x02])
        #expect(try other.write(event: .sysEx(payload: [])) == [0xF0, 0xF7])
        #expect(other.runningStatus == nil)
    }

    @Test func aRefusedWriteChangesNothing() throws {
        let semantic: [(message: MIDI1Semantic, refusal: MIDI1WireRefusal)] = [
            (.noteOn(channel: 0, note: 60, velocity: 100), .channelOutOfRange(0)),
            (.noteOn(channel: 1, note: 60, velocity: 0), .noteOnVelocityZero(channel: 1, note: 60)),
            (.pitchBend(channel: 1, value: 20000), .pitchBendOutOfRange(20000)),
            (.systemCommon(status: 0xF4, data1: nil, data2: nil), .unsupportedSystemCommon(0xF4)),
            (.realTime(status: 0xF9), .unsupportedRealTime(0xF9)),
            (.sysEx(payload: [0x80]), .sysExByteHigh(index: 0, byte: 0x80))
        ]
        for item in semantic {
            var writer = MIDI1RunningStatusWriter()
            _ = try writer.write(on(1, 60))
            let before = writer
            #expect(refusalOfWrite(&writer, item.message) == item.refusal, "\(item.message)")
            #expect(writer == before)
            #expect(writer.runningStatus == 0x90)
            #expect(try writer.write(on(1, 62)) == [0x3E, 0x64])
            var fresh = MIDI1RunningStatusWriter()
            #expect(refusalOfWrite(&fresh, item.message) == item.refusal)
            #expect(fresh == MIDI1RunningStatusWriter())
            #expect(fresh.runningStatus == nil)
        }
        var writer = MIDI1RunningStatusWriter()
        _ = try writer.write(on(1, 60))
        let before = writer
        let forged = MIDI1Event.channel(status: 0x7F, data1: 1, data2: 2)
        #expect(refusalOfWrite(&writer, event: forged) == .channelStatus(0x7F))
        #expect(writer == before)
        #expect(writer.runningStatus == 0x90)
        #expect(try writer.write(on(1, 62)) == [0x3E, 0x64])
    }

    @Test func resetForgetsRunningStatus() throws {
        var writer = MIDI1RunningStatusWriter()
        #expect(try writer.write(on(1, 60)) == [0x90, 0x3C, 0x64])
        writer.reset()
        #expect(writer.runningStatus == nil)
        #expect(try writer.write(on(1, 62)) == [0x90, 0x3E, 0x64])
        #expect(try writer.write(on(1, 64)) == [0x40, 0x64])
        var fresh = MIDI1RunningStatusWriter()
        fresh.reset()
        #expect(fresh == MIDI1RunningStatusWriter())
    }

    @Test func writersCompareByTheirRunningStatus() throws {
        #expect(MIDI1RunningStatusWriter() == MIDI1RunningStatusWriter())
        var first = MIDI1RunningStatusWriter()
        var second = MIDI1RunningStatusWriter()
        _ = try first.write(on(1, 60))
        _ = try second.write(on(1, 60))
        #expect(first == second)
        _ = try second.write(on(2, 60))
        #expect(first != second)
        #expect(first != MIDI1RunningStatusWriter())
        second.reset()
        #expect(second == MIDI1RunningStatusWriter())
    }

    @Test func aMixedStreamIsShorterByTheOmittedStatusesAndParsesBack() throws {
        let stream: [MIDI1Semantic] = [
            on(1, 60), on(1, 62), on(1, 64),
            .noteOff(channel: 1, note: 60, velocity: 64), .noteOff(channel: 1, note: 62, velocity: 64),
            on(2, 48, 90), on(2, 50, 90), on(3, 36, 80),
            .programChange(channel: 3, program: 5), .programChange(channel: 3, program: 6),
            .programChange(channel: 3, program: 7),
            .pitchBend(channel: 1, value: 8192), .pitchBend(channel: 1, value: 8193), .realTime(status: 0xF8),
            .pitchBend(channel: 1, value: 8194), .realTime(status: 0xF8), .realTime(status: 0xFA),
            .controlChange(channel: 1, controller: 7, value: 100),
            .controlChange(channel: 1, controller: 10, value: 64),
            .channelPressure(channel: 1, pressure: 50), .channelPressure(channel: 1, pressure: 51),
            .systemCommon(status: 0xF2, data1: 16, data2: 0),
            .channelPressure(channel: 1, pressure: 52), .channelPressure(channel: 1, pressure: 53),
            .sysEx(payload: [1, 2, 3]),
            .channelPressure(channel: 1, pressure: 54),
            on(1, 60), on(1, 61), .realTime(status: 0xFC), on(1, 62),
            .systemCommon(status: 0xF6, data1: nil, data2: nil),
            on(1, 63), on(2, 63), on(2, 64),
            .sysEx(payload: []),
            .polyphonicPressure(channel: 2, note: 64, pressure: 10),
            .polyphonicPressure(channel: 2, note: 65, pressure: 11),
            .noteOff(channel: 2, note: 64, velocity: 0), .noteOff(channel: 2, note: 65, velocity: 0),
            .realTime(status: 0xFF), .noteOff(channel: 2, note: 66, velocity: 0)
        ]
        #expect(stream.count == 41)
        var writer = MIDI1RunningStatusWriter()
        var sent: [UInt8] = []
        var full: [UInt8] = []
        for message in stream {
            sent += try writer.write(message)
            full += try MIDI1Wire.bytes(message)
        }
        #expect(sent == [
            0x90, 0x3C, 0x64, 0x3E, 0x64, 0x40, 0x64, 0x80, 0x3C, 0x40, 0x3E, 0x40,
            0x91, 0x30, 0x5A, 0x32, 0x5A, 0x92, 0x24, 0x50, 0xC2, 0x05, 0x06, 0x07,
            0xE0, 0x00, 0x40, 0x01, 0x40, 0xF8, 0x02, 0x40, 0xF8, 0xFA,
            0xB0, 0x07, 0x64, 0x0A, 0x40, 0xD0, 0x32, 0x33, 0xF2, 0x10, 0x00, 0xD0, 0x34, 0x35,
            0xF0, 0x01, 0x02, 0x03, 0xF7, 0xD0, 0x36, 0x90, 0x3C, 0x64, 0x3D, 0x64, 0xFC, 0x3E, 0x64,
            0xF6, 0x90, 0x3F, 0x64, 0x91, 0x3F, 0x64, 0x40, 0x64, 0xF0, 0xF7,
            0xA1, 0x40, 0x0A, 0x41, 0x0B, 0x81, 0x40, 0x00, 0x41, 0x00, 0xFF, 0x42, 0x00
        ])
        #expect(full.count - sent.count == 17)
        #expect(try events(sent).map(\.semantic) == stream.map { Optional($0) })
    }

    private struct Generator {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D

        mutating func next(_ bound: Int) -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: (state >> 33) % UInt64(bound))
        }
    }

    /// The message and the channel status a model of running status needs (nil unless a channel message).
    private func randomMessage(_ generator: inout Generator) -> (message: MIDI1Semantic, status: UInt8?) {
        let kind = generator.next(11)
        let channel = 1 + generator.next(2) * 7
        let first = generator.next(128)
        let second = generator.next(128)
        let bases: [UInt8] = [0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0]
        let base = bases[kind == 10 ? 1 : Int(kind) % 7]
        let status: UInt8? = kind < 7 || kind == 10 ? base | (channel - 1) : nil
        switch kind {
        case 0: return (.noteOff(channel: channel, note: first, velocity: second), status)
        case 1, 10: return (.noteOn(channel: channel, note: first, velocity: 1 + second % 127), status)
        case 2: return (.polyphonicPressure(channel: channel, note: first, pressure: second), status)
        case 3: return (.controlChange(channel: channel, controller: first, value: second), status)
        case 4: return (.programChange(channel: channel, program: first), status)
        case 5: return (.channelPressure(channel: channel, pressure: first), status)
        case 6: return (.pitchBend(channel: channel, value: UInt16(first) | (UInt16(second) << 7)), status)
        case 7: return (commonMessage(first: first, second: second), nil)
        case 8: return (.realTime(status: [0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF][Int(first) % 6]), nil)
        default: return (.sysEx(payload: Array([first, second, first, second, first].prefix(Int(first) % 6))), nil)
        }
    }

    private func commonMessage(first: UInt8, second: UInt8) -> MIDI1Semantic {
        switch first % 4 {
        case 0: .systemCommon(status: 0xF1, data1: second, data2: nil)
        case 1: .systemCommon(status: 0xF2, data1: second, data2: first)
        case 2: .systemCommon(status: 0xF3, data1: second, data2: nil)
        default: .systemCommon(status: 0xF6, data1: nil, data2: nil)
        }
    }

    @Test func aPseudoRandomStreamAgreesWithAnIndependentModel() throws {
        var generator = Generator()
        var writer = MIDI1RunningStatusWriter()
        var messages: [MIDI1Semantic] = []
        var sent: [UInt8] = []
        var full: [UInt8] = []
        var model: UInt8?
        var lastChannelStatus: UInt8?
        var omitted = 0
        var resent = 0
        for _ in 0..<600 {
            let (message, status) = randomMessage(&generator)
            messages.append(message)
            sent += try writer.write(message)
            full += try MIDI1Wire.bytes(message)
            if let status {
                if status == model { omitted += 1 }
                if model == nil, status == lastChannelStatus { resent += 1 }
                model = status
                lastChannelStatus = status
            } else if case .realTime = message {
                continue
            } else {
                model = nil
            }
        }
        #expect(messages.count == 600)
        #expect(sent.count <= full.count)
        #expect(full.count - sent.count == omitted)
        #expect(omitted > 0)
        #expect(resent > 0)
        let fromRunning = try events(sent)
        let fromFull = try events(full)
        #expect(fromRunning == fromFull)
        #expect(fromRunning.map(\.semantic) == messages.map { Optional($0) })
    }
}
