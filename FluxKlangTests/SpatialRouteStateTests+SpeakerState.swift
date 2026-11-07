import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialRouteStateTests {
    fileprivate static let stateRoutes: [AudioRoute] = [
        route("r.ok1"), route("r.ok2"), route("r.ok3"),
        route("r.stale", device: "dev.c"), route("r.missing", device: "dev.b"),
        route(rid("r.input"), direction: .input), route(rid("r.prop"), binding: .proposed)
    ]
    fileprivate static let statePresence: [DeviceID: DevicePresence] = [
        did("dev.a"): .present, did("dev.b"): .missing, did("dev.c"): .stale
    ]

    fileprivate static func stateAvailability() throws -> SpatialRouteAvailability {
        try derive(stateRoutes, presence: statePresence)
    }

    fileprivate static func classify(
        _ speakers: [(SpeakerID, RouteID?)], masks: [(SpeakerID, SpeakerMaskState)] = []
    ) throws -> SpatialSpeakerStates {
        try SpatialSpeakerStates.classify(
            layout: layout(speakers.map { try speaker($0.0, route: $0.1) }),
            availability: stateAvailability(),
            masks: self.masks(masks)
        )
    }

    fileprivate static func state(_ states: SpatialSpeakerStates, _ id: SpeakerID) -> SpatialSpeakerState? {
        states.row(for: id)?.state
    }

    @Test
    func routeStatesWithoutMasksAreActiveUnmappedOrLostWithTheReason() throws {
        let states = try Self.classify([
            (Self.sid("s.active"), Self.rid("r.ok1")), (Self.sid("s.none"), nil),
            (Self.sid("s.stale"), Self.rid("r.stale")), (Self.sid("s.missing"), Self.rid("r.missing")),
            (Self.sid("s.input"), Self.rid("r.input")), (Self.sid("s.prop"), Self.rid("r.prop")),
            (Self.sid("s.absent"), Self.rid("r.nowhere"))
        ])
        #expect(Self.state(states, Self.sid("s.active")) == .active)
        #expect(Self.state(states, Self.sid("s.none")) == .unmapped)
        #expect(Self.state(states, Self.sid("s.stale")) == .lost(.deviceStale))
        #expect(Self.state(states, Self.sid("s.missing")) == .lost(.deviceMissing))
        #expect(Self.state(states, Self.sid("s.input")) == .lost(.wrongDirection))
        #expect(Self.state(states, Self.sid("s.prop")) == .lost(.notConfirmed(.proposed)))
        #expect(Self.state(states, Self.sid("s.absent")) == .lost(.routeAbsent))
        #expect(states.rows.count == 7)
    }

    @Test
    func aMutedSpeakerIsMaskedMutedAndOthersStayActive() throws {
        let states = try Self.classify(
            [(Self.sid("s.a"), Self.rid("r.ok1")), (Self.sid("s.b"), Self.rid("r.ok2"))],
            masks: [(Self.sid("s.a"), .muted)]
        )
        #expect(Self.state(states, Self.sid("s.a")) == .masked(.muted))
        #expect(Self.state(states, Self.sid("s.b")) == .active)
    }

    @Test
    func soloingSilencesEveryOtherAvailableSpeakerButNeverHidesALostOne() throws {
        let states = try Self.classify([
            (Self.sid("s.a"), Self.rid("r.ok1")), (Self.sid("s.b"), Self.rid("r.ok2")),
            (Self.sid("s.c"), nil), (Self.sid("s.d"), Self.rid("r.stale"))
        ], masks: [(Self.sid("s.a"), .soloed)])
        #expect(Self.state(states, Self.sid("s.a")) == .active)
        #expect(Self.state(states, Self.sid("s.b")) == .masked(.soloed))
        #expect(Self.state(states, Self.sid("s.c")) == .unmapped)
        #expect(Self.state(states, Self.sid("s.d")) == .lost(.deviceStale))
    }

    @Test
    func whenEverySoloedSpeakerIsMutedEveryAvailableSpeakerIsMasked() throws {
        let states = try Self.classify(
            [(Self.sid("s.a"), Self.rid("r.ok1")), (Self.sid("s.b"), Self.rid("r.ok2"))],
            masks: [(Self.sid("s.a"), .soloed), (Self.sid("s.a"), .muted)]
        )
        #expect(Self.state(states, Self.sid("s.a")) == .masked(.muted))
        #expect(Self.state(states, Self.sid("s.b")) == .masked(.soloed))
    }

    @Test
    func anUnmappedSpeakerIsUnmappedEvenWhenMuted() throws {
        let states = try Self.classify(
            [(Self.sid("s.a"), nil)], masks: [(Self.sid("s.a"), .muted)]
        )
        #expect(Self.state(states, Self.sid("s.a")) == .unmapped)
    }

    @Test
    func aLostSpeakerIsLostEvenWhenMutedOrSoloedOut() throws {
        let states = try Self.classify([
            (Self.sid("s.a"), Self.rid("r.stale")), (Self.sid("s.b"), Self.rid("r.missing")),
            (Self.sid("s.c"), Self.rid("r.ok1"))
        ], masks: [(Self.sid("s.a"), .muted), (Self.sid("s.c"), .soloed)])
        #expect(Self.state(states, Self.sid("s.a")) == .lost(.deviceStale))
        #expect(Self.state(states, Self.sid("s.b")) == .lost(.deviceMissing))
    }

    @Test
    func muteOutranksBeingSoloedOutElsewhere() throws {
        let states = try Self.classify(
            [(Self.sid("s.a"), Self.rid("r.ok1")), (Self.sid("s.b"), Self.rid("r.ok2"))],
            masks: [(Self.sid("s.a"), .muted), (Self.sid("s.b"), .soloed)]
        )
        #expect(Self.state(states, Self.sid("s.a")) == .masked(.muted))
        #expect(Self.state(states, Self.sid("s.b")) == .active)
    }

    @Test
    func rowsAreSortedByRawSpeakerIdAndMirrorTheLayoutRoutes() throws {
        let states = try Self.classify([
            (Self.sid("s.c"), nil), (Self.sid("s.a"), Self.rid("r.ok1")), (Self.sid("s.b"), Self.rid("r.ok2"))
        ])
        #expect(states.rows.map(\.speaker) == [Self.sid("s.a"), Self.sid("s.b"), Self.sid("s.c")])
        #expect(states.rows.map(\.route) == [Self.rid("r.ok1"), Self.rid("r.ok2"), nil])
        #expect(states.row(for: Self.sid("s.zzz")) == nil)
    }

    @Test
    func aMaskOnASpeakerOutsideTheLayoutIsRefusedWithTheFirstUnknownSpeaker() throws {
        let layout = try Self.layout([Self.speaker(Self.sid("s.a"), route: nil)])
        let availability = try Self.stateAvailability()
        let one = try Self.masks([(Self.sid("u.2"), .muted), (Self.sid("u.1"), .soloed), (Self.sid("s.a"), .muted)])
        let two = try Self.masks([(Self.sid("s.a"), .muted), (Self.sid("u.1"), .soloed), (Self.sid("u.2"), .muted)])
        #expect(one == two)
        for masks in [one, two] {
            do throws(SpatialRouteRefusal) {
                _ = try SpatialSpeakerStates.classify(layout: layout, availability: availability, masks: masks)
                Issue.record("classify accepted a mask on an unknown speaker")
            } catch {
                #expect(error == .unknownMaskSpeaker(Self.sid("u.1")))
            }
        }
    }

    @Test
    func statesAgreeWithTheRendererMaskPassesAcrossSixtyFourSpeakers() throws {
        let routeIDs = ["r.ok1", "r.ok2", "r.ok3", "r.stale", "r.missing", "r.nowhere"]
        var speakers: [SpatialSpeaker] = []
        for index in 0..<64 {
            let route = index % 8 == 0 ? nil : try RouteID(routeIDs[index % 6])
            speakers.append(try Self.speaker(try SpeakerID(Self.padded(index, prefix: "s")), route: route))
        }
        let layout = try Self.layout(speakers.reversed())
        let availability = try Self.stateAvailability()
        for soloing in [false, true] {
            var pairs: [(SpeakerID, SpeakerMaskState)] = []
            for index in 0..<64 where index % 5 == 0 {
                pairs.append((try SpeakerID(Self.padded(index, prefix: "s")), .muted))
            }
            if soloing {
                pairs.append((try SpeakerID("s09"), .soloed))
                pairs.append((try SpeakerID("s10"), .soloed))
            }
            let masks = try Self.masks(pairs)
            let states = try SpatialSpeakerStates.classify(layout: layout, availability: availability, masks: masks)
            let passes = masks.passes(layout: layout, availableRoutes: availability.availableRoutes)
            #expect(states.rows.count == 64)
            for (speaker, pass) in zip(layout.speakers, passes) {
                let index = try #require(Int(speaker.id.rawValue.dropFirst()))
                let state = try #require(Self.state(states, speaker.id))
                let routeDefect = index % 8 == 0 || index % 6 >= 3
                let maskDefect = index % 5 == 0 || (soloing && index != 9 && index != 10)
                #expect((pass == .pass) == (state == .active))
                switch (routeDefect, maskDefect) {
                case (false, false):
                    #expect(pass == .pass && state == .active)
                case (true, false):
                    #expect(pass == .lost && Self.isRouteLoss(state))
                case (false, true):
                    #expect(pass == .masked && Self.isMask(state))
                case (true, true):
                    #expect(pass == .masked && Self.isRouteLoss(state))
                }
            }
        }
    }

    fileprivate static func isRouteLoss(_ state: SpatialSpeakerState) -> Bool {
        switch state {
        case .lost, .unmapped: true
        case .active, .masked: false
        }
    }

    fileprivate static func isMask(_ state: SpatialSpeakerState) -> Bool {
        if case .masked = state { true } else { false }
    }

    @Test
    func aLayoutOfSixtyFiveSpeakersIsRefusedByTheLayoutItselfNotRebuilt() throws {
        let sixtyFour = try (0..<64).map { try Self.speaker(try SpeakerID("s\($0)"), route: nil) }
        #expect(try Self.layout(sixtyFour).speakers.count == 64)
        let sixtyFive = try (0..<65).map { try Self.speaker(try SpeakerID("s\($0)"), route: nil) }
        #expect(throws: SpatialLayoutError.tooManySpeakers(65)) { try Self.layout(sixtyFive) }
    }
}
