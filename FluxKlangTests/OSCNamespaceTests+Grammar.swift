import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Address bounds, namespace prefix, byte-exact case rules and wildcard refusal.
extension OSCNamespaceTests {
    @Test func limitsAreTheRulingLiterals() {
        #expect(OSC.NamespaceLimits.maximumAddressBytes == 256)
        #expect(OSC.NamespaceLimits.maximumSegments == 6)
        #expect(OSC.NamespaceLimits.maximumSegmentBytes == 32)
        #expect(OSC.NamespaceLimits.maximumRoutes == 128)
        #expect(OSC.NamespaceLimits.maximumBatchMessages == 1_024)
        #expect(OSC.NamespaceLimits.maximumRampMilliseconds == 60_000)
        #expect(OSC.NamespaceLimits.namespaceSegments == [Array("fk".utf8), Array("v1".utf8)])
    }

    @Test func addressOf256BytesPassesTheLengthCheck() throws {
        let address = "/" + Fixture.repeated("a", 255)
        #expect(address.utf8.count == 256)
        #expect(try Fixture.run(address) == .refused(.segmentTooLong(index: 0, byteCount: 255, limit: 32)))
    }

    @Test func addressOf257BytesIsRefusedAsTooLong() throws {
        let address = "/" + Fixture.repeated("a", 256)
        #expect(address.utf8.count == 257)
        #expect(try Fixture.run(address) == .refused(.addressTooLong(byteCount: 257, limit: 256)))
    }

    @Test func sixSegmentsPassTheCountCheck() throws {
        #expect(try Fixture.run("/fk/v1/param/fader/ramp/extra") == .refused(.unknownRoute(segmentCount: 6)))
    }

    @Test func sevenSegmentsAreRefused() throws {
        #expect(try Fixture.run("/fk/v1/param/fader/ramp/extra/more") == .refused(.tooManySegments(count: 7, limit: 6)))
    }

    @Test func segmentOf32BytesPassesTheSegmentLengthCheck() throws {
        let address = "/fk/v1/param/" + Fixture.repeated("a", 32)
        #expect(try Fixture.run(address) == .refused(.unknownRoute(segmentCount: 4)))
    }

    @Test func segmentOf33BytesIsRefusedWithItsIndex() throws {
        let address = "/fk/v1/param/" + Fixture.repeated("a", 33)
        #expect(try Fixture.run(address) == .refused(.segmentTooLong(index: 3, byteCount: 33, limit: 32)))
    }

    @Test func theLowestTooLongSegmentIsReported() throws {
        let long = Fixture.repeated("a", 33), longer = Fixture.repeated("b", 34)
        try Fixture.expectRefusals([
            ("/fk/v1/\(long)/\(longer)", .segmentTooLong(index: 2, byteCount: 33, limit: 32)),
            ("/fk/v1/param/\(longer)/\(long)", .segmentTooLong(index: 3, byteCount: 34, limit: 32)),
            ("/\(long)/v1/\(longer)", .segmentTooLong(index: 0, byteCount: 33, limit: 32)),
            ("/fk/\(longer)/param/\(long)", .segmentTooLong(index: 1, byteCount: 34, limit: 32))
        ])
    }

    @Test func aTwoSegmentAddressIsMissingTheFamily() throws {
        try Fixture.expectRefusals([("/fk/v1", .missingFamily)])
    }

    @Test func addressesOutsideTheNamespaceAreRefusedWithTheirSegmentCount() throws {
        try Fixture.expectRefusals([
            ("/fk", .outsideNamespace(segmentCount: 1)), ("/a", .outsideNamespace(segmentCount: 1)),
            ("/other/v1/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/fk/v2/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/v1/fk/param/fader", .outsideNamespace(segmentCount: 4))
        ])
    }

    @Test func theNamespacePrefixIsAWholeSegmentMatch() throws {
        try Fixture.expectRefusals([
            ("/fk/v10/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/fk/v1x", .outsideNamespace(segmentCount: 2)),
            ("/fkx/v1/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/f/v1/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/fk/v/param/fader", .outsideNamespace(segmentCount: 4))
        ])
    }

    @Test func theNamespacePrefixIsCaseSensitive() throws {
        try Fixture.expectRefusals([
            ("/FK/v1/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/fk/V1/param/fader", .outsideNamespace(segmentCount: 4)),
            ("/Fk/v1/param/fader", .outsideNamespace(segmentCount: 4))
        ])
    }

    @Test func nameSegmentsAreCaseSensitive() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/Param/fader", .invalidSegment(index: 2, byteOffset: 0)),
            ("/fk/v1/param/Fader", .invalidSegment(index: 3, byteOffset: 0)),
            ("/fk/v1/param/fader/Ramp", .invalidSegment(index: 4, byteOffset: 0)),
            ("/fk/v1/param/faDer", .invalidSegment(index: 3, byteOffset: 2))
        ])
    }

    @Test func invalidSegmentBytesReportTheExactOffset() throws {
        try Fixture.expectRefusals([
            ("/fk/v1/param/fa.der", .invalidSegment(index: 3, byteOffset: 2)),
            ("/fk/v1/param/fa:der", .invalidSegment(index: 3, byteOffset: 2)),
            ("/fk/v1/param/fader/ra.p", .invalidSegment(index: 4, byteOffset: 2)),
            ("/fk/v1/transport/start!", .invalidSegment(index: 3, byteOffset: 5)),
            ("/fk/v1/Param/Fader", .invalidSegment(index: 2, byteOffset: 0))
        ])
    }

    @Test func nameBytesAreExactlyLowercaseDigitsUnderscoreAndHyphen() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-".utf8)
        for byte in UInt8.min...UInt8.max {
            #expect(OSC.NamespaceLimits.isNameByte(byte) == allowed.contains(byte), "byte \(byte)")
        }
        #expect(allowed.count == 38)
    }

    @Test func anEmptySegmentIsInvalidAtOffsetZero() {
        #expect(OSC.ControlMapper.invalidByteOffset(in: []) == 0)
        #expect(OSC.ControlMapper.invalidByteOffset(in: Array("ab".utf8)) == nil)
        #expect(OSC.ControlMapper.invalidByteOffset(in: Array("aB".utf8)) == 1)
        #expect(OSC.ControlMapper.invalidByteOffset(in: [0x61, 0xC3, 0xA9]) == 1)
    }

    @Test func everyWildcardFormIsRefusedBeforeAnyNamespaceCheck() throws {
        let patterns = [
            "/fk/v1/param/{fader,mute}", "/fk/v1/param/*", "/fk/v1/param/fad?r", "/fk/v1/param/[a-z]ader",
            "/*/v1/param/fader", "/fk/*/param/fader", "/fk/v1/*/fader", "/other/*", "/fk/v1/route/*",
            "/{fk,x}/v1/param/fader/ramp/extra/more/more"
        ]
        try Fixture.expectRefusals(patterns.map { ($0, OSC.NamespaceRefusal.wildcardAddress) })
    }

    @Test func aWildcardInAnOutsideNamespaceAddressIsAWildcardRefusal() throws {
        try Fixture.expectRefusals([("/other/[a-z]", .wildcardAddress), ("/fk", .outsideNamespace(segmentCount: 1))])
    }

    @Test func addressesWithIdenticalBytesMapIdentically() throws {
        let text = try OSC.AddressPattern("/fk/v1/param/fader")
        let raw = try OSC.AddressPattern(bytes: Array("/fk/v1/param/fader".utf8), limits: .standard)
        let mapper = try Fixture.mapper()
        let first = try mapper.map(OSC.Message(address: text, arguments: [.float32(1)]))
        let second = try mapper.map(OSC.Message(address: raw, arguments: [.float32(1)]))
        #expect(first == second)
        #expect(first == .set(ParameterCatalog.wingFaderDecibels, ParameterValue(value: 1, unit: .decibels)))
    }
}
