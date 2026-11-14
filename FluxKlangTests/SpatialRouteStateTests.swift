import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the host-local spatial route state (#114 SP1): route availability, speaker state and measurement
/// identity. This file holds the fixtures and the cross-cutting tests; the topics live in the extensions.
@Suite(.productionAccessAudit)
struct SpatialRouteStateTests {
    static let hostA = HostID(validated: "host.a")
    static let hostB = HostID(validated: "host.b")

    static func rid(_ raw: StaticString) -> RouteID { RouteID(validated: raw) }
    static func did(_ raw: StaticString) -> DeviceID { DeviceID(validated: raw) }
    static func sid(_ raw: StaticString) -> SpeakerID { SpeakerID(validated: raw) }

    /// A route; the defaults describe an available one on `hostA`.
    static func route(
        _ id: RouteID,
        device: DeviceID = did("dev.a"),
        direction: RouteDirection = .output,
        channels: [Int] = [0, 1],
        binding: RouteBinding = .confirmed,
        host: HostID? = hostA,
        uid: String? = "uid.a"
    ) -> AudioRoute {
        var route = AudioRoute(
            id: id, role: RoleID(validated: "role.main"), device: device,
            direction: direction, channels: channels, binding: binding
        )
        route.confirmedHost = host
        route.confirmedDeviceUID = uid
        return route
    }

    static func route(_ id: StaticString, device: StaticString = "dev.a", channels: [Int] = [0, 1],
                      uid: String? = "uid.a") -> AudioRoute {
        route(rid(id), device: did(device), channels: channels, uid: uid)
    }

    static let allPresent: [DeviceID: DevicePresence] = [
        did("dev.a"): .present, did("dev.b"): .present, did("dev.c"): .present
    ]

    static func derive(_ routes: [AudioRoute], presence: [DeviceID: DevicePresence] = allPresent,
                       host: HostID = hostA) throws -> SpatialRouteAvailability {
        try SpatialRouteAvailability.derive(routes: routes, presence: presence, host: host)
    }

    static func deriveRefusal(_ routes: [AudioRoute], presence: [DeviceID: DevicePresence] = allPresent,
                              host: HostID = hostA) -> SpatialRouteRefusal? {
        do throws(SpatialRouteRefusal) {
            _ = try SpatialRouteAvailability.derive(routes: routes, presence: presence, host: host)
            return nil
        } catch {
            return error
        }
    }

    static func speaker(_ id: SpeakerID, route: RouteID?) throws -> SpatialSpeaker {
        try SpatialSpeaker(id: id, position: NeutralPoint(x: 0, y: 0), route: route)
    }

    static func layout(_ speakers: [SpatialSpeaker]) throws -> SpatialLayout {
        try SpatialLayout(speakers: speakers)
    }

    static func masks(_ pairs: [(SpeakerID, SpeakerMaskState)]) throws -> SpatialMaskSet {
        try SpatialMaskSet(masks: pairs.map { SpatialOutputMask(speaker: $0.0, state: $0.1) })
    }

    static func measurement(_ speaker: SpeakerID, route: RouteID, uid: String = "uid.a",
                            channels: [Int] = [0, 1], host: HostID = hostA) throws -> SpatialSpeakerMeasurement {
        SpatialSpeakerMeasurement(
            speaker: speaker,
            identity: try SpatialMeasurementIdentity.make(route: route, deviceUID: uid, channels: channels, host: host)
        )
    }

    static func calibration(_ speakers: [SpeakerID]) throws -> SpatialCalibrationSet {
        try SpatialCalibrationSet(entries: speakers.map { try SpeakerCalibration(speaker: $0) })
    }

    static func checkRefusal(
        calibration: SpatialCalibrationSet, layout: SpatialLayout,
        measured: [SpatialSpeakerMeasurement], current: SpatialRouteAvailability
    ) -> SpatialRouteRefusal? {
        do throws(SpatialRouteRefusal) {
            _ = try SpatialCalibrationBinding.check(
                calibration: calibration, layout: layout, measured: measured, current: current
            )
            return nil
        } catch {
            return error
        }
    }

    /// A zero-padded two digit suffix so raw id order equals numeric order.
    static func padded(_ index: Int, prefix: String) -> String {
        prefix + (index < 10 ? "0" : "") + String(index)
    }

    @Test
    func emptyInputsAreLegalForEveryOperation() throws {
        let availability = try Self.derive([], presence: [:])
        #expect(availability.host == Self.hostA)
        #expect(availability.available.isEmpty)
        #expect(availability.unavailable.isEmpty)
        #expect(availability.availableRoutes.isEmpty)
        let empty = try Self.layout([])
        let states = try SpatialSpeakerStates.classify(layout: empty, availability: availability, masks: .none)
        #expect(states.rows.isEmpty)
        let flags = try SpatialCalibrationBinding.check(
            calibration: .empty, layout: empty, measured: [], current: availability
        )
        #expect(flags.isEmpty)
    }
}
