import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Order of the mapper checks, refused families, route lookup and the all-or-nothing batch.
extension OSCNamespaceTests {
    private func refusal(_ address: String, _ arguments: [OSC.Argument] = []) throws -> Outcome {
        try Fixture.run(address, arguments)
    }

    @Test func aTooLongAddressBeatsAWildcard() throws {
        let address = "/" + Fixture.repeated("a", 256) + "*"
        #expect(try refusal(address) == .refused(.addressTooLong(byteCount: 258, limit: 256)))
    }

    @Test func aWildcardBeatsTheSegmentCount() throws {
        #expect(try refusal("/fk/v1/param/fader/ramp/extra/*") == .refused(.wildcardAddress))
    }

    @Test func theSegmentCountBeatsTheSegmentLength() throws {
        let address = "/fk/v1/param/\(Fixture.repeated("a", 33))/ramp/extra/more"
        #expect(try refusal(address) == .refused(.tooManySegments(count: 7, limit: 6)))
    }

    @Test func theSegmentLengthBeatsTheNamespaceCheck() throws {
        let long = Fixture.repeated("a", 33)
        try Fixture.expectRefusals([
            ("/other/\(long)", .segmentTooLong(index: 1, byteCount: 33, limit: 32)),
            ("/\(long)", .segmentTooLong(index: 0, byteCount: 33, limit: 32))
        ])
    }

    @Test func theNamespaceCheckBeatsAMissingFamilyAndAnInvalidSegment() throws {
        try Fixture.expectRefusals([
            ("/fk/v2", .outsideNamespace(segmentCount: 2)),
            ("/other/v1/Param/X", .outsideNamespace(segmentCount: 4)),
            ("/FK/v1/Param/X", .outsideNamespace(segmentCount: 4))
        ])
    }

    @Test func anInvalidSegmentBeatsARefusedFamilyAndAnUnknownFamily() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/route/Bad", .invalidSegment(index: 3, byteOffset: 0)),
            ("/fk/v1/Route/x", .invalidSegment(index: 2, byteOffset: 0)),
            ("/fk/v1/route/x.y", .invalidSegment(index: 3, byteOffset: 1)),
            ("/fk/v1/safety/safe.mute", .invalidSegment(index: 3, byteOffset: 4)),
            ("/fk/v1/nothing/Bad", .invalidSegment(index: 3, byteOffset: 0))
        ])
    }

    @Test func aRefusedFamilyBeatsAnUnknownRouteAndABadArgument() throws {
        let bad: [OSC.Argument] = [.string("x"), .float32(.nan), .blob([])]
        try Fixture.expectRefusals([("/fk/v1/safety/panic", .refusedFamily(.safety))], bad)
        try Fixture.expectRefusals([("/fk/v1/route", .refusedFamily(.route)), ("/fk/v1/hazard/x/y/z",
            .refusedFamily(.hazard))])
    }

    @Test func anUnknownRouteBeatsBadArguments() throws {
        let bad: [OSC.Argument] = [.string("x"), .string("y"), .string("z")]
        try Fixture.expectRefusals([
            ("/fk/v1/param/nope", .unknownRoute(segmentCount: 4)),
            ("/fk/v1/param/fader/slide", .unknownRoute(segmentCount: 5))
        ], bad)
    }

    @Test func theArgumentCountBeatsTheirTypes() throws {
        let outcome = try refusal("/fk/v1/param/fader", [.string("a"), .string("b")])
        #expect(outcome == .refused(.wrongArgumentCount(minimum: 1, maximum: 1, got: 2)))
    }

    @Test func argumentTypesBeatFinitenessAndRanges() throws {
        let path = "/fk/v1/param/fader/ramp"
        #expect(try refusal(path, [.float32(.nan), .string("x")]) == .refused(.unsupportedArgument(index: 1,
            typeTag: UInt8(ascii: "s"))))
        #expect(try refusal(path, [.float32(.nan), .float32(5)]) == .refused(.unsupportedArgument(index: 1,
            typeTag: UInt8(ascii: "f"))))
        #expect(try refusal(path, [.float32(0), .float32(-1)]) == .refused(.unsupportedArgument(index: 1,
            typeTag: UInt8(ascii: "f"))))
        #expect(try refusal(path, [.string("a"), .string("b")]) == .refused(.unsupportedArgument(index: 0,
            typeTag: UInt8(ascii: "s"))))
    }

    @Test func finitenessBeatsTheMillisecondRange() throws {
        let outcome = try refusal("/fk/v1/param/fader/ramp", [.float32(.infinity), .int32(-1)])
        #expect(outcome == .refused(.nonFiniteValue(index: 0)))
    }

    @Test func everyRefusedFamilyIsRefusedByNameWhateverFollows() throws {
        let expected: [(String, OSC.RefusedFamily)] = [
            ("route/x", .route), ("patch/x", .patch), ("draft/x", .draft), ("safety/panic", .safety),
            ("safety/safe-mute", .safety), ("hazard/x", .hazard)
        ]
        let shapes: [[OSC.Argument]] = [[], [.impulse], [.float32(1)], [.int32(1), .int32(2)], [.string("x")]]
        for (tail, family) in expected {
            for suffix in ["", "/y", "/y/z"] {
                for arguments in shapes {
                    let outcome = try Fixture.run("/fk/v1/\(tail)\(suffix)", arguments)
                    #expect(outcome == .refused(.refusedFamily(family)), "\(tail)\(suffix)")
                }
            }
        }
    }

    @Test func aRefusedFamilyWithSevenSegmentsIsStillTooManySegments() throws {
        try Fixture.expectRefusals([("/fk/v1/route/x/y/z/w", .tooManySegments(count: 7, limit: 6))])
    }

    @Test func unlistedFamiliesAreUnknown() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/panic", .unknownFamily), ("/fk/v1/bind/x", .unknownFamily), ("/fk/v1/params/x", .unknownFamily),
            ("/fk/v1/routes/x", .unknownFamily), ("/fk/v1/rout/x", .unknownFamily), ("/fk/v1/recall/x", .unknownFamily),
            ("/fk/v1/transports/start", .unknownFamily), ("/fk/v1/a", .unknownFamily)
        ])
    }

    @Test func unknownRoutesCarryTheExactSegmentCount() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/param", .unknownRoute(segmentCount: 3)), ("/fk/v1/action", .unknownRoute(segmentCount: 3)),
            ("/fk/v1/transport", .unknownRoute(segmentCount: 3)), ("/fk/v1/param/nope", .unknownRoute(segmentCount: 4)),
            ("/fk/v1/action/nope", .unknownRoute(segmentCount: 4)), ("/fk/v1/transport/pause",
                .unknownRoute(segmentCount: 4)),
            ("/fk/v1/param/fader/slide", .unknownRoute(segmentCount: 5)),
            ("/fk/v1/param/fader/ramp/extra", .unknownRoute(segmentCount: 6)),
            ("/fk/v1/action/go/x", .unknownRoute(segmentCount: 5)),
            ("/fk/v1/transport/start/x", .unknownRoute(segmentCount: 5)),
            ("/fk/v1/param/go", .unknownRoute(segmentCount: 4)), ("/fk/v1/action/fader", .unknownRoute(segmentCount: 4))
        ], [.float32(1), .int32(1)])
    }

    @Test func aDisabledTransportVerbIsAnUnknownRoute() throws {
        let mapper = OSC.ControlMapper(table: try Fixture.table(transport: [.start]))
        #expect(try Fixture.run("/fk/v1/transport/start", mapper: mapper) == .operation(.start))
        try Fixture.expectRefusals([
            ("/fk/v1/transport/stop", .unknownRoute(segmentCount: 4)),
            ("/fk/v1/transport/locate", .unknownRoute(segmentCount: 4))
        ], [.int32(1)], mapper: mapper)
        let none = OSC.ControlMapper(table: try Fixture.table(transport: []))
        try Fixture.expectRefusals([("/fk/v1/transport/start", .unknownRoute(segmentCount: 4))], mapper: none)
    }

    @Test func theTableOwnsTheNamesIncludingTheWordRamp() throws {
        let routes = [OSC.ParameterRoute(name: "ramp", id: ParameterCatalog.wingPan)]
        let mapper = OSC.ControlMapper(table: try Fixture.table(parameters: routes))
        let pan = ParameterValue(value: 0.5, unit: .pan)
        #expect(try Fixture.run("/fk/v1/param/ramp", [.float32(0.5)], mapper: mapper) ==
            .operation(.set(ParameterCatalog.wingPan, pan)))
        let ramped = try Fixture.run("/fk/v1/param/ramp/ramp", [.float32(0.5), .int32(3)], mapper: mapper)
        #expect(ramped == .operation(.ramp(ParameterCatalog.wingPan, pan, milliseconds: 3)))
        try Fixture.expectRefusals([("/fk/v1/param/fader", .unknownRoute(segmentCount: 4))], [.float32(1)],
            mapper: mapper)
    }

    @Test func aBatchOf1024MessagesMapsInInputOrder() throws {
        let mapper = try Fixture.mapper()
        let starts = try Array(repeating: Fixture.message("/fk/v1/transport/start"), count: 1_023)
        let batch = starts + [try Fixture.message("/fk/v1/transport/locate", [.int32(5)])]
        let operations = try mapper.map(batch: batch)
        #expect(operations.count == 1_024)
        #expect(operations.dropLast().allSatisfy { $0 == .start })
        #expect(operations.last == .locate(ticks: 5))
    }

    @Test func aBatchOf1025MessagesIsRefusedBeforeAnyMessageIsRead() throws {
        let mapper = try Fixture.mapper()
        let bad = try Fixture.message("/other")
        let batch = Array(repeating: bad, count: 1_025)
        #expect(throws: OSC.NamespaceBatchRefusal.tooManyMessages(count: 1_025, limit: 1_024)) {
            try mapper.map(batch: batch)
        }
    }

    @Test func aBatchReportsTheFirstFailureByIndex() throws {
        let mapper = try Fixture.mapper()
        let good = try Fixture.message("/fk/v1/transport/start")
        let outside = try Fixture.message("/other")
        let nonFinite = try Fixture.message("/fk/v1/param/fader", [.float32(.nan)])
        let unknown = try Fixture.message("/fk/v1/param/nope", [.float32(1)])
        #expect(throws: OSC.NamespaceBatchRefusal.message(index: 0, refusal: .outsideNamespace(segmentCount: 1))) {
            try mapper.map(batch: [outside, good, good])
        }
        #expect(throws: OSC.NamespaceBatchRefusal.message(index: 2, refusal: .nonFiniteValue(index: 0))) {
            try mapper.map(batch: [good, good, nonFinite, unknown, outside])
        }
        #expect(throws: OSC.NamespaceBatchRefusal.message(index: 3, refusal: .unknownRoute(segmentCount: 4))) {
            try mapper.map(batch: [good, good, good, unknown])
        }
    }

    @Test func anEmptyBatchMapsToNothing() throws {
        #expect(try Fixture.mapper().map(batch: []) == [])
    }

    @Test func aRefusedBatchReturnsNoPartialResultAndChangesNothing() throws {
        let mapper = try Fixture.mapper()
        let before = mapper
        let batch = try [Fixture.message("/fk/v1/transport/start"), Fixture.message("/fk/v1/transport/stop"),
            Fixture.message("/fk")]
        let copy = batch
        var operations: [CommandOperation] = []
        do { operations = try mapper.map(batch: batch) } catch { #expect(error == .message(index: 2,
            refusal: .outsideNamespace(segmentCount: 1))) }
        #expect(operations.isEmpty && batch == copy && mapper == before)
        #expect(try mapper.map(batch: Array(batch.prefix(2))) == [.start, .stop])
    }

    @Test func theSameMessageMapsIdenticallyOnEveryCallAndEveryEqualMapper() throws {
        let first = try Fixture.mapper()
        let second = try Fixture.mapper()
        let permuted = OSC.ControlMapper(table: try Fixture.table(
            parameters: Array(Fixture.parameterRoutes().reversed()), transport: [.locate, .stop, .start]
        ))
        let messages = try [
            Fixture.message("/fk/v1/param/fader", [.float32(-6)]), Fixture.message("/fk/v1/param/pan/ramp",
                [.float32(0),
                .int32(9)]),
            Fixture.message("/fk/v1/action/go"), Fixture.message("/fk/v1/transport/locate", [.int64(4)]),
            Fixture.message("/fk/v1/transport/start", [.impulse]), Fixture.message("/fk/v1/route/x"),
                Fixture.message("/fk/v1/param/nope")
        ]
        #expect(first == second && first == permuted)
        for message in messages {
            let expected = Fixture.attempt(first, message)
            for _ in 0..<3 { #expect(Fixture.attempt(first, message) == expected) }
            #expect(Fixture.attempt(second, message) == expected && Fixture.attempt(permuted, message) == expected)
        }
    }

    @Test func everyRefusalLeavesTheMessageAndTheMapperUnchanged() throws {
        let refusing: [(String, [OSC.Argument])] = [
            ("/other", []), ("/fk/v1", []), ("/fk/v1/param/*", []), ("/fk/v1/route/x", [.impulse]),
            ("/fk/v1/param/nope", []), ("/fk/v1/param/fader", []), ("/fk/v1/param/fader", [.float32(.nan)]),
            ("/fk/v1/param/fader/ramp", [.float32(1), .int32(-1)]), ("/fk/v1/transport/locate", [.int32(-1)]),
            ("/fk/v1/action/go", [.int32(1)]), ("/fk/v1/param/Fader", [.float32(1)])
        ]
        let mapper = try Fixture.mapper()
        for (address, arguments) in refusing {
            let message = try Fixture.message(address, arguments)
            let copy = message
            let mapperCopy = mapper
            let outcome = Fixture.attempt(mapper, message)
            guard case .refused = outcome else {
                Issue.record("expected a refusal for \(address)")
                continue
            }
            #expect(message == copy && mapper == mapperCopy, "\(address)")
            let stop = try Fixture.message("/fk/v1/transport/stop")
            #expect(Fixture.attempt(mapper, message) == outcome)
            #expect(Fixture.attempt(mapper, stop) == .operation(.stop))
        }
    }
}
