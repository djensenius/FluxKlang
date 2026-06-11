//
//  WingNamingTests.swift
//  FluxKlangTests
//
//  Covers writing scribble-strip names and colours back to the console: the
//  controller sends the right address/value and the Demo simulator echoes the
//  change into the cache so the UI updates offline.
//

import Testing
@testable import FluxKlang

@MainActor
struct WingNamingTests {
    @Test func sanitizesNameByTrimmingAndClamping() {
        #expect(WingController.sanitizeName("  Kick  ") == "Kick")
        #expect(WingController.sanitizeName("AbsurdlyLongStripName")
            == String("AbsurdlyLongStripName".prefix(WingController.maxNameLength)))
    }

    @Test func setNameEchoesIntoCache() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()

        await controller.setName(.channel, 10, to: "Synth Bass")
        try await waitUntil { controller.name(.channel, 10) == "Synth Bass" }
        #expect(controller.name(.channel, 10) == "Synth Bass")

        await controller.disconnect()
    }

    @Test func setNameClampsBeforeSending() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()

        await controller.setName(.channel, 11, to: "  This Name Is Far Too Long  ")
        let expected = WingController.sanitizeName("  This Name Is Far Too Long  ")
        try await waitUntil { controller.name(.channel, 11) == expected }
        #expect(controller.name(.channel, 11) == expected)
        #expect((controller.name(.channel, 11)?.count ?? 0) <= WingController.maxNameLength)

        await controller.disconnect()
    }

    @Test func setColorEchoesIntoCache() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()

        await controller.setColor(.channel, 12, to: 3)
        try await waitUntil { controller.color(.channel, 12) == 3 }
        #expect(controller.color(.channel, 12) == 3)

        await controller.disconnect()
    }

    @Test func setNamePairSuffixesStereoNodes() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()

        await controller.setNamePair(.channel(13), .channel(14), to: "Pad")
        try await waitUntil {
            controller.name(.channel, 13) == "Pad L" && controller.name(.channel, 14) == "Pad R"
        }
        #expect(controller.name(.channel, 13) == "Pad L")
        #expect(controller.name(.channel, 14) == "Pad R")

        await controller.disconnect()
    }

    @Test func setNamePairLeavesMonoNameUnsuffixed() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()

        await controller.setNamePair(.channel(15), nil, to: "Vox")
        try await waitUntil { controller.name(.channel, 15) == "Vox" }
        #expect(controller.name(.channel, 15) == "Vox")

        await controller.disconnect()
    }

    @Test func setNamePairKeepsStereoNodesDistinctAtMaxLength() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()

        // A base name long enough that the ` L`/` R` suffixes would overflow
        // maxNameLength: the two nodes must still differ and stay within bounds.
        await controller.setNamePair(.channel(16), .channel(17), to: "AbsurdlyLongName")
        try await waitUntil {
            controller.name(.channel, 16) != nil && controller.name(.channel, 17) != nil
        }
        let left = try #require(controller.name(.channel, 16))
        let right = try #require(controller.name(.channel, 17))
        #expect(left.hasSuffix(" L"))
        #expect(right.hasSuffix(" R"))
        #expect(left != right)
        #expect(left.count <= WingController.maxNameLength)
        #expect(right.count <= WingController.maxNameLength)

        await controller.disconnect()
    }
}
