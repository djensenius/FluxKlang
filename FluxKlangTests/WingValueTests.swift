//
//  WingValueTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct WingValueTests {
    @Test func exposesTypedAccessors() {
        #expect(WingValue.float(0.25).floatValue == 0.25)
        #expect(WingValue.int(1).intValue == 1)
        #expect(WingValue.string("x").stringValue == "x")
        #expect(WingValue.float(0.25).intValue == nil)
        #expect(WingValue.int(1).stringValue == nil)
        #expect(WingValue.string("x").floatValue == nil)
    }

    @Test func equatableComparesCaseAndPayload() {
        #expect(WingValue.float(0.5) == .float(0.5))
        #expect(WingValue.float(0.5) != .float(0.6))
        #expect(WingValue.int(1) != .string("1"))
    }

    @Test func resolvesHardwareFaderReplyToNormalizedPosition() {
        let value = WingReplyResolver.resolve(
            address: "/ch/1/fdr",
            values: [.string("-oo"), .float(0), .float(-144)]
        )
        #expect(value == .float(0))
    }

    @Test func resolvesHardwareEngineeringFloatReplies() {
        #expect(WingReplyResolver.resolve(
            address: "/ch/1/pan",
            values: [.string("0"), .float(0.5), .float(0)]
        ) == .float(0))
        #expect(WingReplyResolver.resolve(
            address: "/ch/1/main/1/lvl",
            values: [.string("0.0"), .float(0.75), .float(0)]
        ) == .float(0))
    }

    @Test func resolvesHardwareIntegerReplyToActualValue() {
        let value = WingReplyResolver.resolve(
            address: "/ch/1/mute",
            values: [.string("0"), .float(0), .int(0)]
        )
        #expect(value == .int(0))
    }

    @Test func resolvesHardwareSourceIndexToOneBasedDisplayValue() {
        #expect(WingReplyResolver.resolve(
            address: "/ch/1/in/conn/in",
            values: [.string("23"), .float(0.349_206_36), .int(22)]
        ) == .int(23))
        #expect(WingReplyResolver.resolve(
            address: "/io/out/LCL/1/in",
            values: [.string("1"), .float(0), .int(0)]
        ) == .int(1))
    }

    @Test func preservesSingleValueEchoes() {
        #expect(WingReplyResolver.resolve(address: "/ch/1/fdr", values: [.float(0.75)]) == .float(0.75))
    }
}
