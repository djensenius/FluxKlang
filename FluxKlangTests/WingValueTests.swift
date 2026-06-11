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
}
