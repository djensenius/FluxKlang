//
//  WingDiscoveryTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct WingDiscoveryTests {
    @Test func recognisesInfoReplyAddresses() {
        #expect(WingDiscoveryParser.isInfoReply("/?"))
        #expect(WingDiscoveryParser.isInfoReply("/*"))
        #expect(WingDiscoveryParser.isInfoReply("/info"))
        #expect(WingDiscoveryParser.isInfoReply("/xinfo"))
        #expect(!WingDiscoveryParser.isInfoReply("/ch/1/fdr"))
    }

    @Test func parsesNameAndModelFromReply() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/?",
            arguments: [.string("V3.0.0"), .string("Studio WING"), .string("WING Rack"), .string("1.16")],
            host: "192.168.1.40"
        )
        #expect(wing?.host == "192.168.1.40")
        #expect(wing?.name == "Studio WING")
        #expect(wing?.model == "WING Rack")
        #expect(wing?.firmware == "1.16")
    }

    @Test func parsesHardwareCSVIdentityReply() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/*",
            arguments: [
                .string("WING,192.168.11.221,WING-PP-07111644,wing-rack,0100QL80604AAE,3.1-0-g9f314617:release")
            ],
            host: "192.168.11.221"
        )

        #expect(wing?.host == "192.168.11.221")
        #expect(wing?.name == "WING-PP-07111644")
        #expect(wing?.model == "WING Rack")
        #expect(wing?.identifier == "0100QL80604AAE")
        #expect(wing?.firmware == "3.1-0-g9f314617:release")
    }

    @Test func fallsBackToHostWhenNoName() {
        let wing = WingDiscoveryParser.wing(fromReplyAt: "/info", arguments: [], host: "10.0.0.5")
        #expect(wing?.name == "10.0.0.5")
        #expect(wing?.model == nil)
    }

    @Test func nonWingCommaPayloadFallsBackToLegacyParsing() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/info",
            arguments: [.string("Legacy Console, Studio A")],
            host: "10.0.0.6"
        )

        #expect(wing?.host == "10.0.0.6")
        #expect(wing?.name == "Legacy Console, Studio A")
    }

    @Test func ignoresNonInfoReplies() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/ch/1/fdr",
            arguments: [.float(0.75)],
            host: "10.0.0.5"
        )
        #expect(wing == nil)
    }
}
