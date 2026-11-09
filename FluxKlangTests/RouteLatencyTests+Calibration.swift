import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RouteLatencyTests {
    @Test func deviceIDAloneMakesARecordStale() throws {
        let recorded = Setup()
        var current = recorded
        current.device = "dev.b"
        current.routes = current.routes.map { route in
            var changed = route
            changed.device = "dev.b"
            return changed
        }
        let record = try Self.record(recorded.configuration(), frames: 480)
        #expect(try record.staleReasons(against: current.configuration()) == [.deviceID])
    }

    @Test func deviceIdentityUIDAndEvidenceAreSeparateStaleFields() throws {
        let recorded = Setup()
        var uidChanged = recorded
        uidChanged.uid = "uid.interface-b"
        var evidenceChanged = recorded
        evidenceChanged.evidence = [.endpointUID]
        let record = try Self.record(recorded.configuration(), frames: 480)
        #expect(try record.staleReasons(against: uidChanged.configuration()) == [.deviceIdentity])
        #expect(try record.staleReasons(against: evidenceChanged.configuration()) == [.deviceIdentity])
    }

    @Test func sampleRateAndEachBufferChangeInvalidates() throws {
        let recorded = Setup()
        var rateChanged = recorded
        rateChanged.rate += 1
        var inputChanged = recorded
        inputChanged.input += 1
        var outputChanged = recorded
        outputChanged.output += 1
        let record = try Self.record(recorded.configuration(), frames: 480)
        #expect(try record.staleReasons(against: rateChanged.configuration()) == [.sampleRate])
        #expect(try record.staleReasons(against: inputChanged.configuration()) == [.inputBuffer])
        #expect(try record.staleReasons(against: outputChanged.configuration()) == [.outputBuffer])
    }

    @Test func routeIdentityDirectionChannelsAndOrderAreBound() throws {
        let recorded = Setup()
        let record = try Self.record(recorded.configuration(), frames: 480)
        var idChanged = recorded
        idChanged.routes[0].id = "route.changed"
        var directionChanged = recorded
        directionChanged.routes[0].direction = .output
        var channelsChanged = recorded
        channelsChanged.routes[0].channels = [1, 0]
        var orderChanged = recorded
        orderChanged.routes.reverse()
        #expect(try record.staleReasons(against: idChanged.configuration()) == [.routes])
        #expect(try record.staleReasons(against: directionChanged.configuration()) == [.routes])
        #expect(try record.staleReasons(against: channelsChanged.configuration()) == [.routes])
        #expect(try record.staleReasons(against: orderChanged.configuration()).isEmpty)
    }

    @Test func addingAndRemovingRoutesInvalidates() throws {
        let recorded = Setup()
        let record = try Self.record(recorded.configuration(), frames: 480)
        var added = recorded
        added.routes.append(RouteSpec(id: "route.extra", direction: .input, channels: [4]))
        var removed = recorded
        removed.routes.removeLast()
        #expect(try record.staleReasons(against: added.configuration()) == [.routes])
        #expect(try record.staleReasons(against: removed.configuration()) == [.routes])
    }

    @Test func routeInputOrderDoesNotChangeTheSnapshot() throws {
        var first = Setup()
        var reversed = first
        reversed.routes.reverse()
        #expect(try first.configuration() == reversed.configuration())
        let ascending = [try RouteID("route.in"), try RouteID("route.out")]
        #expect(try first.configuration().routes.map(\.id) == ascending)
        #expect(try reversed.configuration().routes.map(\.id) == ascending)
        first.routes[0].channels = [1, 0]
        #expect(try first.configuration() != reversed.configuration())
    }

    @Test func routeOnAnOtherDeviceIsRefusedWithItsTypedIDs() throws {
        var setup = Setup()
        setup.routes[1].device = "dev.other"
        #expect(throws: LatencyRefusal.routeDeviceMismatch(
            try RouteID("route.out"), expected: try DeviceID("dev.a"), found: try DeviceID("dev.other")
        )) {
            try setup.configuration()
        }
    }

    @Test func configurationRejectsRouteCountBoundariesAndAcceptsSixteen() throws {
        var empty = Setup()
        empty.routes = []
        #expect(throws: LatencyRefusal.noRoutes) { try empty.configuration() }
        var tooMany = Setup()
        tooMany.routes = (0..<17).map { RouteSpec(id: "route.\($0)", channels: [0]) }
        #expect(throws: LatencyRefusal.tooManyRoutes(count: 17)) { try tooMany.configuration() }
        var maximum = Setup()
        maximum.routes = (0..<16).map { RouteSpec(id: "route.\($0)", channels: [0]) }
        #expect(try maximum.configuration().routes.count == 16)
        maximum.routes.removeLast()
        #expect(try maximum.configuration().routes.count == 15)
    }

    @Test func duplicateRouteRefusesTheSmallestDuplicateID() throws {
        var setup = Setup()
        setup.routes = [
            RouteSpec(id: "route.z"),
            RouteSpec(id: "route.b", direction: .output, channels: [2]),
            RouteSpec(id: "route.a", channels: [4]),
            RouteSpec(id: "route.b", direction: .output, channels: [3])
        ]
        #expect(throws: LatencyRefusal.duplicateRoute(try RouteID("route.b"))) {
            try setup.configuration()
        }
    }

    @Test func routeChannelsRejectEmptyOutOfRangeAndDuplicatesButAcceptEdges() throws {
        for channels in [[], [-1], [4_096], [0, 0]] {
            var setup = Setup()
            setup.routes[0].channels = channels
            #expect(throws: LatencyRefusal.invalidRouteChannels(try RouteID("route.in"))) {
                try setup.configuration()
            }
        }
        var edges = Setup()
        edges.routes[0].channels = [0, 4_095]
        _ = try edges.configuration()
        edges.routes[0].channels = Array(0..<4_096)
        _ = try edges.configuration()
    }

    @Test func allConfigurationChangesAreListedInDeclarationOrder() throws {
        let recorded = Setup()
        var current = recorded
        current.device = "dev.b"
        current.uid = "uid.b"
        current.rate += 1
        current.input += 1
        current.output += 1
        current.routes[0].id = "route.changed"
        current.deviceGeneration += 1
        current.calibrationGeneration += 1
        current.routes = current.routes.map { route in
            var changed = route
            changed.device = "dev.b"
            return changed
        }
        let record = try Self.record(recorded.configuration(), frames: 480)
        #expect(try record.staleReasons(against: current.configuration())
            == [.deviceID, .deviceIdentity, .sampleRate, .inputBuffer, .outputBuffer, .routes,
                .deviceGeneration, .calibrationGeneration])
    }

    @Test func routeRoleBindingAndEvidenceAreNotBoundSignalPathFields() throws {
        let setup = Setup()
        var changed = try setup.routes.map { try $0.route() }
        changed[0].role = try RoleID("role.other")
        changed[0].binding = .stale
        changed[0].evidence = "different evidence"
        let current = try CalibrationConfiguration.make(
            deviceID: DeviceID("dev.a"), identity: Self.identity(), routes: changed,
            stream: StreamSetup.make(sampleRateHz: setup.rate, inputBufferFrames: setup.input,
                                     outputBufferFrames: setup.output),
            generations: Self.generations()
        )
        let record = try Self.record(setup.configuration(), frames: 480)
        #expect(record.isFresh(for: current))
    }

    @Test func producerIDAcceptsOneAnd128BytesAndRejectsOutsideAndBadAlphabet() throws {
        let configuration = try Setup().configuration()
        let measurement = try Self.measurement(frames: 1)
        for producer in ["p", String(repeating: "p", count: 128)] {
            #expect(try CalibrationRecord.make(measurement: measurement, producer: producer,
                                               configuration: configuration).producer.rawValue == producer)
        }
        for producer in ["", String(repeating: "p", count: 129), "producer invalid"] {
            #expect(throws: LatencyRefusal.invalidProducerID(bytes: producer.utf8.count)) {
                try CalibrationRecord.make(measurement: measurement, producer: producer, configuration: configuration)
            }
        }
    }

    @Test func generationsAdvanceAndOverflowWithoutChangingState() throws {
        var device = try Self.generations().device
        try device.advance()
        #expect(device.generation.value == 2)
        var maximum = DeviceGeneration(try Generation(Generation.maximumValue))
        let before = maximum
        #expect(throws: RevisionError.overflow) { try maximum.advance() }
        #expect(maximum == before)
    }
}

private struct DeviceIdentityBytesCalibrationMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension RouteLatencyTests {
    private static let identityBytesAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789.-_")

    /// Copy of main (CalibrationConfiguration.swift `staleReasons` before DEV2); `self` is `recorded`.
    private static func identityBytesOldStaleReasons(
        _ recorded: CalibrationConfiguration, comparedTo current: CalibrationConfiguration
    ) -> [CalibrationStaleReason] {
        var reasons: [CalibrationStaleReason] = []
        if recorded.device.deviceID != current.device.deviceID { reasons.append(.deviceID) }
        if recorded.device.uid != current.device.uid || recorded.device.evidence != current.device.evidence {
            reasons.append(.deviceIdentity)
        }
        if recorded.stream.sampleRateHz != current.stream.sampleRateHz { reasons.append(.sampleRate) }
        if recorded.stream.inputBufferFrames != current.stream.inputBufferFrames { reasons.append(.inputBuffer) }
        if recorded.stream.outputBufferFrames != current.stream.outputBufferFrames { reasons.append(.outputBuffer) }
        if recorded.routes != current.routes { reasons.append(.routes) }
        if recorded.generations.device != current.generations.device { reasons.append(.deviceGeneration) }
        if recorded.generations.calibration != current.generations.calibration {
            reasons.append(.calibrationGeneration)
        }
        return reasons
    }

    @Test func deviceIdentityBytesCalibrationForAnotherSpellingIsStale() throws {
        var recorded = Setup()
        recorded.uid = "\u{E9}"
        var current = recorded
        current.uid = "e\u{301}"
        let record = try Self.record(recorded.configuration(), frames: 480)
        let otherUnit = try current.configuration()
        let sameUnit = try recorded.configuration()
        #expect(record.staleReasons(against: otherUnit) == [.deviceIdentity])
        #expect(!record.isFresh(for: otherUnit))
        #expect(record.staleReasons(against: sameUnit) == [])
        #expect(record.isFresh(for: sameUnit))

        var upper = recorded
        upper.uid = "Unit.A"
        var lower = recorded
        lower.uid = "unit.a"
        let upperRecord = try Self.record(upper.configuration(), frames: 480)
        #expect(try upperRecord.staleReasons(against: lower.configuration()) == [.deviceIdentity])
    }

    @Test func deviceIdentityBytesCalibrationSnapshotsHashApart() throws {
        var first = Setup()
        first.uid = "\u{C5}"
        var second = first
        second.uid = "A\u{30A}"
        var third = first
        third.uid = "\u{212B}"
        let snapshots = try [first, second, third].map { try $0.configuration().device }
        #expect(snapshots[0] != snapshots[1])
        #expect(snapshots[0] != snapshots[2])
        #expect(snapshots[1] != snapshots[2])
        #expect(Set(snapshots).count == 3)
        let rebuilt = try first.configuration().device
        #expect(snapshots[0] == rebuilt)
        #expect(snapshots[0].hashValue == rebuilt.hashValue)
    }

    @Test func deviceIdentityBytesCalibrationASCIIStaleReasonsMatchTheOldCopy() throws {
        let lengths = [1, 2, 3, 5, 8, 40, 1_024]
        let alphabetSize = UInt64(Self.identityBytesAlphabet.count)
        var cases = 0
        for seed: UInt64 in [1, 0xD3A2, 0x65] {
            var generator = DeviceIdentityBytesCalibrationMix(state: seed)
            var setups: [Setup] = []
            for index in 0..<12 {
                var uid = ""
                for _ in 0..<lengths[index % lengths.count] {
                    uid.append(Self.identityBytesAlphabet[Int(generator.next() % alphabetSize)])
                }
                for evidence: Set<IdentityEvidence> in [[.deviceUID], [.endpointUID, .deviceUID]] {
                    for rate in [48_000, 44_100] {
                        var setup = Setup()
                        setup.uid = uid
                        setup.evidence = evidence
                        setup.rate = rate
                        setups.append(setup)
                    }
                }
            }
            let configurations = try setups.map { try $0.configuration() }
            for recorded in configurations {
                for current in configurations {
                    let old = Self.identityBytesOldStaleReasons(recorded, comparedTo: current)
                    #expect(recorded.staleReasons(comparedTo: current) == old)
                    cases += 1
                }
            }
        }
        let expectedCases = 6_912
        #expect(cases == expectedCases)
    }
}
