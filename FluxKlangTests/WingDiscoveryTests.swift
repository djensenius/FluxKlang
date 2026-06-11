//
//  WingDiscoveryTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct WingDiscoveryTests {
    @Test func recognisesInfoReplyAddresses() {
        #expect(WingDiscoveryParser.isInfoReply("/?"))
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
    }

    @Test func fallsBackToHostWhenNoName() {
        let wing = WingDiscoveryParser.wing(fromReplyAt: "/info", arguments: [], host: "10.0.0.5")
        #expect(wing?.name == "10.0.0.5")
        #expect(wing?.model == nil)
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
