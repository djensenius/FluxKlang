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
