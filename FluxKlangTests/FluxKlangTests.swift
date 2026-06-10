//
//  FluxKlangTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct FluxKlangTests {
    @Test func bootstrapAddressIsPing() {
        #expect(OSCProbe.bootstrapAddress == "/ping")
    }
}
