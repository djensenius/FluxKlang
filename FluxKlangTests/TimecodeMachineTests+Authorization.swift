import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension TimecodeMachineTests {
    @Test func machineEmptyPolicyAdmitsNothingForAnyClassOrDevice() throws {
        let policy = MMCAuthorization.denyAll
        #expect(policy.entries.isEmpty)
        #expect(try Self.policy([]) == policy)
        for raw: UInt8 in [0x00, 0x10, 0x7E, 0x7F] {
            for commandClass in MMCCommandClass.allCases {
                #expect(!policy.admits(deviceID: try Self.deviceID(raw), commandClass: commandClass))
            }
        }
    }

    @Test func machineEachClassIsAdmittedOnlyByItsOwnEntry() throws {
        let device = try Self.deviceID(0x21)
        for granted in MMCCommandClass.allCases {
            let policy = try Self.policy([Self.entry(granted)])
            for asked in MMCCommandClass.allCases {
                #expect(policy.admits(deviceID: device, commandClass: asked) == (asked == granted))
            }
        }
    }

    @Test func machineRecordIsNeverImpliedByPlayAndPlayNeverByRecord() throws {
        let device = try Self.deviceID(0x21)
        let playOnly = try Self.policy([Self.entry(.play), Self.entry(.stop), Self.entry(.locate)])
        #expect(playOnly.admits(deviceID: device, commandClass: .play))
        #expect(!playOnly.admits(deviceID: device, commandClass: .record))
        let recordOnly = try Self.policy([Self.entry(.record)])
        #expect(recordOnly.admits(deviceID: device, commandClass: .record))
        #expect(!recordOnly.admits(deviceID: device, commandClass: .play))
    }

    @Test func machineDeviceSelectorMatchesOnlyItsOwnDevice() throws {
        let policy = try Self.policy([Self.entry(.play, .device(try Self.deviceID(5)))])
        #expect(policy.admits(deviceID: try Self.deviceID(5), commandClass: .play))
        #expect(!policy.admits(deviceID: try Self.deviceID(6), commandClass: .play))
        #expect(!policy.admits(deviceID: try Self.deviceID(4), commandClass: .play))
        #expect(!policy.admits(deviceID: .allCall, commandClass: .play))
        #expect(!policy.admits(deviceID: try Self.deviceID(5), commandClass: .stop))
    }

    @Test func machineAnySelectorAdmitsEveryDeviceIncludingAllCall() throws {
        let policy = try Self.policy([Self.entry(.stop, .any)])
        for raw: UInt8 in [0x00, 0x05, 0x7E, 0x7F] {
            #expect(policy.admits(deviceID: try Self.deviceID(raw), commandClass: .stop))
        }
        #expect(!policy.admits(deviceID: .allCall, commandClass: .play))
    }

    @Test func machineAllCallSelectorMatchesOnlyAllCallMessages() throws {
        let policy = try Self.policy([Self.entry(.pause, .device(.allCall))])
        #expect(policy.admits(deviceID: .allCall, commandClass: .pause))
        #expect(!policy.admits(deviceID: try Self.deviceID(0x7E), commandClass: .pause))
        #expect(!policy.admits(deviceID: try Self.deviceID(0), commandClass: .pause))
    }

    @Test func machinePolicyAcceptsExactlyTheMaximumEntryCount() throws {
        #expect(MMCAuthorization.maximumEntries == 64)
        let policy = try Self.policy(try Self.distinctEntries(count: 64))
        #expect(policy.entries.count == 64)
    }

    @Test func machinePolicyRefusesOneEntryOverTheMaximum() throws {
        let entries = try Self.distinctEntries(count: 65)
        #expect(throws: MMCAuthorizationError.tooManyEntries(count: 65, limit: 64)) {
            try MMCAuthorization.make(entries: entries)
        }
    }

    @Test func machineEntryCountIsRefusedBeforeDuplicates() throws {
        let entries = try Self.distinctEntries(count: 64) + [Self.entry(.stop)]
        #expect(entries.count == 65)
        #expect(throws: MMCAuthorizationError.tooManyEntries(count: 65, limit: 64)) {
            try MMCAuthorization.make(entries: entries)
        }
    }

    @Test func machineDuplicateEntriesAreRefusedWithTheSmallestInBothOrders() throws {
        let low = Self.entry(.stop, .device(try Self.deviceID(2)))
        let high = Self.entry(.play, .device(try Self.deviceID(9)))
        let middle = Self.entry(.record, .any)
        let forward = [high, middle, low, high, low]
        #expect(throws: MMCAuthorizationError.duplicateEntry(low)) {
            try MMCAuthorization.make(entries: forward)
        }
        #expect(throws: MMCAuthorizationError.duplicateEntry(low)) {
            try MMCAuthorization.make(entries: forward.reversed())
        }
        let anyDuplicate = [Self.entry(.locate), Self.entry(.locate), low, low]
        #expect(throws: MMCAuthorizationError.duplicateEntry(Self.entry(.locate))) {
            try MMCAuthorization.make(entries: anyDuplicate)
        }
    }

    @Test func machineSameClassWithDifferentSelectorsIsNotADuplicate() throws {
        let five = try Self.deviceID(5)
        let six = try Self.deviceID(6)
        let entries = [Self.entry(.play, .any), Self.entry(.play, .device(five)), Self.entry(.stop, .device(five))]
        #expect(try Self.policy(entries).entries.count == 3)
        #expect(try Self.policy([Self.entry(.play, .any), Self.entry(.play, .device(five))]).entries.count == 2)
        #expect(try Self.policy([Self.entry(.stop, .device(five)), Self.entry(.stop, .device(six))]).entries.count == 2)
    }

    @Test func machineEntriesAreStoredCanonicallyForAnyInputOrder() throws {
        let two = try Self.deviceID(2)
        let nine = try Self.deviceID(9)
        let canonical = [
            Self.entry(.stop, .any), Self.entry(.record, .any),
            Self.entry(.stop, .device(two)), Self.entry(.play, .device(two)),
            Self.entry(.rewind, .device(nine)), Self.entry(.locate, .device(.allCall))
        ]
        let shuffled = [canonical[4], canonical[1], canonical[5], canonical[2], canonical[0], canonical[3]]
        #expect(try Self.policy(shuffled).entries == canonical)
        #expect(try Self.policy(canonical.reversed()).entries == canonical)
        #expect(try Self.policy(shuffled) == Self.policy(canonical))
    }

    @Test func machineRefusedPolicyBuildLeavesTheInputEntriesUnchanged() throws {
        let entries = [Self.entry(.play), Self.entry(.play)]
        let copy = entries
        #expect(throws: MMCAuthorizationError.duplicateEntry(Self.entry(.play))) {
            try MMCAuthorization.make(entries: entries)
        }
        #expect(entries == copy)
        #expect(MMCAuthorization.denyAll.entries.isEmpty)
    }

    /// `count` distinct entries: eight classes for each device id in turn.
    static func distinctEntries(count: Int) throws -> [MMCAuthorizationEntry] {
        let classes = MMCCommandClass.allCases
        return try (0..<count).map { index in
            Self.entry(classes[index % classes.count], .device(try Self.deviceID(UInt8(index / classes.count))))
        }
    }
}
