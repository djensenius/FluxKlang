import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialRouteStateTests {
    struct ReasonCase {
        let route: AudioRoute
        let presence: [DeviceID: DevicePresence]
        let expected: SpatialRouteAvailability.Reason
    }

    @Test
    func confirmedOutputsOnThisHostWithPresentDevicesAreAvailableWithTheirUnit() throws {
        let routes = [
            Self.route("r.b", device: "dev.b", channels: [3, 1], uid: "uid.b"),
            Self.route("r.a", device: "dev.a", channels: [0], uid: "uid.a")
        ]
        let availability = try Self.derive(routes)
        #expect(availability.host == Self.hostA)
        #expect(availability.available.map(\.route) == [Self.rid("r.a"), Self.rid("r.b")])
        let first = try #require(availability.available.first)
        #expect(first.device == Self.did("dev.a"))
        #expect(first.uid.value == "uid.a")
        #expect(first.channels == [0])
        let second = try #require(availability.available.last)
        #expect(second.device == Self.did("dev.b"))
        #expect(second.uid.value == "uid.b")
        #expect(second.channels == [1, 3])
        #expect(availability.unavailable.isEmpty)
        #expect(availability.availableRoutes == [Self.rid("r.a"), Self.rid("r.b")])
    }

    @Test
    func everySingleDefectGivesItsOwnReason() throws {
        let id = Self.rid("r.x")
        let absent: [DeviceID: DevicePresence] = [Self.did("dev.b"): .present]
        let cases = [
            ReasonCase(route: Self.route(id, direction: .input), presence: Self.allPresent, expected: .wrongDirection),
            ReasonCase(route: Self.route(id, binding: .proposed), presence: Self.allPresent,
                       expected: .notConfirmed(.proposed)),
            ReasonCase(route: Self.route(id, binding: .stale), presence: Self.allPresent,
                       expected: .notConfirmed(.stale)),
            ReasonCase(route: Self.route(id, binding: .deviceMissing), presence: Self.allPresent,
                       expected: .notConfirmed(.deviceMissing)),
            ReasonCase(route: Self.route(id, host: Self.hostB), presence: Self.allPresent,
                       expected: .otherHost(Self.hostB)),
            ReasonCase(route: Self.route(id, host: nil), presence: Self.allPresent, expected: .otherHost(nil)),
            ReasonCase(route: Self.route(id, uid: nil), presence: Self.allPresent, expected: .missingUID),
            ReasonCase(route: Self.route(id, uid: ""), presence: Self.allPresent, expected: .missingUID),
            ReasonCase(route: Self.route(id, uid: " \t\n"), presence: Self.allPresent, expected: .missingUID),
            ReasonCase(route: Self.route(id), presence: [Self.did("dev.a"): .missing], expected: .deviceMissing),
            ReasonCase(route: Self.route(id), presence: [Self.did("dev.a"): .stale], expected: .deviceStale),
            ReasonCase(route: Self.route(id), presence: [:], expected: .deviceUnobserved),
            ReasonCase(route: Self.route(id), presence: absent, expected: .deviceUnobserved)
        ]
        for reasonCase in cases {
            let availability = try Self.derive([reasonCase.route], presence: reasonCase.presence)
            #expect(availability.available.isEmpty)
            #expect(availability.unavailable.map(\.route) == [id])
            #expect(availability.unavailable.map(\.reason) == [reasonCase.expected])
            #expect(availability.availableRoutes.isEmpty)
        }
    }

    @Test
    func directionIsCheckedBeforeBinding() throws {
        let route = Self.route(Self.rid("r.x"), direction: .input, binding: .proposed)
        let availability = try Self.derive([route])
        #expect(availability.unavailable.map(\.reason) == [.wrongDirection])
    }

    @Test
    func bindingIsCheckedBeforeHost() throws {
        let route = Self.route(Self.rid("r.x"), binding: .proposed, host: Self.hostB)
        let availability = try Self.derive([route])
        #expect(availability.unavailable.map(\.reason) == [.notConfirmed(.proposed)])
    }

    @Test
    func hostIsCheckedBeforeUID() throws {
        let route = Self.route(Self.rid("r.x"), host: Self.hostB, uid: nil)
        let availability = try Self.derive([route])
        #expect(availability.unavailable.map(\.reason) == [.otherHost(Self.hostB)])
    }

    @Test
    func uidIsCheckedBeforePresence() throws {
        let route = Self.route(Self.rid("r.x"), uid: nil)
        let presences: [[DeviceID: DevicePresence]] = [
            [:], [Self.did("dev.a"): .missing], [Self.did("dev.a"): .stale], [Self.did("dev.a"): .present]
        ]
        for presence in presences {
            let availability = try Self.derive([route], presence: presence)
            #expect(availability.unavailable.map(\.reason) == [.missingUID])
        }
    }

    @Test
    func aRouteWithEveryDefectGetsTheFirstReason() throws {
        let route = Self.route(Self.rid("r.x"), direction: .input, binding: .stale, host: nil, uid: nil)
        let availability = try Self.derive([route], presence: [:])
        #expect(availability.unavailable.map(\.reason) == [.wrongDirection])
    }

    @Test
    func blankUIDsAreMissingNotRefusedAndOtherUIDsAreStoredExactly() throws {
        for blank in ["", " ", "\t\n\r", "\u{00A0}", "\u{3000}", "\u{2028}", "\u{200B}"] {
            let availability = try Self.derive([Self.route("r.a", uid: blank)])
            #expect(availability.unavailable.map(\.reason) == [.missingUID])
        }
        for stored in [" uid ", "UID.A"] {
            let availability = try Self.derive([Self.route("r.a", uid: stored)])
            #expect(availability.available.map(\.uid.value) == [stored])
        }
    }

    @Test
    func routeUIDLengthIsAtMostOneThousandTwentyFourBytes() throws {
        let id = Self.rid("r.a")
        let exact = String(repeating: "a", count: 1_024)
        #expect(try Self.derive([Self.route("r.a", uid: exact)]).available.count == 1)
        let twoByte = String(repeating: "\u{e9}", count: 512)
        #expect(twoByte.utf8.count == 1_024)
        #expect(try Self.derive([Self.route("r.a", uid: twoByte)]).available.count == 1)
        let over = String(repeating: "a", count: 1_025)
        #expect(Self.deriveRefusal([Self.route("r.a", uid: over)]) == .uidTooLong(id, bytes: 1_025))
        let overMixed = String(repeating: "\u{e9}", count: 511) + "abc"
        #expect(Self.deriveRefusal([Self.route("r.a", uid: overMixed)]) == .uidTooLong(id, bytes: 1_025))
        let blankOver = String(repeating: " ", count: 1_025)
        #expect(Self.deriveRefusal([Self.route("r.a", uid: blankOver)]) == .uidTooLong(id, bytes: 1_025))
        let inputRoute = Self.route(id, direction: .input, uid: over)
        #expect(Self.deriveRefusal([inputRoute]) == .uidTooLong(id, bytes: 1_025))
    }

    @Test
    func routeCountBoundIsFourThousandNinetySix() throws {
        func routes(_ count: Int) throws -> [AudioRoute] {
            try (0..<count).map { Self.route(try RouteID("r\($0)"), host: nil, uid: nil) }
        }
        let accepted = try Self.derive(routes(4_096), presence: [:])
        #expect(accepted.unavailable.count == 4_096)
        #expect(accepted.available.isEmpty)
        #expect(Self.deriveRefusal(try routes(4_097)) == .tooManyRoutes(4_097))
    }

    @Test
    func presenceEntryBoundIsFourThousandNinetySix() throws {
        func presence(_ count: Int) throws -> [DeviceID: DevicePresence] {
            var result: [DeviceID: DevicePresence] = [:]
            for index in 0..<count { result[try DeviceID("d\(index)")] = .present }
            return result
        }
        let accepted = try Self.derive([Self.route("r.a")], presence: presence(4_096))
        #expect(accepted.unavailable.map(\.reason) == [.deviceUnobserved])
        let refused = Self.deriveRefusal([Self.route("r.a")], presence: try presence(4_097))
        #expect(refused == .tooManyPresenceEntries(4_097))
    }

    @Test
    func duplicateRouteRefusesTheSmallestDuplicatedIdInEveryInputOrder() {
        let firstA = Self.route("r.a")
        let secondA = Self.route("r.a", uid: "uid.other")
        let firstB = Self.route("r.b")
        let secondB = Self.route("r.b", uid: "uid.other")
        let expected = SpatialRouteRefusal.duplicateRoute(Self.rid("r.a"))
        #expect(Self.deriveRefusal([firstB, secondB, firstA, secondA]) == expected)
        #expect(Self.deriveRefusal([secondA, firstA, secondB, firstB]) == expected)
        #expect(Self.deriveRefusal([secondB, firstA, firstB, secondA]) == expected)
        #expect(Self.deriveRefusal([firstA, firstB, secondB]) == .duplicateRoute(Self.rid("r.b")))
    }

    @Test
    func routeChannelCountIsOneThroughSixtyFour() throws {
        let id = Self.rid("r.a")
        let one = try Self.derive([Self.route("r.a", channels: [0])])
        #expect(one.available.map(\.channels) == [[0]])
        let sixtyFour = Array((0..<64).reversed())
        let full = try Self.derive([Self.route("r.a", channels: sixtyFour)])
        #expect(full.available.map(\.channels) == [Array(0..<64)])
        #expect(Self.deriveRefusal([Self.route("r.a", channels: [])]) == .channelCountOutOfRange(id, count: 0))
        #expect(Self.deriveRefusal([Self.route("r.a", channels: Array(0..<65))])
                == .channelCountOutOfRange(id, count: 65))
        let input = Self.route(id, direction: .input, channels: [])
        #expect(try Self.derive([input]).unavailable.map(\.reason) == [.wrongDirection])
    }

    @Test
    func channelsAreValidatedOnlyForARouteThatPassedEveryAvailabilityCheck() throws {
        let id = Self.rid("r.a")
        let tooMany = Array(0..<65)
        let inputRoute = Self.route(id, direction: .input, channels: tooMany)
        #expect(try Self.derive([inputRoute]).unavailable.map(\.reason) == [.wrongDirection])
        let otherHost = Self.route(id, channels: [2, 2], host: Self.hostB)
        #expect(try Self.derive([otherHost]).unavailable.map(\.reason) == [.otherHost(Self.hostB)])
        let noUID = Self.route("r.a", channels: [-1], uid: nil)
        #expect(try Self.derive([noUID]).unavailable.map(\.reason) == [.missingUID])
        let absent = Self.route("r.a", channels: [-1])
        let missing = try Self.derive([absent], presence: [Self.did("dev.a"): .missing])
        #expect(missing.unavailable.map(\.reason) == [.deviceMissing])
        #expect(Self.deriveRefusal([Self.route("r.a", channels: tooMany)]) == .channelCountOutOfRange(id, count: 65))
    }

    @Test
    func theConfirmationEpochIsIgnoredByAvailability() throws {
        var stamped = Self.route("r.a")
        stamped.confirmedEpoch = try Generation(7)
        #expect(try Self.derive([stamped]) == Self.derive([Self.route("r.a")]))
    }

    @Test
    func routeChannelValuesAreNonNegativeAndDistinct() throws {
        let id = Self.rid("r.a")
        #expect(Self.deriveRefusal([Self.route("r.a", channels: [-1])]) == .negativeChannel(id, channel: -1))
        #expect(Self.deriveRefusal([Self.route("r.a", channels: [4, Int.min, -2])])
                == .negativeChannel(id, channel: Int.min))
        #expect(Self.deriveRefusal([Self.route("r.a", channels: [3, 3])]) == .duplicateChannel(id, channel: 3))
        #expect(Self.deriveRefusal([Self.route("r.a", channels: [5, 3, 5, 1, 3])])
                == .duplicateChannel(id, channel: 3))
        let extreme = try Self.derive([Self.route("r.a", channels: [Int.max, 0])])
        #expect(extreme.available.map(\.channels) == [[0, Int.max]])
    }

    @Test
    func reasonForAnswersAvailableUnavailableAndAbsentRoutes() throws {
        let availability = try Self.derive([
            Self.route("r.a"),
            Self.route(Self.rid("r.b"), direction: .input)
        ])
        #expect(availability.reason(for: Self.rid("r.a")) == nil)
        #expect(availability.reason(for: Self.rid("r.b")) == .wrongDirection)
        #expect(availability.reason(for: Self.rid("r.zzz")) == .routeAbsent)
        #expect(availability.entry(for: Self.rid("r.a"))?.uid.value == "uid.a")
        #expect(availability.entry(for: Self.rid("r.b")) == nil)
    }

    @Test
    func aRefusedDeriveLeavesItsInputsEqualToTheirCopies() {
        let routes = [Self.route("r.a", channels: [1, 1]), Self.route("r.b")]
        let presence = Self.allPresent
        let routesBefore = routes
        let presenceBefore = presence
        #expect(Self.deriveRefusal(routes, presence: presence) != nil)
        #expect(routes == routesBefore)
        #expect(presence == presenceBefore)
    }
}
