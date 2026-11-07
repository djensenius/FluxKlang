import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Refusal ORDER and input-order independence. Every order test uses a fixture with BOTH defects at once,
/// and the two typed refusals (or labels) differ, so swapping the two checks changes the result.
extension SpatialRouteStateTests {
    fileprivate static func badChannelsRoute(_ id: StaticString, channels: [Int], uid: String = "uid.a") -> AudioRoute {
        route(id, channels: channels, uid: uid)
    }

    fileprivate static func make(_ uid: String, _ channels: [Int]) -> SpatialRouteRefusal? {
        do throws(SpatialRouteRefusal) {
            _ = try SpatialMeasurementIdentity.make(
                route: rid("r.a"), deviceUID: uid, channels: channels, host: hostA
            )
            return nil
        } catch {
            return error
        }
    }

    @Test
    func tooManyRoutesIsCheckedBeforeTooManyPresenceEntries() throws {
        let routes = try (0..<4_097).map { Self.route(try RouteID("r\($0)")) }
        var presence: [DeviceID: DevicePresence] = [:]
        for index in 0..<4_097 { presence[try DeviceID("d\(index)")] = .present }
        #expect(Self.deriveRefusal(routes, presence: presence) == .tooManyRoutes(4_097))
    }

    @Test
    func tooManyPresenceEntriesIsCheckedBeforeDuplicateRoute() throws {
        var presence: [DeviceID: DevicePresence] = [:]
        for index in 0..<4_097 { presence[try DeviceID("d\(index)")] = .present }
        let routes = [Self.route("r.a"), Self.route("r.a")]
        #expect(Self.deriveRefusal(routes, presence: presence) == .tooManyPresenceEntries(4_097))
    }

    @Test
    func duplicateRouteIsCheckedBeforeChannelValidation() {
        let routes = [Self.badChannelsRoute("r.a", channels: []), Self.badChannelsRoute("r.a", channels: [0])]
        #expect(Self.deriveRefusal(routes) == .duplicateRoute(Self.rid("r.a")))
        #expect(Self.deriveRefusal(routes.reversed()) == .duplicateRoute(Self.rid("r.a")))
    }

    @Test
    func channelCountIsCheckedBeforeNegativeChannels() {
        let channels = [-1] + Array(1..<65)
        #expect(channels.count == 65)
        #expect(Self.deriveRefusal([Self.badChannelsRoute("r.a", channels: channels)])
                == .channelCountOutOfRange(Self.rid("r.a"), count: 65))
    }

    @Test
    func negativeChannelIsCheckedBeforeDuplicateChannels() {
        #expect(Self.deriveRefusal([Self.badChannelsRoute("r.a", channels: [-1, -1])])
                == .negativeChannel(Self.rid("r.a"), channel: -1))
        #expect(Self.deriveRefusal([Self.badChannelsRoute("r.a", channels: [2, 2, -3])])
                == .negativeChannel(Self.rid("r.a"), channel: -3))
    }

    @Test
    func uidLengthIsCheckedBeforeChannelsOnOneRoute() {
        let long = String(repeating: "a", count: 1_025)
        #expect(Self.deriveRefusal([Self.badChannelsRoute("r.a", channels: [], uid: long)])
                == .uidTooLong(Self.rid("r.a"), bytes: 1_025))
    }

    @Test
    func routesAreValidatedInAscendingIdOrderWhateverTheInputOrder() {
        let long = String(repeating: "a", count: 1_025)
        let first = Self.badChannelsRoute("r.a", channels: [0], uid: long)
        let second = Self.badChannelsRoute("r.b", channels: [])
        #expect(Self.deriveRefusal([first, second]) == .uidTooLong(Self.rid("r.a"), bytes: 1_025))
        #expect(Self.deriveRefusal([second, first]) == .uidTooLong(Self.rid("r.a"), bytes: 1_025))
        let firstBad = Self.badChannelsRoute("r.a", channels: [])
        let secondBad = Self.badChannelsRoute("r.b", channels: [0], uid: long)
        #expect(Self.deriveRefusal([secondBad, firstBad]) == .channelCountOutOfRange(Self.rid("r.a"), count: 0))
    }

    @Test
    func permutedRoutesAndPresenceGiveTheSameSortedAvailability() throws {
        let routes = [
            Self.route("r.a"), Self.route(Self.rid("r.b"), direction: .input),
            Self.route(Self.rid("r.c"), binding: .proposed), Self.route(Self.rid("r.d"), host: Self.hostB),
            Self.route("r.e", uid: nil), Self.route("r.f", device: "dev.b"), Self.route("r.g", device: "dev.c")
        ]
        var forward: [DeviceID: DevicePresence] = [:]
        for (device, presence) in [(Self.did("dev.a"), DevicePresence.present), (Self.did("dev.b"), .missing),
                                   (Self.did("dev.c"), .present)] { forward[device] = presence }
        var backward: [DeviceID: DevicePresence] = [:]
        for (device, presence) in [(Self.did("dev.c"), DevicePresence.present), (Self.did("dev.b"), .missing),
                                   (Self.did("dev.a"), .present)] { backward[device] = presence }
        let expected = try Self.derive(routes, presence: forward)
        #expect(expected.available.map(\.route) == [Self.rid("r.a"), Self.rid("r.g")])
        let expectedRoutes = try ["r.b", "r.c", "r.d", "r.e", "r.f"].map { try RouteID($0) }
        #expect(expected.unavailable.map(\.route) == expectedRoutes)
        #expect(expected.unavailable.map(\.reason) == [
            .wrongDirection, .notConfirmed(.proposed), .otherHost(Self.hostB), .missingUID, .deviceMissing
        ])
        let rotated = Array(routes[3...] + routes[..<3])
        let interleaved = [routes[6], routes[0], routes[5], routes[1], routes[4], routes[2], routes[3]]
        for permutation in [Array(routes.reversed()), rotated, interleaved] {
            #expect(try Self.derive(permutation, presence: backward) == expected)
        }
    }

    @Test
    func makeChecksUIDLengthBeforeTheEmptyCheck() {
        let id = Self.rid("r.a")
        #expect(Self.make(String(repeating: " ", count: 1_025), [0]) == .uidTooLong(id, bytes: 1_025))
    }

    @Test
    func makeChecksTheUIDBeforeTheChannels() {
        let id = Self.rid("r.a")
        #expect(Self.make(" ", []) == .emptyUID(id))
        #expect(Self.make(String(repeating: "a", count: 1_025), []) == .uidTooLong(id, bytes: 1_025))
    }

    @Test
    func makeChecksChannelCountThenNegativeThenDuplicateWhateverTheChannelOrder() {
        let id = Self.rid("r.a")
        #expect(Self.make("u", [-1] + Array(1..<65)) == .channelCountOutOfRange(id, count: 65))
        #expect(Self.make("u", [-1, -1]) == .negativeChannel(id, channel: -1))
        #expect(Self.make("u", [2, -1, -5, 2]) == .negativeChannel(id, channel: -5))
        #expect(Self.make("u", [-5, 2, 2, -1]) == .negativeChannel(id, channel: -5))
        #expect(Self.make("u", [7, 2, 7, 2]) == .duplicateChannel(id, channel: 2))
    }

    @Test
    func tooManyMeasurementsIsCheckedBeforeDuplicateMeasurement() throws {
        let one = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"))
        let refusal = Self.checkRefusal(
            calibration: .empty, layout: try Self.identityLayout(),
            measured: Array(repeating: one, count: 65), current: try Self.identityAvailability()
        )
        #expect(refusal == .tooManyMeasurements(65))
    }

    @Test
    func duplicateMeasurementIsCheckedBeforeUnknownSpeakerInEveryInputOrder() throws {
        let known = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"))
        let again = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.b"))
        let unknown = try Self.measurement(Self.sid("u.x"), route: Self.rid("r.a"))
        for measured in [[known, again, unknown], [unknown, again, known], [again, unknown, known]] {
            let refusal = Self.checkRefusal(
                calibration: .empty, layout: try Self.identityLayout(), measured: measured,
                current: try Self.identityAvailability()
            )
            #expect(refusal == .duplicateMeasurement(Self.sid("s.1")))
        }
    }

    @Test
    func unknownSpeakerIsTheSmallestAcrossMeasurementsAndCalibrationEntries() throws {
        let layout = try Self.identityLayout()
        let availability = try Self.identityAvailability()
        let measuredFirst = try Self.measurement(Self.sid("u.1"), route: Self.rid("r.a"))
        let measuredLater = try Self.measurement(Self.sid("u.2"), route: Self.rid("r.a"))
        let entryLater = try Self.calibration([Self.sid("s.1"), Self.sid("u.2")])
        let entryFirst = try Self.calibration([Self.sid("s.1"), Self.sid("u.1")])
        #expect(Self.checkRefusal(calibration: entryLater, layout: layout, measured: [measuredFirst],
                                  current: availability) == .unknownSpeaker(Self.sid("u.1")))
        #expect(Self.checkRefusal(calibration: entryFirst, layout: layout, measured: [measuredLater],
                                  current: availability) == .unknownSpeaker(Self.sid("u.1")))
        #expect(Self.checkRefusal(calibration: entryFirst, layout: layout, measured: [measuredLater, measuredFirst],
                                  current: availability) == .unknownSpeaker(Self.sid("u.1")))
    }

    fileprivate static func kind(of speaker: SpeakerID, _ measured: SpatialSpeakerMeasurement) throws
        -> SpatialCalibrationFlag.Kind? {
        try SpatialCalibrationBinding.check(
            calibration: calibration([speaker]), layout: identityLayout(), measured: [measured],
            current: identityAvailability()
        ).first?.kind
    }

    @Test
    func otherHostOutranksRouteUnavailable() throws {
        let measured = try Self.measurement(Self.sid("s.4"), route: Self.rid("r.in"), host: Self.hostB)
        #expect(try Self.kind(of: Self.sid("s.4"), measured) == .otherHost)
    }

    @Test
    func routeUnavailableOutranksRemapped() throws {
        let measured = try Self.measurement(Self.sid("s.4"), route: Self.rid("r.a"))
        #expect(try Self.kind(of: Self.sid("s.4"), measured) == .routeUnavailable)
    }

    @Test
    func aRouteChangeOutranksAUnitChange() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.b"), uid: "uid.other")
        #expect(try Self.kind(of: Self.sid("s.1"), measured) == .remapped)
    }

    @Test
    func aUnitChangeOutranksAChannelChange() throws {
        let measured = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"), uid: "uid.other", channels: [0, 2])
        #expect(try Self.kind(of: Self.sid("s.1"), measured) == .unitChanged)
    }

    @Test
    func aMeasurementWithEveryDefectIsOtherHost() throws {
        let measured = try Self.measurement(
            Self.sid("s.4"), route: Self.rid("r.b"), uid: "uid.other", channels: [9], host: Self.hostB
        )
        #expect(try Self.kind(of: Self.sid("s.4"), measured) == .otherHost)
    }

    @Test
    func permutedMeasurementsGiveTheSameFlags() throws {
        let one = try Self.measurement(Self.sid("s.1"), route: Self.rid("r.a"))
        let two = try Self.measurement(Self.sid("s.2"), route: Self.rid("r.b"), uid: "uid.z", channels: [2, 3])
        let five = try Self.measurement(Self.sid("s.5"), route: Self.rid("r.a"))
        let calibration = try Self.calibration([Self.sid("s.3"), Self.sid("s.2"), Self.sid("s.1"), Self.sid("s.5")])
        var results: [[SpatialCalibrationFlag]] = []
        for measured in [[one, two, five], [five, two, one], [two, five, one]] {
            results.append(try SpatialCalibrationBinding.check(
                calibration: calibration, layout: Self.identityLayout(), measured: measured,
                current: Self.identityAvailability()
            ))
        }
        #expect(results[0] == results[1])
        #expect(results[1] == results[2])
        let expectedSpeakers = try ["s.1", "s.2", "s.3", "s.5"].map { try SpeakerID($0) }
        #expect(results[0].map(\.speaker) == expectedSpeakers)
        #expect(results[0].map(\.kind) == [.matches, .unitChanged, .noMeasurement, .routeUnavailable])
    }
}
