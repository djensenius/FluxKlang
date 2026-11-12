import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Composes real registry events with the spatial route chain (#114; #65 is related only):
/// `DeviceRegistryPresence.make` -> `SpatialRouteAvailability.derive` -> `SpatialMaskSet.passes`.
/// Nothing in production calls this chain yet; the tests pin what the three existing stages do together.
#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct DevicePresenceRouteAvailabilityTests {
    private struct FixtureFailure: Error {}

    private enum Scenario {
        case present, lost, revalidating, mismatchBuffer, mismatchLayout, noBaseline
    }

    // MARK: Tests

    @Test
    func devicePresenceRouteLifecycleStatesReachTheMaskPasses() throws {
        let scenarios: [Scenario] = [.present, .lost, .revalidating, .mismatchBuffer, .mismatchLayout, .noBaseline]
        let routes = try Self.routesOnOwnDevices(1...6)
        let result = try Self.chain(Self.registry(scenarios), routes: routes, speakerRoutes: Self.routeIDs(1...6))
        #expect(result.passes == [.pass, .lost, .lost, .lost, .lost, .lost])
        let expectedAvailable: Set<RouteID> = [try Self.routeID(1)]
        #expect(result.availability.availableRoutes == expectedAvailable)
        let reasons = result.availability.unavailable.map(\.reason)
        #expect(reasons == [.deviceMissing, .deviceStale, .deviceStale, .deviceStale, .deviceStale])
        let unavailableRoutes = result.availability.unavailable.map(\.route.rawValue)
        #expect(unavailableRoutes == ["r.2", "r.3", "r.4", "r.5", "r.6"])
        let readBack = try Self.reasons(result.availability, 1...6)
        #expect(readBack == [nil, .deviceMissing, .deviceStale, .deviceStale, .deviceStale, .deviceStale])
    }

    @Test
    func devicePresenceRouteUnknownDeviceStaysInertNotPresent() throws {
        let routes = [try Self.route(1, device: 1), try Self.route(2, device: 9)]
        let speakers = try Self.routeIDs(1...2)
        let known = try Self.chain(Self.registry([.present]), routes: routes, speakerRoutes: speakers)
        #expect(known.passes == [.pass, .lost])
        let knownReasons = try Self.reasons(known.availability, 1...2)
        #expect(knownReasons == [nil, .deviceUnobserved])
        let absent = known.availability.reason(for: try Self.routeID(3))
        #expect(absent == .routeAbsent)
        let empty = try Self.chain(.empty, routes: routes, speakerRoutes: speakers)
        #expect(empty.passes == [.lost, .lost])
        let emptyReasons = try Self.reasons(empty.availability, 1...2)
        #expect(emptyReasons == [.deviceUnobserved, .deviceUnobserved])
        #expect(empty.availability.available.isEmpty)
    }

    @Test
    func devicePresenceRouteReturnRestoresPassOnlyAfterTheBaselineMatches() throws {
        let baseline = try Self.measuredSet()
        let record = try Self.record(1, measured: baseline)
        let key = record.identityKey
        let observed = try Self.step(.empty, .observed(record))
        let lost = try Self.step(observed, .disappeared(key))
        let returned = try Self.step(lost, .returned(key))
        let mismatched = try Self.step(returned, .capabilitiesMeasured(key, Self.measuredSet(bufferFrames: 256)))
        let restored = try Self.step(returned, .capabilitiesMeasured(key, baseline))
        let stages = [
            RouteStage(registry: observed, pass: .pass, reason: nil),
            RouteStage(registry: lost, pass: .lost, reason: .deviceMissing),
            RouteStage(registry: returned, pass: .lost, reason: .deviceStale),
            RouteStage(registry: mismatched, pass: .lost, reason: .deviceStale),
            RouteStage(registry: restored, pass: .pass, reason: nil)
        ]
        for stage in stages {
            let result = try Self.chain(
                stage.registry, routes: [Self.route(1, device: 1)], speakerRoutes: [Self.routeID(1)]
            )
            #expect(result.passes == [stage.pass])
            let stageReasons = try Self.reasons(result.availability, 1...1)
            #expect(stageReasons == [stage.reason])
        }
    }

    @Test
    func devicePresenceRouteLostDeviceDropsOnlyItsRoutes() throws {
        let routes = [try Self.route(1, device: 1), try Self.route(2, device: 1), try Self.route(3, device: 2)]
        let speakers: [RouteID?] = [try Self.routeID(1), try Self.routeID(2), try Self.routeID(3), nil]
        let result = try Self.chain(Self.registry([.lost, .present]), routes: routes, speakerRoutes: speakers)
        #expect(result.passes == [.lost, .lost, .pass, .lost])
        let expectedAvailable: Set<RouteID> = [try Self.routeID(3)]
        #expect(result.availability.availableRoutes == expectedAvailable)
        let dropped = try Self.reasons(result.availability, 1...3)
        #expect(dropped == [.deviceMissing, .deviceMissing, nil])
    }

    @Test
    func devicePresenceRouteResultIgnoresRecordAndRouteOrder() throws {
        let scenarios: [Scenario] = [.present, .lost, .lost, .lost, .lost, .lost]
        let records = try Self.registry(scenarios).records
        try #require(records.count == 6)
        let recordOrders = [records, records.reversed(), [3, 0, 5, 1, 4, 2].map { records[$0] }]
        let routes = try Self.routesOnOwnDevices(1...6)
        let routeOrders = [routes, routes.reversed(), [2, 5, 0, 4, 1, 3].map { routes[$0] }]
        let speakers = try Self.routeIDs(1...6)
        var results: [(availability: SpatialRouteAvailability, passes: [SpeakerPass])] = []
        for ordered in recordOrders {
            let presence = try DeviceRegistryPresence.make(records: ordered)
            for orderedRoutes in routeOrders {
                results.append(try Self.chain(presence, routes: orderedRoutes, speakerRoutes: speakers))
            }
        }
        #expect(results.count == 9)
        let first = try #require(results.first)
        for result in results {
            #expect(result.availability == first.availability)
            #expect(result.passes == first.passes)
        }
        #expect(first.availability.available.map(\.route.rawValue) == ["r.1"])
        #expect(first.availability.unavailable.map(\.route.rawValue) == ["r.2", "r.3", "r.4", "r.5", "r.6"])
        #expect(first.passes == [.pass, .lost, .lost, .lost, .lost, .lost])
    }

    @Test
    func devicePresenceRouteRefusalsStayRefusalsAndNilWouldHideTheLoss() throws {
        let sameID = try Self.deviceID(1)
        let twins = [try Self.record(1, id: sameID), try Self.record(2, id: sameID)]
        let presenceRefusal: DeviceRegistryRefusal?
        do throws(DeviceRegistryRefusal) {
            _ = try DeviceRegistryPresence.make(records: twins)
            presenceRefusal = nil
        } catch {
            presenceRefusal = error
        }
        #expect(presenceRefusal == .duplicateDeviceID(sameID))

        let twinRoutes = [try Self.route(1, device: 1), try Self.route(1, device: 2)]
        let presence = try DeviceRegistryPresence.make(registry: Self.registry([.present, .present]))
        let routeRefusal: SpatialRouteRefusal?
        do throws(SpatialRouteRefusal) {
            _ = try Self.derive(twinRoutes, presence)
            routeRefusal = nil
        } catch {
            routeRefusal = error
        }
        let repeatedRoute = try Self.routeID(1)
        #expect(routeRefusal == .duplicateRoute(repeatedRoute))

        let speakers = try Self.routeIDs(1...2)
        let routes = [try Self.route(1, device: 1), try Self.route(2, device: 2)]
        let derived = try Self.chain(Self.registry([.present, .lost]), routes: routes, speakerRoutes: speakers)
        let skipped = try SpatialMaskSet.none.passes(layout: Self.layout(speakers), availableRoutes: nil)
        #expect(skipped == [.pass, .pass])
        #expect(derived.passes == [.pass, .lost])
    }

    @Test
    func devicePresenceRouteMaximalRecordSetDerivesRoutesWithinSpatialLimits() throws {
        let count = DeviceCapabilityLimits.devices
        let fitsPresence = count <= SpatialRouteLimits.maximumPresenceEntries
        #expect(fitsPresence)
        var records: [DeviceRecord] = []
        var routes: [AudioRoute] = []
        for index in 1...count {
            records.append(try Self.record(index))
            routes.append(try Self.route(index, device: index, id: Self.paddedRouteID(index)))
        }
        let presence = try DeviceRegistryPresence.make(records: records)
        #expect(presence.byDevice.count == count)
        let all = try Self.derive(routes, presence)
        #expect(all.available.count == count)
        #expect(all.unavailable.isEmpty)
        #expect(all.availableRoutes.count == count)
        let firstRoute = try #require(all.available.first)
        let lastRoute = try #require(all.available.last)
        let expectedFirst = try Self.paddedRouteID(1)
        let expectedLast = try Self.paddedRouteID(count)
        #expect(firstRoute.route == expectedFirst)
        #expect(lastRoute.route == expectedLast)

        let lostIndex = 499
        try #require(records.count > lostIndex)
        records[lostIndex] = records[lostIndex].afterDisappearance()
        let fewer = try Self.derive(routes, DeviceRegistryPresence.make(records: records))
        #expect(fewer.available.count == count - 1)
        let lostRoute = fewer.reason(for: try Self.paddedRouteID(lostIndex + 1))
        #expect(lostRoute == .deviceMissing)
    }

    // MARK: Fixtures

    private static let host = HostID(validated: "host.xdv")
    private static let audioCapability = CapabilityID(validated: "cap.audio")

    private static func deviceID(_ index: Int) throws -> DeviceID {
        try DeviceID("dev.\(index)")
    }

    private static func routeID(_ index: Int) throws -> RouteID {
        try RouteID("r.\(index)")
    }

    private static func routeIDs(_ range: ClosedRange<Int>) throws -> [RouteID?] {
        try range.map { try routeID($0) }
    }

    private static func paddedRouteID(_ index: Int) throws -> RouteID {
        try RouteID(String(format: "r.%04d", index))
    }

    private static func reasons(
        _ availability: SpatialRouteAvailability, _ range: ClosedRange<Int>
    ) throws -> [SpatialRouteAvailability.Reason?] {
        try range.map { availability.reason(for: try routeID($0)) }
    }

    private static func route(_ index: Int, device: Int, id: RouteID? = nil) throws -> AudioRoute {
        var route = AudioRoute(
            id: try id ?? routeID(index), role: RoleID(validated: "role.main"), device: try deviceID(device),
            direction: .output, channels: [0, 1], binding: .confirmed
        )
        route.confirmedHost = host
        route.confirmedDeviceUID = "uid.\(device)"
        return route
    }

    private static func routesOnOwnDevices(_ range: ClosedRange<Int>) throws -> [AudioRoute] {
        try range.map { try route($0, device: $0) }
    }

    private static func layout(_ speakerRoutes: [RouteID?]) throws -> SpatialLayout {
        let speakers = try speakerRoutes.enumerated().map { offset, route in
            try SpatialSpeaker(id: SpeakerID("s.\(offset + 1)"), position: NeutralPoint(x: 0, y: 0), route: route)
        }
        return try SpatialLayout(speakers: speakers)
    }

    private static func derive(
        _ routes: [AudioRoute], _ presence: DeviceRegistryPresence
    ) throws(SpatialRouteRefusal) -> SpatialRouteAvailability {
        try SpatialRouteAvailability.derive(routes: routes, presence: presence.byDevice, host: host)
    }

    private static func chain(
        _ presence: DeviceRegistryPresence, routes: [AudioRoute], speakerRoutes: [RouteID?]
    ) throws -> (availability: SpatialRouteAvailability, passes: [SpeakerPass]) {
        let availability = try derive(routes, presence)
        let passes = try SpatialMaskSet.none.passes(
            layout: layout(speakerRoutes), availableRoutes: availability.availableRoutes
        )
        return (availability, passes)
    }

    private static func chain(
        _ registry: DeviceRegistry, routes: [AudioRoute], speakerRoutes: [RouteID?]
    ) throws -> (availability: SpatialRouteAvailability, passes: [SpeakerPass]) {
        try chain(DeviceRegistryPresence.make(registry: registry), routes: routes, speakerRoutes: speakerRoutes)
    }

    private static func record(
        _ index: Int, id: DeviceID? = nil, measured: DeviceCapabilitySet? = nil
    ) throws -> DeviceRecord {
        try DeviceRecord.make(
            id: try id ?? deviceID(index),
            kind: .audioInterface,
            identity: DeviceIdentityFields(uid: "uid.\(index)", evidence: [.deviceUID]),
            reportedCapabilities: DeviceCapabilitySet.make(capabilities: [audioCapability]),
            measuredCapabilities: measured
        )
    }

    private static func measuredSet(bufferFrames: Int = 128, inputs: Int = 2) throws -> DeviceCapabilitySet {
        try DeviceCapabilitySet.make(
            capabilities: [audioCapability],
            layout: ChannelLayout(inputs: inputs, outputs: 2, sampleRate: 48_000),
            actualRate: MeasuredRate(MeasuredRateFields(hertz: 48_000, evidence: "readback.48k")),
            bufferFrames: bufferFrames
        )
    }

    private static func step(_ registry: DeviceRegistry, _ event: DeviceRegistryEvent) throws -> DeviceRegistry {
        guard case .accepted(let next, _) = registry.applying(event) else { throw FixtureFailure() }
        return next
    }

    private static func registry(_ scenarios: [Scenario]) throws -> DeviceRegistry {
        var registry = DeviceRegistry.empty
        for (offset, scenario) in scenarios.enumerated() {
            registry = try adding(scenario, index: offset + 1, to: registry)
        }
        return registry
    }

    private static func adding(
        _ scenario: Scenario, index: Int, to registry: DeviceRegistry
    ) throws -> DeviceRegistry {
        let baseline = try measuredSet()
        let record = try record(index, measured: scenario == .noBaseline ? nil : baseline)
        let key = record.identityKey
        var events: [DeviceRegistryEvent] = [.observed(record)]
        switch scenario {
        case .present:
            break
        case .lost:
            events.append(.disappeared(key))
        case .revalidating:
            events.append(contentsOf: [.disappeared(key), .returned(key)])
        case .mismatchBuffer:
            events.append(contentsOf: [.disappeared(key), .returned(key)])
            events.append(.capabilitiesMeasured(key, try measuredSet(bufferFrames: 256)))
        case .mismatchLayout:
            events.append(contentsOf: [.disappeared(key), .returned(key)])
            events.append(.capabilitiesMeasured(key, try measuredSet(inputs: 4)))
        case .noBaseline:
            events.append(contentsOf: [.disappeared(key), .returned(key)])
            events.append(.capabilitiesMeasured(key, baseline))
        }
        return try events.reduce(registry) { try step($0, $1) }
    }
}

private struct RouteStage {
    let registry: DeviceRegistry
    let pass: SpeakerPass
    let reason: SpatialRouteAvailability.Reason?
}
