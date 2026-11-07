import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension TimecodeMachineTests {
    static func grant(
        _ classes: [MMCCommandClass] = [.play],
        target: UInt8 = 0x21,
        issuedAt: Int = 10,
        expiresAt: Int = 20
    ) throws -> MMCSendGrant {
        try MMCSendGrant.make(target: try deviceID(target), commandClasses: classes,
                              issuedAt: issuedAt, expiresAt: expiresAt)
    }

    @Test func machineGrantStoresItsFieldsAndSortedClasses() throws {
        let grant = try Self.grant([.locate, .stop, .record, .play], target: 0x7E, issuedAt: 0, expiresAt: 1)
        #expect(grant.target == (try Self.deviceID(0x7E)))
        #expect(grant.commandClasses == [.stop, .play, .record, .locate])
        #expect(grant.issuedAt == 0)
        #expect(grant.expiresAt == 1)
        #expect(try Self.grant([.record, .play]) == Self.grant([.play, .record]))
    }

    @Test func machineGrantRefusesAnEmptyClassSet() throws {
        #expect(throws: MMCSendGrantError.emptyCommandClasses) { try Self.grant([]) }
    }

    @Test func machineGrantRefusesTheSmallestDuplicateClassInBothOrders() throws {
        let forward: [MMCCommandClass] = [.locate, .record, .play, .locate, .play]
        #expect(throws: MMCSendGrantError.duplicateCommandClass(.play)) { try Self.grant(forward) }
        #expect(throws: MMCSendGrantError.duplicateCommandClass(.play)) { try Self.grant(forward.reversed()) }
    }

    @Test func machineGrantRefusesTheAllCallTargetButAcceptsTheLastRealDevice() throws {
        #expect(throws: MMCSendGrantError.broadcastTarget) { try Self.grant(target: 0x7F) }
        #expect(try Self.grant(target: 0x7E).target.rawValue == 0x7E)
        #expect(try Self.grant(target: 0x00).target.rawValue == 0x00)
    }

    @Test func machineGrantWindowBoundsHaveNAndNPlusOneCases() throws {
        #expect(try Self.grant(issuedAt: 0, expiresAt: 1).expiresAt == 1)
        #expect(throws: MMCSendGrantError.invalidWindow(issuedAt: -1, expiresAt: 5)) {
            try Self.grant(issuedAt: -1, expiresAt: 5)
        }
        #expect(throws: MMCSendGrantError.invalidWindow(issuedAt: 7, expiresAt: 7)) {
            try Self.grant(issuedAt: 7, expiresAt: 7)
        }
        #expect(throws: MMCSendGrantError.invalidWindow(issuedAt: 7, expiresAt: 6)) {
            try Self.grant(issuedAt: 7, expiresAt: 6)
        }
        #expect(try Self.grant(issuedAt: Int.max - 1, expiresAt: Int.max).issuedAt == Int.max - 1)
        #expect(throws: MMCSendGrantError.invalidWindow(issuedAt: Int.max, expiresAt: Int.max)) {
            try Self.grant(issuedAt: Int.max, expiresAt: Int.max)
        }
    }

    @Test func machineGrantFactoryChecksClassesBeforeTargetBeforeWindow() throws {
        #expect(throws: MMCSendGrantError.emptyCommandClasses) {
            try Self.grant([], target: 0x7F, issuedAt: -1, expiresAt: -2)
        }
        #expect(throws: MMCSendGrantError.duplicateCommandClass(.stop)) {
            try Self.grant([.stop, .stop], target: 0x7F, issuedAt: -1, expiresAt: -2)
        }
        #expect(throws: MMCSendGrantError.broadcastTarget) {
            try Self.grant([.stop], target: 0x7F, issuedAt: -1, expiresAt: -2)
        }
        #expect(throws: MMCSendGrantError.invalidWindow(issuedAt: -1, expiresAt: -2)) {
            try Self.grant([.stop], target: 0x20, issuedAt: -1, expiresAt: -2)
        }
    }

    @Test func machineBuilderAcceptsTheWholeActiveWindowAndRefusesBothEdges() throws {
        let grant = try Self.grant(issuedAt: 10, expiresAt: 20)
        let play = MMCMessage(deviceID: try Self.deviceID(0x21), command: .play)
        #expect(try MMCSendBuilder.message(for: .play, grant: grant, now: 10) == play)
        #expect(try MMCSendBuilder.message(for: .play, grant: grant, now: 19) == play)
        #expect(throws: MMCSendRefusal.expired(now: 20, expiresAt: 20)) {
            try MMCSendBuilder.message(for: .play, grant: grant, now: 20)
        }
        #expect(throws: MMCSendRefusal.notYetValid(now: 9, issuedAt: 10)) {
            try MMCSendBuilder.message(for: .play, grant: grant, now: 9)
        }
    }

    @Test func machineBuilderHandlesExtremeTicksWithoutArithmetic() throws {
        let grant = try Self.grant(issuedAt: 0, expiresAt: Int.max)
        #expect(try MMCSendBuilder.message(for: .play, grant: grant, now: Int.max - 1).command == .play)
        #expect(throws: MMCSendRefusal.expired(now: Int.max, expiresAt: Int.max)) {
            try MMCSendBuilder.message(for: .play, grant: grant, now: Int.max)
        }
        #expect(throws: MMCSendRefusal.notYetValid(now: Int.min, issuedAt: 0)) {
            try MMCSendBuilder.message(for: .play, grant: grant, now: Int.min)
        }
    }

    @Test func machineBuilderRefusesClassesOutsideTheGrant() throws {
        let grant = try Self.grant([.play, .stop])
        #expect(throws: MMCSendRefusal.commandClassNotGranted(.record)) {
            try MMCSendBuilder.message(for: .recordStrobe, grant: grant, now: 15)
        }
        #expect(throws: MMCSendRefusal.commandClassNotGranted(.record)) {
            try MMCSendBuilder.message(for: .recordExit, grant: grant, now: 15)
        }
        #expect(throws: MMCSendRefusal.commandClassNotGranted(.pause)) {
            try MMCSendBuilder.message(for: .pause, grant: grant, now: 15)
        }
        #expect(throws: MMCSendRefusal.commandClassNotGranted(.locate)) {
            try MMCSendBuilder.message(for: .locate(try Self.locateTarget()), grant: grant, now: 15)
        }
        #expect(try MMCSendBuilder.message(for: .stop, grant: grant, now: 15).command == .stop)
    }

    @Test func machineRecordGrantCoversBothRecordCommandsButNotPlay() throws {
        let grant = try Self.grant([.record])
        #expect(try MMCSendBuilder.message(for: .recordStrobe, grant: grant, now: 15).command == .recordStrobe)
        #expect(try MMCSendBuilder.message(for: .recordExit, grant: grant, now: 15).command == .recordExit)
        #expect(throws: MMCSendRefusal.commandClassNotGranted(.play)) {
            try MMCSendBuilder.message(for: .play, grant: grant, now: 15)
        }
    }

    @Test func machineBuilderChecksTimeBeforeScope() throws {
        let grant = try Self.grant([.play], issuedAt: 10, expiresAt: 20)
        #expect(throws: MMCSendRefusal.expired(now: 20, expiresAt: 20)) {
            try MMCSendBuilder.message(for: .recordStrobe, grant: grant, now: 20)
        }
        #expect(throws: MMCSendRefusal.notYetValid(now: 9, issuedAt: 10)) {
            try MMCSendBuilder.message(for: .recordStrobe, grant: grant, now: 9)
        }
    }

    @Test func machineBuilderAddressesTheGrantTargetAndEncodesExactBytes() throws {
        let grant = try Self.grant([.deferredPlay], target: 0x33)
        let message = try MMCSendBuilder.message(for: .deferredPlay, grant: grant, now: 12)
        #expect(message.deviceID == (try Self.deviceID(0x33)))
        #expect(message.bytes == [0xF0, 0x7F, 0x33, 0x06, 0x03, 0xF7])
    }

    @Test func machineBuilderOutputRoundTripsThroughMMCDecode() throws {
        let target = try Self.locateTarget(subframes: 17, colorFrame: false)
        let grant = try Self.grant(MMCCommandClass.allCases, target: 0x33)
        let receiver = try Self.deviceID(0x33)
        for (command, _) in try Self.commandsWithClasses() + [(.locate(target), .locate)] {
            let message = try MMCSendBuilder.message(for: command, grant: grant, now: 10)
            let decoded = try #require(try MMCMessage.decode(message.event, receiver: receiver))
            #expect(decoded == message)
            #expect(decoded.command == command)
            #expect(try MMCMessage(sysExPayload: message.sysExPayload) == message)
        }
    }

    @Test func machineRefusedBuildLeavesTheGrantUnchangedAndASecondBuildSucceeds() throws {
        let grant = try Self.grant([.play], issuedAt: 10, expiresAt: 20)
        let copy = grant
        #expect(throws: MMCSendRefusal.expired(now: 25, expiresAt: 20)) {
            try MMCSendBuilder.message(for: .play, grant: grant, now: 25)
        }
        #expect(grant == copy)
        #expect(try MMCSendBuilder.message(for: .play, grant: grant, now: 11).command == .play)
    }
}
