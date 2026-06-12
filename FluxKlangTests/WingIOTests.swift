//
//  WingIOTests.swift
//  FluxKlangTests
//
//  Covers the (provisional) physical I/O connector-name reading: the address
//  builders, their inclusion in the bulk refresh, and the demo simulator seeding
//  believable names so gear shows up on the inputs and the outputs are labelled
//  offline.
//

import Testing
@testable import FluxKlang

@MainActor
struct WingIOTests {
    @Test func ioNameAddressesFollowTheLocalBank() {
        #expect(WingAddress.inputName(3) == "/io/in/LCL/3/name")
        #expect(WingAddress.outputName(2) == "/io/out/LCL/2/name")
    }

    @Test func bulkRefreshQueriesIONames() {
        let addresses = Set(WingAddress.allQueryAddresses())
        #expect(addresses.contains(WingAddress.inputName(1)))
        #expect(addresses.contains(WingAddress.inputName(WingSourceGroup.local.count)))
        #expect(addresses.contains(WingAddress.outputName(1)))
        #expect(addresses.contains(WingAddress.outputName(WingAddress.localOutputCount)))
    }

    @Test func demoSeedsInputsFromTheGearRig() {
        let store = DemoWingTransport.seededStore()
        // Channel 1 carries the first stereo device's left leg, so input 1 is
        // labelled after it.
        #expect(store[WingAddress.inputName(1)]?.stringValue == "OP-1 Field L")
        #expect(store[WingAddress.outputName(1)]?.stringValue == "Output 1")
    }

    @Test func controllerReadsSeededIONames() {
        let controller = WingController.preview()
        #expect(controller.inputName(1) == "OP-1 Field L")
        #expect(controller.outputName(1) == "Output 1")
        #expect(controller.inputName(999) == nil)
    }
}
