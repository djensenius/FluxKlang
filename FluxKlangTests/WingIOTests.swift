//
//  WingIOTests.swift
//  FluxKlangTests
//
//  Covers hardware-confirmed physical input connector names. WING output nodes
//  have no name child, so output labels are configured by FluxKlang.
//

import Testing
@testable import FluxKlang

@MainActor
struct WingIOTests {
    @Test func inputNameAddressesFollowTheLocalBank() {
        #expect(WingAddress.inputName(3) == "/io/in/LCL/3/name")
    }

    @Test func bulkRefreshQueriesIONames() {
        let addresses = Set(WingAddress.allQueryAddresses())
        #expect(addresses.contains(WingAddress.inputName(1)))
        #expect(addresses.contains(WingAddress.inputName(WingSourceGroup.local.count)))
    }

    @Test func demoSeedsInputsFromTheGearRig() {
        let store = DemoWingTransport.seededStore()
        // Channel 1 carries the first stereo device's left leg, so input 1 is
        // labelled after it.
        #expect(store[WingAddress.inputName(1)]?.stringValue == "OP-1 Field L")
    }

    @Test func controllerReadsSeededIONames() {
        let controller = WingController.preview()
        #expect(controller.inputName(1) == "OP-1 Field L")
        #expect(controller.inputName(999) == nil)
    }
}
