import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialRenderTests {
    static func unmasked(_ horizontal: Double, _ vertical: Double) throws -> [Double] {
        try plan(quad(), [source(horizontal, vertical)]).row(0)
    }

    @Test func muteZeroesSpeakerAndLeavesSurvivorsBitIdentical() throws {
        let law = try Self.unmasked(0.2, 0.4)
        let row = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], masks: [Self.mask("spk.rr")]).row(0)
        #expect(row[3] == 0 && law[3] > 0)
        #expect(Array(row[0..<3]) == Array(law[0..<3]))
        #expect(Self.power(row) < 1)
        for renormalize in [false, true] {
            let all = try Self.quadNames.map { try Self.mask($0) }
            let silent = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], masks: all, renormalize: renormalize)
            #expect(silent.gains == [0, 0, 0, 0])
        }
    }

    @Test func renormalizationIsOptInAndRestoresUnitPower() throws {
        let law = try Self.unmasked(0.2, 0.4)
        let row = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], masks: [Self.mask("spk.rr")],
                                renormalize: true).row(0)
        #expect(row[3] == 0)
        #expect(abs(Self.power(row) - 1) < 1e-12)
        #expect((0..<3).allSatisfy { row[$0] > law[$0] })
        #expect(try SpatialMaskSet(masks: [Self.mask("spk.rr")]).renormalizeSurvivors == false)
        #expect(SpatialMaskSet.none.renormalizeSurvivors == false)
    }

    @Test func survivorScaleCapEdge() {
        #expect(SpatialRenderer.maximumRenormalizationBoost == 2)
        #expect(SpatialRenderer.survivorScale(power: 0.25, renormalize: true) == 2)
        #expect(SpatialRenderer.survivorScale(power: Double(0.25).nextDown, renormalize: true) == 2)
        #expect(SpatialRenderer.survivorScale(power: 0.2, renormalize: true) == 2)
        #expect(SpatialRenderer.survivorScale(power: Double(0.25).nextUp, renormalize: true) <= 2)
        let above = SpatialRenderer.survivorScale(power: 0.2501, renormalize: true)
        #expect(above == 1 / 0.2501.squareRoot() && above < 2)
        #expect(SpatialRenderer.survivorScale(power: 0.3, renormalize: true) == 1 / 0.3.squareRoot())
        #expect(SpatialRenderer.survivorScale(power: 1, renormalize: true) == 1)
        #expect(SpatialRenderer.survivorScale(power: Double(1.0).nextDown, renormalize: true) > 1)
        #expect(SpatialRenderer.survivorScale(power: 0, renormalize: true) == 1)
        #expect(SpatialRenderer.survivorScale(power: 0.25, renormalize: false) == 1)
    }

    @Test func renormalizationCapInPlans() throws {
        // At the origin each quad gain is exactly 0.5: one survivor has power 0.25,
        // the cap edge, so it reaches exactly 1.
        let origin = try Self.unmasked(0, 0)
        #expect(origin == [0.5, 0.5, 0.5, 0.5])
        let three = try ["spk.fr", "spk.rl", "spk.rr"].map { try Self.mask($0) }
        let one = try Self.plan(Self.quad(), [Self.source(0, 0)], masks: three, renormalize: true).row(0)
        #expect(one == [1, 0, 0, 0])
        let two = try Self.plan(Self.quad(), [Self.source(0, 0)], masks: Array(three.suffix(2)),
                                renormalize: true).row(0)
        #expect(abs(two[0] - 0.5 * 2.0.squareRoot()) < 1e-15 && two[1] == two[0] && two[2] == 0)
        #expect(abs(Self.power(two) - 1) < 1e-15)
        // On a muted speaker the survivors' power is far below 0.25: capped at ×2.
        let law = try Self.unmasked(1, -1)
        let capped = try Self.plan(Self.quad(), [Self.source(1, -1)], masks: [Self.mask("spk.rr")],
                                   renormalize: true).row(0)
        #expect(Self.power(Array(law[0..<3])) < 0.25)
        #expect(Array(capped[0..<3]) == law[0..<3].map { $0 * 2 })
        #expect(capped[3] == 0 && Self.power(capped) < 1)
    }

    @Test func soloMasksOthersWithoutBoostAndMuteWins() throws {
        let law = try Self.unmasked(0.2, 0.4)
        let solo = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], masks: [Self.mask("spk.fl", .soloed)])
        #expect(solo.row(0) == [law[0], 0, 0, 0])
        let pair = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)],
                                 masks: [Self.mask("spk.fl", .soloed), Self.mask("spk.fr", .soloed)])
        #expect(pair.row(0) == [law[0], law[1], 0, 0])
        let partly = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)],
                                   masks: [Self.mask("spk.fl", .soloed), Self.mask("spk.fr", .soloed),
                                           Self.mask("spk.fl")])
        #expect(partly.row(0) == [0, law[1], 0, 0])
        for renormalize in [false, true] {
            let masks = try [Self.mask("spk.fl", .soloed), Self.mask("spk.fl"),
                             Self.mask("spk.fr", .soloed), Self.mask("spk.fr")]
            let silent = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], masks: masks, renormalize: renormalize)
            #expect(silent.row(0) == [0, 0, 0, 0])
        }
    }

    @Test func routeLossOnlyZeroesEvenWithRenormalization() throws {
        let layout = try Self.quad()
        let law = try Self.unmasked(0.2, 0.4)
        let routes = try Set(["rte.spk.fl", "rte.spk.rl", "rte.spk.rr"].map { try RouteID($0) })
        for renormalize in [false, true] {
            let lost = try Self.plan(layout, [Self.source(0.2, 0.4)], renormalize: renormalize, routes: routes)
            #expect(lost.row(0) == [law[0], 0, law[2], law[3]])
        }
        let muted = try Self.plan(layout, [Self.source(0.2, 0.4)], masks: [Self.mask("spk.rr")], renormalize: true)
        let mutedAndLost = try Self.plan(layout, [Self.source(0.2, 0.4)], masks: [Self.mask("spk.rr")],
                                         renormalize: true, routes: routes)
        #expect(mutedAndLost.row(0) == [muted.row(0)[0], 0, muted.row(0)[2], 0])
        let unrouted = try SpatialLayout(speakers: [
            SpatialSpeaker(id: Self.id("spk.a"), position: NeutralPoint(x: -1, y: 0), route: RouteID("rte.a")),
            SpatialSpeaker(id: Self.id("spk.b"), position: NeutralPoint(x: 1, y: 0))
        ])
        let available = try Set([RouteID("rte.a")])
        let both = try Self.plan(unrouted, [Self.source(0, 0)]).row(0)
        #expect(try Self.plan(unrouted, [Self.source(0, 0)], routes: available).row(0) == [both[0], 0])
        #expect(try Self.plan(unrouted, [Self.source(0, 0)], routes: []).row(0) == [0, 0])
    }

    /// Rounding can leave an unmasked row's power a hair below 1; loss alone, or
    /// muting a silent non-participant, must still never scale survivors.
    @Test func renormalizationNeverScalesUnmaskedRows() throws {
        let layout = try Self.layout(Self.quadPoints + [(0, 0.9), (-0.6, 0.1)],
                                     participates: [true, true, true, true, true, false])
        let routes = try Set((0..<6).filter { $0 != 1 }.map { try RouteID("rte.spk.\($0)") })
        var belowUnit = 0
        let grid = stride(from: -1.0, through: 1.0, by: 0.125)
        for col in grid {
            for row in grid {
                let law = try Self.plan(layout, [Self.source(col, row)]).row(0)
                if Self.power(law) < 1 { belowUnit += 1 }
                let lost = try Self.plan(layout, [Self.source(col, row)], renormalize: true, routes: routes).row(0)
                #expect(lost == [law[0], 0] + law[2...])
                let silentMute = try Self.plan(layout, [Self.source(col, row)], masks: [Self.mask("spk.5")],
                                               renormalize: true).row(0)
                #expect(silentMute == law)
            }
        }
        #expect(belowUnit > 0)
    }

    @Test func passesPrecedence() throws {
        let layout = try Self.quad()
        let set = try SpatialMaskSet(masks: [Self.mask("spk.fl", .soloed), Self.mask("spk.fl"),
                                             Self.mask("spk.fr", .soloed)])
        let routes = try Set([RouteID("rte.spk.fl"), RouteID("rte.spk.rr")])
        #expect(set.passes(layout: layout, availableRoutes: routes) == [.masked, .lost, .masked, .masked])
        #expect(set.passes(layout: layout, availableRoutes: nil) == [.masked, .pass, .masked, .masked])
        #expect(SpatialMaskSet.none.passes(layout: layout, availableRoutes: routes) == [.pass, .lost, .lost, .pass])
    }

    @Test func nonParticipantStaysSilentUnderRenormalization() throws {
        let layout = try Self.layout(Self.quadPoints + [(0.2, 0.4)], participates: [true, true, true, true, false])
        let row = try Self.plan(layout, [Self.source(0.2, 0.4)], masks: [Self.mask("spk.0"), Self.mask("spk.1")],
                                renormalize: true).row(0)
        #expect(row[4] == 0 && row[0] == 0 && row[1] == 0)
        #expect(abs(Self.power(row) - 1) < 1e-12)
    }

    @Test func maskBoundsAndUnknownSpeakers() throws {
        let names = (0..<64).map { "spk.\($0)" }
        let points = names.indices.map { (Double($0) / 64, 0.0) }
        let layout = try Self.layout(points, names: names)
        let full = try names.flatMap { [try Self.mask($0), try Self.mask($0, .soloed)] }
        #expect(try Self.plan(layout, [Self.source(0, 0)], masks: full).gains.count == 64)
        #expect(throws: SpatialRenderError.tooManyMasks(129)) {
            try SpatialMaskSet(masks: full + [Self.mask("spk.x")])
        }
        let spk = try Self.id("spk.0")
        #expect(throws: SpatialRenderError.duplicateMask(spk)) {
            try SpatialMaskSet(masks: [Self.mask("spk.0"), Self.mask("spk.1"), Self.mask("spk.0")])
        }
        let ghost = try Self.id("spk.ghost")
        #expect(throws: SpatialRenderError.unknownMaskSpeaker(ghost)) {
            try Self.plan(Self.quad(), [Self.source(0, 0)], masks: [Self.mask("spk.fl"), Self.mask("spk.ghost")])
        }
    }

    static func renderDecodeError<Value: Decodable>(_ type: Value.Type, _ json: String) -> SpatialRenderError? {
        do {
            _ = try JSONDecoder().decode(type, from: Data(json.utf8))
            return nil
        } catch let DecodingError.dataCorrupted(context) {
            return context.underlyingError as? SpatialRenderError
        } catch {
            return nil
        }
    }

    @Test func maskSetCodable() throws {
        let set = try SpatialMaskSet(masks: [Self.mask("spk.rr"), Self.mask("spk.fl", .soloed)],
                                     renormalizeSurvivors: true)
        let data = try JSONEncoder().encode(set)
        #expect(try JSONDecoder().decode(SpatialMaskSet.self, from: data) == set)
        let defaults = try JSONDecoder().decode(SpatialMaskSet.self,
                                                from: Data(#"{"masks":[{"speaker":"spk.rr","state":"muted"}]}"#.utf8))
        #expect(defaults == (try SpatialMaskSet(masks: [Self.mask("spk.rr")])))
        let duplicate = #"{"masks":[{"speaker":"a","state":"muted"},{"speaker":"a","state":"muted"}]}"#
        #expect(Self.renderDecodeError(SpatialMaskSet.self, duplicate) == .duplicateMask(try Self.id("a")))
        let many = (0..<129).map { #"{"speaker":"s\#($0)","state":"muted"}"# }.joined(separator: ",")
        #expect(Self.renderDecodeError(SpatialMaskSet.self, #"{"masks":[\#(many)]}"#) == .tooManyMasks(129))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SpatialMaskSet.self,
                                     from: Data(#"{"masks":[{"speaker":"a","state":"boosted"}]}"#.utf8))
        }
    }
}
