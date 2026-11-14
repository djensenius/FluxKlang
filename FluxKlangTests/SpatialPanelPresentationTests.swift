import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Fixtures of the spatial panel presentation tests (#116 SPT1). Self-contained: no other test file is used.
enum SpatialPanelFixture {
    static let hostA = HostID(validated: "host.a")

    static func sid(_ raw: StaticString) -> SpeakerID { SpeakerID(validated: raw) }
    static func rid(_ raw: StaticString) -> RouteID { RouteID(validated: raw) }
    static func did(_ raw: StaticString) -> DeviceID { DeviceID(validated: raw) }

    static func route(_ id: StaticString, device: StaticString) -> AudioRoute {
        var route = AudioRoute(
            id: rid(id), role: RoleID(validated: "role.main"), device: did(device),
            direction: .output, channels: [0, 1], binding: .confirmed
        )
        route.confirmedHost = hostA
        route.confirmedDeviceUID = "uid.a"
        return route
    }

    static func speaker(_ id: StaticString, _ name: String?, route: StaticString?) throws -> SpatialSpeaker {
        try SpatialSpeaker(
            id: sid(id), name: name, position: NeutralPoint(x: 0, y: 0), route: route.map { rid($0) }
        )
    }

    /// Front Left, Front Right, Rear Left and Rear Right on `r.fl` to `r.rr`, plus the unnamed, unmapped `spk.c`.
    static func quad(withCentre: Bool = false) throws -> SpatialLayout {
        var speakers = [
            try speaker("spk.fl", "Front Left", route: "r.fl"),
            try speaker("spk.fr", "Front Right", route: "r.fr"),
            try speaker("spk.rl", "Rear Left", route: "r.rl"),
            try speaker("spk.rr", "Rear Right", route: "r.rr")
        ]
        if withCentre { speakers.append(try speaker("spk.c", nil, route: nil)) }
        return try SpatialLayout(speakers: speakers)
    }

    static func availability(
        _ routes: [(route: StaticString, device: StaticString)], presence: [DeviceID: DevicePresence]
    ) throws -> SpatialRouteAvailability {
        try SpatialRouteAvailability.derive(
            routes: routes.map { route($0.route, device: $0.device) }, presence: presence, host: hostA
        )
    }

    /// All four quad routes on the present device `dev.a`.
    static func allActive() throws -> SpatialRouteAvailability {
        try availability(
            [("r.fl", "dev.a"), ("r.fr", "dev.a"), ("r.rl", "dev.a"), ("r.rr", "dev.a")],
            presence: [did("dev.a"): .present]
        )
    }

    /// The document's example: three routes on the missing `dev.b`, Rear Right on the present `dev.a`.
    static func docExample() throws -> SpatialRouteAvailability {
        try availability(
            [("r.fl", "dev.b"), ("r.fr", "dev.b"), ("r.rl", "dev.b"), ("r.rr", "dev.a")],
            presence: [did("dev.a"): .present, did("dev.b"): .missing]
        )
    }

    static func masks(
        _ pairs: [(StaticString, SpeakerMaskState)], renormalize: Bool = false
    ) throws -> SpatialMaskSet {
        try SpatialMaskSet(
            masks: pairs.map { SpatialOutputMask(speaker: sid($0.0), state: $0.1) },
            renormalizeSurvivors: renormalize
        )
    }

    static func routeName(_ route: RouteID) -> String? {
        switch route {
        case rid("r.fl"): "Interface B ch 1"
        case rid("r.fr"): "Interface B ch 2"
        case rid("r.rl"): "Interface B ch 3"
        case rid("r.rr"): "Interface B ch 4"
        default: nil
        }
    }

    static func make(
        layout: SpatialLayout,
        availability: SpatialRouteAvailability,
        masks: SpatialMaskSet = .none,
        routeText: (RouteID) -> String? = routeName,
        unavailable: SpatialCalibrationUnavailableReason? = nil
    ) throws -> SpatialPanelPresentation {
        try SpatialPanelPresentation.make(
            layout: layout, availability: availability, masks: masks, routeText: routeText,
            calibrationUnavailable: unavailable, calibrationDeviceName: "Interface B"
        )
    }
}

@Suite("Spatial panel presentation", .productionAccessAudit)
struct SpatialPanelPresentationTests {
    typealias Fixture = SpatialPanelFixture

    @Test func docExampleRowsFollowTheDocument() throws {
        let panel = try Fixture.make(
            layout: Fixture.quad(), availability: Fixture.docExample(), masks: Fixture.masks([("spk.rr", .muted)])
        )
        #expect(panel.rows.count == 4)
        #expect(panel.rows.map(\.name) == ["Front Left", "Front Right", "Rear Left", "Rear Right"])
        #expect(panel.rows.map(\.routeText) == [
            "Interface B ch 1", "Interface B ch 2", "Interface B ch 3", "Interface B ch 4"
        ])
        #expect(panel.rows.map(\.stateText) == ["Lost", "Lost", "Lost", "Masked"])
        #expect(panel.rows.map(\.isMasked) == [false, false, false, true])
    }

    @Test func docExampleBannerAndMaskLine() throws {
        let panel = try Fixture.make(
            layout: Fixture.quad(), availability: Fixture.docExample(), masks: Fixture.masks([("spk.rr", .muted)])
        )
        #expect(panel.banner == "LOST / MUTED")
        #expect(panel.maskText == "Mask: Rear Right muted. Survivors are not boosted.")
    }

    @Test func calibrateDisabledReasons() throws {
        let layout = try Fixture.quad()
        let availability = try Fixture.allActive()
        let missing = try Fixture.make(layout: layout, availability: availability, unavailable: .deviceMissing)
        let unconfirmed = try Fixture.make(layout: layout, availability: availability, unavailable: .routeUnconfirmed)
        let none = try Fixture.make(layout: layout, availability: availability)
        #expect(missing.calibrateDisabledReason == "Interface B missing")
        #expect(unconfirmed.calibrateDisabledReason == "Interface B route not confirmed")
        #expect(none.calibrateDisabledReason == nil)
    }

    @Test func availableRoutesAreActiveWithNoBannerOrMaskLine() throws {
        let panel = try Fixture.make(layout: Fixture.quad(), availability: Fixture.allActive())
        #expect(panel.rows.count == 4)
        #expect(panel.rows.allSatisfy { $0.stateText == "Active" && !$0.isMasked })
        #expect(panel.banner == nil)
        #expect(panel.maskText == nil)
    }

    @Test func unmappedSpeakerAsksToMapOutputs() throws {
        let panel = try Fixture.make(layout: Fixture.quad(withCentre: true), availability: Fixture.allActive())
        let centre = try #require(panel.row(for: Fixture.sid("spk.c")))
        #expect(centre.stateText == "Map outputs...")
        #expect(centre.routeText == nil)
        #expect(!centre.isMasked)
        #expect(centre.state == .unmapped)
        #expect(panel.banner == nil)
        #expect(centre.accessibilityLabel == "spk.c, no route, Map outputs....")
    }

    @Test func everyLostReasonReadsLostAndRaisesTheBanner() throws {
        let availability = try Fixture.availability(
            [("r.fl", "dev.s"), ("r.fr", "dev.m"), ("r.rl", "dev.u")],
            presence: [Fixture.did("dev.s"): .stale, Fixture.did("dev.m"): .missing]
        )
        let panel = try Fixture.make(layout: Fixture.quad(), availability: availability)
        let reasons: [(StaticString, SpatialRouteAvailability.Reason)] = [
            ("spk.fl", .deviceStale), ("spk.fr", .deviceMissing), ("spk.rl", .deviceUnobserved),
            ("spk.rr", .routeAbsent)
        ]
        for (speaker, reason) in reasons {
            let row = try #require(panel.row(for: Fixture.sid(speaker)))
            #expect(row.state == .lost(reason))
            #expect(row.stateText == "Lost")
            #expect(!row.isMasked)
        }
        #expect(panel.banner == "LOST / MUTED")
    }

    @Test func aMutedSpeakerIsMaskedAndTheOthersStayActive() throws {
        let panel = try Fixture.make(
            layout: Fixture.quad(), availability: Fixture.allActive(), masks: Fixture.masks([("spk.rl", .muted)])
        )
        try #require(panel.rows.count == 4)
        for row in panel.rows {
            let muted = row.speaker == Fixture.sid("spk.rl")
            #expect(row.stateText == (muted ? "Masked" : "Active"))
            #expect(row.isMasked == muted)
        }
        #expect(panel.banner == nil)
    }

    @Test func rowsFollowLayoutOrderNotRawIDOrder() throws {
        let layout = try SpatialLayout(speakers: [
            Fixture.speaker("spk.z", "Z", route: nil), Fixture.speaker("spk.a", "A", route: nil)
        ])
        let availability = try Fixture.availability([], presence: [:])
        let panel = try Fixture.make(layout: layout, availability: availability)
        #expect(panel.rows.map(\.speaker) == [Fixture.sid("spk.z"), Fixture.sid("spk.a")])
        let states = try SpatialSpeakerStates.classify(layout: layout, availability: availability, masks: .none)
        #expect(states.rows.map(\.speaker) == [Fixture.sid("spk.a"), Fixture.sid("spk.z")])
    }

    @Test func nameAndRouteFallbacks() throws {
        let layout = try Fixture.quad(withCentre: true)
        let panel = try Fixture.make(layout: layout, availability: Fixture.allActive()) { route in
            switch route {
            case Fixture.rid("r.fl"): nil
            case Fixture.rid("r.fr"): ""
            case Fixture.rid("r.rl"): "  "
            default: "named"
            }
        }
        #expect(panel.rows.map(\.routeText) == ["r.fl", "r.fr", "  ", "named", nil])
        #expect(panel.rows.map(\.name) == ["Front Left", "Front Right", "Rear Left", "Rear Right", "spk.c"])
    }

    @Test func accessibilityLabelsAreExact() throws {
        let panel = try Fixture.make(
            layout: Fixture.quad(withCentre: true), availability: Fixture.docExample(),
            masks: Fixture.masks([("spk.rr", .muted)])
        )
        #expect(panel.rows.map(\.accessibilityLabel) == [
            "Front Left, Interface B ch 1, Lost.",
            "Front Right, Interface B ch 2, Lost.",
            "Rear Left, Interface B ch 3, Lost.",
            "Rear Right, Interface B ch 4, Masked.",
            "spk.c, no route, Map outputs...."
        ])
        let active = try Fixture.make(layout: Fixture.quad(), availability: Fixture.allActive())
        let first = try #require(active.rows.first)
        #expect(first.accessibilityLabel == "Front Left, Interface B ch 1, Active.")
    }

    @Test func moveActionTitles() throws {
        let panel = try Fixture.make(layout: Fixture.quad(withCentre: true), availability: Fixture.allActive())
        let first = try #require(panel.rows.first)
        let last = try #require(panel.rows.last)
        #expect(first.moveActionTitle == "Move to Front Left")
        #expect(last.moveActionTitle == "Move to spk.c")
    }

    @Test func anEmptyLayoutHasNoRowsButStillGivesTheCalibrateReason() throws {
        let empty = try SpatialLayout(speakers: [])
        let availability = try Fixture.availability([], presence: [:])
        let panel = try Fixture.make(layout: empty, availability: availability, unavailable: .deviceMissing)
        #expect(panel.rows.isEmpty)
        #expect(panel.banner == nil)
        #expect(panel.maskText == nil)
        #expect(panel.calibrateDisabledReason == "Interface B missing")
    }

    @Test func routeTextIsAskedOncePerRoutedSpeakerInLayoutOrder() throws {
        var asked: [RouteID] = []
        _ = try Fixture.make(layout: Fixture.quad(withCentre: true), availability: Fixture.allActive()) { route in
            asked.append(route)
            return Fixture.routeName(route)
        }
        #expect(asked == [Fixture.rid("r.fl"), Fixture.rid("r.fr"), Fixture.rid("r.rl"), Fixture.rid("r.rr")])
    }

    @Test func rowsWrapClassifyAndTheValueIsStable() throws {
        let layout = try Fixture.quad(withCentre: true)
        let availability = try Fixture.docExample()
        let masks = try Fixture.masks([("spk.rr", .muted), ("spk.fr", .soloed)])
        let panel = try Fixture.make(layout: layout, availability: availability, masks: masks)
        let states = try SpatialSpeakerStates.classify(layout: layout, availability: availability, masks: masks)
        for row in panel.rows {
            #expect(row.state == states.row(for: row.speaker)?.state)
            #expect(panel.row(for: row.speaker) == row)
        }
        #expect(panel.row(for: Fixture.sid("spk.unknown")) == nil)
        #expect(try Fixture.make(layout: layout, availability: availability, masks: masks) == panel)
    }

    @Test func fixedTexts() {
        let texts: [(String, String)] = [
            (SpatialPanelText.speakersHeading, "Speakers"),
            (SpatialPanelText.routeHeading, "Route (this host)"),
            (SpatialPanelText.stateHeading, "State"),
            (SpatialPanelText.banner, "LOST / MUTED"),
            (SpatialPanelText.maskPrefix, "Mask: "),
            (SpatialPanelText.survivorsNotBoosted, "Survivors are not boosted"),
            (SpatialPanelText.survivorsRenormalized, "Survivors are renormalized"),
            (SpatialPanelText.mapOutputs, "Map outputs..."),
            (SpatialPanelText.noRoute, "no route"),
            (SpatialPanelText.lost, "Lost"),
            (SpatialPanelText.masked, "Masked"),
            (SpatialPanelText.active, "Active")
        ]
        for (actual, expected) in texts { #expect(actual == expected) }
    }
}
