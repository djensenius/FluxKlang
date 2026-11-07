import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Argument counts, types, finiteness and ranges for every operation the namespace can produce.
extension OSCNamespaceTests {
    private static let fader = ParameterCatalog.wingFaderDecibels

    private func decibels(_ value: Double) -> ParameterValue { ParameterValue(value: value, unit: .decibels) }

    private func tag(_ character: Character) -> UInt8 { UInt8(ascii: character.unicodeScalars.first ?? " ") }

    @Test func aFloat32SetKeepsTheCatalogUnit() throws {
        let fader = try Fixture.run("/fk/v1/param/fader", [.float32(-10.5)])
        #expect(fader == .operation(.set(Self.fader, decibels(-10.5))))
        let pan = try Fixture.run("/fk/v1/param/pan", [.float32(0.25)])
        #expect(pan == .operation(.set(ParameterCatalog.wingPan, ParameterValue(value: 0.25, unit: .pan))))
    }

    @Test func anInt32SetWidensExactly() throws {
        let mute = try Fixture.run("/fk/v1/param/mute", [.int32(1)])
        #expect(mute == .operation(.set(ParameterCatalog.wingMute, ParameterValue(value: 1, unit: .boolean))))
        #expect(try Fixture.run("/fk/v1/param/fader", [.int32(.max)]) == .operation(.set(Self.fader,
            decibels(2_147_483_647))))
        #expect(try Fixture.run("/fk/v1/param/fader", [.int32(.min)]) == .operation(.set(Self.fader,
            decibels(-2_147_483_648))))
    }

    @Test func aSetValueIsNeitherClampedNorRounded() throws {
        #expect(try Fixture.run("/fk/v1/param/fader", [.float32(1e9)]) == .operation(.set(Self.fader, decibels(1e9))))
        let tiny = try Fixture.run("/fk/v1/param/mute", [.float32(0.7)])
        #expect(tiny == .operation(.set(ParameterCatalog.wingMute, ParameterValue(value: Double(Float(0.7)),
            unit: .boolean))))
    }

    @Test func negativeZeroAndSubnormalFloatsKeepTheirBitPattern() throws {
        for value in [Float(-0.0), Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude,
            Float.leastNormalMagnitude] {
            guard case .operation(.set(_, let mapped)) = try Fixture.run("/fk/v1/param/fader", [.float32(value)]) else {
                Issue.record("expected an operation for \(value)")
                continue
            }
            #expect(mapped.value.bitPattern == Double(value).bitPattern)
        }
        #expect(Double(Float(-0.0)).bitPattern == (-0.0).bitPattern)
    }

    @Test func nonFiniteSetValuesAreRefused() throws {
        for value in [Float.nan, Float.infinity, -Float.infinity, Float.signalingNaN] {
            #expect(try Fixture.run("/fk/v1/param/fader", [.float32(value)]) == .refused(.nonFiniteValue(index: 0)))
        }
        #expect(try Fixture.run("/fk/v1/param/fader", [.float32(Float.greatestFiniteMagnitude)]) !=
            .refused(.nonFiniteValue(index: 0)))
    }

    @Test func setNeedsExactlyOneArgument() throws {
        try Fixture.expectRefusals([("/fk/v1/param/fader", .wrongArgumentCount(minimum: 1, maximum: 1, got: 0))])
        let two: [OSC.Argument] = [.float32(1), .float32(2)]
        try Fixture.expectRefusals([("/fk/v1/param/fader", .wrongArgumentCount(minimum: 1, maximum: 1, got: 2))], two)
        try Fixture.expectRefusals([("/fk/v1/param/fader", .wrongArgumentCount(minimum: 1, maximum: 1, got: 3))],
            two + [.int32(3)])
    }

    @Test func setRefusesEveryNonNumberTypeWithItsTag() throws {
        let cases: [(OSC.Argument, Character)] = [
            (.float64(1), "d"), (.int64(1), "h"), (.string("a"), "s"), (.blob([1]), "b"), (.timeTag(.immediate), "t"),
            (.true, "T"), (.false, "F"), (.nil, "N"), (.impulse, "I")
        ]
        for (argument, character) in cases {
            let outcome = try Fixture.run("/fk/v1/param/fader", [argument])
            #expect(outcome == .refused(.unsupportedArgument(index: 0, typeTag: tag(character))), "\(character)")
        }
    }

    @Test func aRampMapsValueAndMilliseconds() throws {
        let slow = try Fixture.run("/fk/v1/param/fader/ramp", [.float32(-3), .int32(0)])
        #expect(slow == .operation(.ramp(Self.fader, decibels(-3), milliseconds: 0)))
        let top = try Fixture.run("/fk/v1/param/fader/ramp", [.int32(4), .int32(60_000)])
        #expect(top == .operation(.ramp(Self.fader, decibels(4), milliseconds: 60_000)))
        let mid = try Fixture.run("/fk/v1/param/mute/ramp", [.float32(1), .int32(250)])
        #expect(mid == .operation(.ramp(ParameterCatalog.wingMute, ParameterValue(value: 1, unit: .boolean),
            milliseconds: 250)))
    }

    @Test func rampMillisecondsOutsideZeroTo60000AreRefused() throws {
        for milliseconds: Int32 in [-1, 60_001, .min, .max] {
            let outcome = try Fixture.run("/fk/v1/param/fader/ramp", [.float32(0), .int32(milliseconds)])
            #expect(outcome == .refused(.rampMillisecondsOutOfRange(Int(milliseconds))), "\(milliseconds)")
        }
        let edge = try Fixture.run("/fk/v1/param/fader/ramp", [.float32(0), .int32(59_999)])
        #expect(edge == .operation(.ramp(Self.fader, decibels(0), milliseconds: 59_999)))
    }

    @Test func rampNeedsExactlyTwoArguments() throws {
        let path = "/fk/v1/param/fader/ramp"
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 2, maximum: 2, got: 0))])
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 2, maximum: 2, got: 1))], [.float32(1)])
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 2, maximum: 2, got: 3))], [.float32(1),
            .int32(1),
            .int32(1)])
    }

    @Test func rampMillisecondsMustBeAnInt32() throws {
        let path = "/fk/v1/param/fader/ramp"
        let float = try Fixture.run(path, [.float32(0.5), .float32(100)])
        #expect(float == .refused(.unsupportedArgument(index: 1, typeTag: UInt8(ascii: "f"))))
        let wide = try Fixture.run(path, [.float32(0.5), .int64(100)])
        #expect(wide == .refused(.unsupportedArgument(index: 1, typeTag: UInt8(ascii: "h"))))
        let text = try Fixture.run(path, [.float32(0.5), .string("100")])
        #expect(text == .refused(.unsupportedArgument(index: 1, typeTag: UInt8(ascii: "s"))))
    }

    @Test func aRampValueMustBeANumberAndFinite() throws {
        let path = "/fk/v1/param/fader/ramp"
        let wrong = try Fixture.run(path, [.string("x"), .int32(10)])
        #expect(wrong == .refused(.unsupportedArgument(index: 0, typeTag: UInt8(ascii: "s"))))
        #expect(try Fixture.run(path, [.float32(.nan), .int32(10)]) == .refused(.nonFiniteValue(index: 0)))
        #expect(try Fixture.run(path, [.float32(.infinity), .int32(10)]) == .refused(.nonFiniteValue(index: 0)))
    }

    @Test func aTriggerTakesNoArgumentOrOneImpulse() throws {
        #expect(try Fixture.run("/fk/v1/action/go") == .operation(.trigger(Fixture.goID)))
        #expect(try Fixture.run("/fk/v1/action/go", [.impulse]) == .operation(.trigger(Fixture.goID)))
    }

    @Test func aTriggerRefusesAButtonValueOfAnyOtherType() throws {
        let cases: [(OSC.Argument, Character)] = [
            (.int32(1), "i"), (.int32(0), "i"), (.float32(1), "f"), (.true, "T"), (.false, "F"), (.nil, "N"),
            (.string("go"), "s"), (.int64(1), "h")
        ]
        for (argument, character) in cases {
            let outcome = try Fixture.run("/fk/v1/action/go", [argument])
            #expect(outcome == .refused(.unsupportedArgument(index: 0, typeTag: tag(character))), "\(character)")
        }
    }

    @Test func aTriggerWithTwoOrMoreArgumentsIsACountRefusal() throws {
        let path = "/fk/v1/action/go"
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 0, maximum: 1, got: 2))], [.impulse, .impulse])
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 0, maximum: 1, got: 2))], [.int32(1), .impulse])
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 0, maximum: 1, got: 3))], [.impulse, .impulse,
            .impulse])
    }

    @Test func startAndStopTakeNoArguments() throws {
        #expect(try Fixture.run("/fk/v1/transport/start") == .operation(.start))
        #expect(try Fixture.run("/fk/v1/transport/stop") == .operation(.stop))
        for path in ["/fk/v1/transport/start", "/fk/v1/transport/stop"] {
            try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 0, maximum: 0, got: 1))], [.impulse])
            try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 0, maximum: 0, got: 1))], [.int32(0)])
            try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 0, maximum: 0, got: 2))], [.impulse,
                .impulse])
        }
    }

    @Test func locateWidensInt32AndInt64ToTicks() throws {
        let path = "/fk/v1/transport/locate"
        #expect(try Fixture.run(path, [.int32(0)]) == .operation(.locate(ticks: 0)))
        #expect(try Fixture.run(path, [.int32(1)]) == .operation(.locate(ticks: 1)))
        #expect(try Fixture.run(path, [.int32(.max)]) == .operation(.locate(ticks: 2_147_483_647)))
        #expect(try Fixture.run(path, [.int64(0)]) == .operation(.locate(ticks: 0)))
        #expect(try Fixture.run(path, [.int64(.max)]) == .operation(.locate(ticks: Int64.max)))
        #expect(try Fixture.run(path, [.int64(2_147_483_648)]) == .operation(.locate(ticks: 2_147_483_648)))
    }

    @Test func negativeLocateTicksAreRefused() throws {
        let path = "/fk/v1/transport/locate"
        for argument: OSC.Argument in [.int32(-1), .int32(.min), .int64(-1), .int64(.min)] {
            #expect(try Fixture.run(path, [argument]) == .refused(.negativeTicks), "\(argument)")
        }
    }

    @Test func locateNeedsExactlyOneIntegerArgument() throws {
        let path = "/fk/v1/transport/locate"
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 1, maximum: 1, got: 0))])
        try Fixture.expectRefusals([(path, .wrongArgumentCount(minimum: 1, maximum: 1, got: 2))], [.int32(1),
            .int32(2)])
        let cases: [(OSC.Argument, Character)] = [
            (.float32(1), "f"), (.float64(1), "d"), (.string("1"), "s"), (.true, "T"), (.impulse, "I")
        ]
        for (argument, character) in cases {
            let outcome = try Fixture.run(path, [argument])
            #expect(outcome == .refused(.unsupportedArgument(index: 0, typeTag: tag(character))), "\(character)")
        }
    }

    @Test func aRampOfMinusOneMillisecondIsRefused() throws {
        let outcome = try Fixture.run("/fk/v1/param/fader/ramp", [.float32(0), .int32(-1)])
        #expect(outcome == .refused(.rampMillisecondsOutOfRange(-1)))
    }

    @Test func aCountRefusalReportsTheBoundsAndTheNumberOfArgumentsReceived() throws {
        let received: [OSC.Argument] = [.impulse, .impulse, .impulse, .impulse]
        try Fixture.expectRefusals([
            ("/fk/v1/transport/stop", .wrongArgumentCount(minimum: 0, maximum: 0, got: 4)),
            ("/fk/v1/param/fader/ramp", .wrongArgumentCount(minimum: 2, maximum: 2, got: 4))
        ], received)
    }
}
