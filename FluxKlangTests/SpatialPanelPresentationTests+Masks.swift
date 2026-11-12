import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The mask line and the mask refusal of the spatial panel presentation (#116 SPT1).
extension SpatialPanelPresentationTests {
    private func panel(
        _ pairs: [(StaticString, SpeakerMaskState)], renormalize: Bool = false,
        availability: SpatialRouteAvailability? = nil
    ) throws -> SpatialPanelPresentation {
        try Fixture.make(
            layout: Fixture.quad(), availability: availability ?? Fixture.allActive(),
            masks: Fixture.masks(pairs, renormalize: renormalize)
        )
    }

    @Test func soloingOneSpeakerMasksTheOthers() throws {
        let result = try panel([("spk.fl", .soloed)])
        #expect(result.rows.map(\.stateText) == ["Active", "Masked", "Masked", "Masked"])
        #expect(result.rows.map(\.isMasked) == [false, true, true, true])
        #expect(result.maskText == "Mask: Front Left soloed. Survivors are not boosted.")
    }

    @Test func mutedAndSoloedSentencesComeInOrder() throws {
        let result = try panel([("spk.rr", .muted), ("spk.fl", .soloed)])
        #expect(result.maskText == "Mask: Rear Right muted. Front Left soloed. Survivors are not boosted.")
    }

    @Test func muteWinsOverSoloInTheMaskLine() throws {
        let result = try panel([("spk.fl", .muted), ("spk.fl", .soloed)])
        #expect(result.maskText == "Mask: Front Left muted. Survivors are not boosted.")
    }

    @Test func namesFollowLayoutOrderNotMaskOrder() throws {
        let result = try panel([("spk.rr", .muted), ("spk.fr", .muted)])
        #expect(result.maskText == "Mask: Front Right, Rear Right muted. Survivors are not boosted.")
        let layout = try SpatialLayout(speakers: [
            Fixture.speaker("spk.z", "Zed", route: nil), Fixture.speaker("spk.a", "Aye", route: nil)
        ])
        let both = try Fixture.make(
            layout: layout, availability: Fixture.availability([], presence: [:]),
            masks: Fixture.masks([("spk.a", .muted), ("spk.z", .muted)])
        )
        #expect(both.maskText == "Mask: Zed, Aye muted. Survivors are not boosted.")
    }

    @Test func renormalizedSurvivorsAreNamedAndAnEmptyMaskSetHasNoLine() throws {
        let muted = try panel([("spk.fl", .muted)], renormalize: true)
        #expect(muted.maskText == "Mask: Front Left muted. Survivors are renormalized.")
        let none = try panel([], renormalize: true)
        #expect(none.maskText == nil)
    }

    @Test func lostBeatsMaskedButTheMaskLineStillNamesTheSpeaker() throws {
        let result = try panel([("spk.fl", .muted)], availability: Fixture.docExample())
        let first = try #require(result.rows.first)
        #expect(first.stateText == "Lost")
        #expect(!first.isMasked)
        #expect(result.banner == "LOST / MUTED")
        #expect(result.maskText == "Mask: Front Left muted. Survivors are not boosted.")
    }

    @Test func aMaskNamingAnUnknownSpeakerIsRefusedBeforeAnyRouteTextIsAsked() throws {
        let masks = try Fixture.masks([("spk.y", .muted), ("spk.x", .soloed)])
        let layout = try Fixture.quad()
        let availability = try Fixture.allActive()
        var asked = 0
        var refusal: SpatialRouteRefusal?
        do throws(SpatialRouteRefusal) {
            _ = try SpatialPanelPresentation.make(
                layout: layout, availability: availability, masks: masks,
                routeText: { _ in asked += 1; return nil },
                calibrationUnavailable: nil, calibrationDeviceName: "Interface B"
            )
        } catch {
            refusal = error
        }
        #expect(refusal == .unknownMaskSpeaker(Fixture.sid("spk.x")))
        #expect(asked == 0)
    }
}
