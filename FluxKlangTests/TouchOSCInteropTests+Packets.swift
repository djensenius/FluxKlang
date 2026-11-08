import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// Bounds at N and N + 1, UDP versus TCP, and the default-off endpoint.
extension TouchOSCInteropTests {
    // MARK: Bounds

    @Test("An address of 257 bytes is addressTooLong; one of 256 bytes is refused by the segment rules instead")
    func addressOf257BytesIsTooLongAndOf256BytesIsRefusedBySegmentRules() throws {
        let long = Fixture.address(ofBytes: 257)
        #expect(long.utf8.count == 257)
        #expect(try Fixture.refusal(long) == .addressTooLong(byteCount: 257, limit: 256))
        let edge = Fixture.address(ofBytes: 256)
        #expect(edge.utf8.count == 256)
        #expect(try Fixture.refusal(edge) == .segmentTooLong(index: 3, byteCount: 243, limit: 32))
        let manyShort = "/fk/v1/param/" + String(repeating: "a/", count: 121) + "a"
        #expect(manyShort.utf8.count == 256)
        #expect(try Fixture.refusal(manyShort) == .tooManySegments(count: 125, limit: 6))
    }

    @Test("A multi-byte UTF-8 address byte is refused by the codec before the mapper sees any packet")
    func aMultiByteAddressIsMalformedAtIntakeAndNeverReachesTheMapper() throws {
        let address = Array("/fk/v1/param/f\u{E9}der".utf8)
        #expect(address.count == 19)
        let packet = address + [0] + [UInt8](repeating: 0, count: 4 - (address.count + 1) % 4) + [0x2C, 0, 0, 0]
        var pipeline = try Fixture.pipeline()
        let delivery = try Fixture.datagram(&pipeline, packet)
        #expect(delivery == .intake(.malformed(.invalidAddress(.invalidCharacter(0xC3)))))
    }

    @Test("Six segments reach the route check and seven are refused tooManySegments")
    func segmentCountBoundaryIsSixAndSeven() throws {
        let args: [OSC.Argument] = [.float32(0)]
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp/x", args) == .unknownRoute(segmentCount: 6))
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp/x/y", args) == .tooManySegments(count: 7, limit: 6))
    }

    @Test("A segment of 32 bytes reaches the route check and one of 33 bytes is refused segmentTooLong")
    func segmentLengthBoundaryIs32And33Bytes() throws {
        #expect(try Fixture.refusal(Fixture.longSegment(32)) == .unknownRoute(segmentCount: 4))
        #expect(try Fixture.refusal(Fixture.longSegment(33)) == .segmentTooLong(index: 3, byteCount: 33, limit: 32))
    }

    @Test("A batch of 1,024 messages maps in order and one of 1,025 is refused before any message is read")
    func batchBoundaryIs1024And1025Messages() throws {
        let mapper = try Fixture.mapper()
        let start = try Fixture.message("/fk/v1/transport/start")
        let batch = [OSC.Message](repeating: start, count: 1_024)
        #expect(try mapper.map(batch: batch) == [CommandOperation](repeating: .start, count: 1_024))
        let over = batch + [try Fixture.message("/fk/v1/hazard/panic")]
        #expect(throws: OSC.NamespaceBatchRefusal.tooManyMessages(count: 1_025, limit: 1_024)) {
            try mapper.map(batch: over)
        }
        let late = Array(batch.dropLast()) + [try Fixture.message("/fk/v1/hazard/panic")]
        #expect(throws: OSC.NamespaceBatchRefusal.message(index: 1_023, refusal: .refusedFamily(.hazard))) {
            try mapper.map(batch: late)
        }
        #expect(try mapper.map(batch: []) == [])
    }

    @Test("Start and stop take no argument, locate takes one non-negative tick count, and the namespace needs a family")
    func transportVerbsTakeTheirExactArguments() throws {
        for verb in ["start", "stop"] {
            let address = "/fk/v1/transport/\(verb)"
            #expect(try Fixture.refusal(address, [.int32(1)]) == .wrongArgumentCount(minimum: 0, maximum: 0, got: 1))
        }
        let locate = "/fk/v1/transport/locate"
        #expect(try Fixture.refusal(locate) == .wrongArgumentCount(minimum: 1, maximum: 1, got: 0))
        #expect(try Fixture.refusal(locate, [.int32(-1)]) == .negativeTicks)
        #expect(try Fixture.map(locate, [.int32(0)]) == .success(.locate(ticks: 0)))
        #expect(try Fixture.map(locate, [.int64(5_000_000_000)]) == .success(.locate(ticks: 5_000_000_000)))
        #expect(try Fixture.refusal(locate, [.float32(1)]) == .unsupportedArgument(index: 0, typeTag: 0x66))
        #expect(try Fixture.refusal("/fk/v1") == .missingFamily)
    }

    @Test("A ramp of 0 and 60,000 ms maps; -1 and 60,001 ms are refused rampMillisecondsOutOfRange")
    func rampBoundaryIsZeroToSixtyThousandMilliseconds() throws {
        let target = ParameterCatalog.wingFaderDecibels
        for milliseconds in [0, 60_000] {
            let outcome = try Fixture.map("/fk/v1/param/fader/ramp", [.float32(0), .int32(Int32(milliseconds))])
            let expected = CommandOperation.ramp(
                target, ParameterValue(value: 0, unit: .decibels), milliseconds: milliseconds
            )
            #expect(outcome == .success(expected))
        }
        for milliseconds in [-1, 60_001] {
            let refusal = try Fixture.refusal("/fk/v1/param/fader/ramp", [.float32(0), .int32(Int32(milliseconds))])
            #expect(refusal == .rampMillisecondsOutOfRange(milliseconds))
        }
    }

    @Test("A bundle of 1,024 messages arrives as one batch in order and one of 1,025 is malformed at intake")
    func bundleElementBoundaryIs1024And1025Messages() throws {
        func bundle(_ count: Int) throws -> [UInt8] {
            let message = try Fixture.encode("/fk/v1/transport/start")
            let size = [0, 0, 0, UInt8(message.count)]
            let header = Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1]
            return header + (0..<count).flatMap { _ in size + message }
        }
        var pipeline = try Fixture.pipeline()
        let accepted = try Fixture.datagram(&pipeline, try bundle(1_024))
        #expect(accepted == .mapped([CommandOperation](repeating: .start, count: 1_024)))
        let refused = try Fixture.datagram(&pipeline, try bundle(1_025), now: 1)
        #expect(refused == .intake(.malformed(.tooManyElements(limit: 1_024))))
    }

    // MARK: UDP versus TCP

    @Test("The same packet bytes map equally by datagram and by a length-prefixed stream split at every offset")
    func datagramAndLengthPrefixedStreamMapEquallyAtEverySplit() throws {
        let wanted = ["fader", "fader-ramp", "next", "locate"]
        let rows = try Fixture.table().accepted.filter { wanted.contains($0.control) }
        #expect(rows.count == 4)
        for row in rows {
            let packet = try Fixture.encode(row.address, try Fixture.arguments(of: row))
            var udp = try Fixture.pipeline()
            let expected = try Fixture.datagram(&udp, packet)
            let operation = try #require(Fixture.expectedOperations[row.address])
            #expect(expected == .mapped([operation]), "\(row.address)")
            let frame = try Fixture.framed(packet)
            var whole = try Fixture.pipeline(.stream(.lengthPrefixed))
            #expect(try Fixture.chunks(&whole, [frame]) == [expected], "\(row.address) unsplit")
            for offset in 1..<frame.count {
                var tcp = try Fixture.pipeline(.stream(.lengthPrefixed))
                let pieces = [Array(frame[..<offset]), Array(frame[offset...])]
                #expect(try Fixture.chunks(&tcp, pieces) == [expected], "\(row.address) split at \(offset)")
            }
        }
    }

    @Test("A stream of one-byte chunks and a stream of two frames in one chunk map like separate datagrams")
    func byteAtATimeAndCoalescedFramesMapLikeSeparateDatagrams() throws {
        let start = try Fixture.encode("/fk/v1/transport/start")
        let locate = try Fixture.encode("/fk/v1/transport/locate", [.int32(5)])
        let both = try Fixture.framed(start) + Fixture.framed(locate)
        var coalesced = try Fixture.pipeline(.stream(.lengthPrefixed))
        let expected: [TouchOSCDelivery] = [.mapped([.start]), .mapped([.locate(ticks: 5)])]
        #expect(try Fixture.chunks(&coalesced, [both]) == expected)
        var dripped = try Fixture.pipeline(.stream(.lengthPrefixed))
        #expect(try Fixture.chunks(&dripped, both.map { [$0] }) == expected)
    }

    @Test("A datagram pipeline refuses a chunk and a stream pipeline refuses a datagram, wrongTransport")
    func crossingTransportsIsRefusedWrongTransportAndChangesNothing() throws {
        let packet = try Fixture.encode("/fk/v1/transport/start")
        var udp = try Fixture.pipeline()
        let udpBefore = udp
        #expect(try Fixture.chunks(&udp, [packet]) == [.intake(.wrongTransport(expected: .datagram))])
        #expect(udp == udpBefore)
        var tcp = try Fixture.pipeline(.stream(.lengthPrefixed))
        let tcpBefore = tcp
        let refused = try Fixture.datagram(&tcp, packet)
        #expect(refused == .intake(.wrongTransport(expected: .stream(.lengthPrefixed))))
        #expect(tcp == tcpBefore)
    }

    // MARK: Default off

    @Test("A disabled pipeline refuses every packet endpointDisabled, changes nothing and reaches no mapper")
    func aDisabledPipelineRefusesEverythingAndNothingReachesTheMapper() throws {
        let valid = try Fixture.encode("/fk/v1/transport/start")
        let frame = try Fixture.framed(valid)
        var pipeline = OSC.IntakePipeline()
        let fresh = pipeline
        var reached = 0
        for bytes in [valid, Fixture.garbage, [], valid + valid] {
            let result = pipeline.receive(datagram: bytes, from: Fixture.alpha, now: 3)
            if case .success = result { reached += 1 }
            #expect(result == .failure(.endpointDisabled))
        }
        for bytes in [frame, Fixture.garbage, []] {
            let outcome = pipeline.receive(chunk: bytes, from: Fixture.alpha, now: 4)
            if case .consumed = outcome { reached += 1 }
            #expect(outcome == .refused(.endpointDisabled))
        }
        #expect(reached == 0)
        #expect(pipeline == fresh)
        #expect(pipeline.endpoint == .disabled)
    }

    @Test("Enabling lets the same packet through and disabling returns the pipeline to its default value")
    func enablingAdmitsThePacketAndDisablingRestoresTheDefaultPipeline() throws {
        let packet = try Fixture.encode("/fk/v1/transport/stop")
        var pipeline = try Fixture.pipeline()
        #expect(try Fixture.datagram(&pipeline, packet, now: 1) == .mapped([.stop]))
        #expect(pipeline != OSC.IntakePipeline())
        pipeline.disable()
        #expect(pipeline == OSC.IntakePipeline())
        #expect(try Fixture.datagram(&pipeline, packet, now: 2) == .intake(.endpointDisabled))
    }
}
