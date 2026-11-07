import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Positions

extension ControlFeedbackTests {
    static let paramOne = ParameterID(validated: "par.one")
    static let paramTwo = ParameterID(validated: "par.two")
    static let paramThree = ParameterID(validated: "par.three")

    @Test("A host value is answered inside the range its ceiling leaves, clamped at both ends")
    func ceilingCapsThePositionRange() throws {
        let capped = try Self.descriptor(Self.level, unit: .normalized, range: 0...1, ceiling: 0.5)
        let binding = try Self.binding(unit: .normalized)
        let cases: [(host: Double, position: Double)] = [(0.8, 1), (0.5, 1), (0.25, 0.5), (0, 0), (-0.1, 0)]
        for entry in cases {
            var planner = try Self.planner()
            let truth = try Self.truth([capped], [Self.level: entry.host])
            let outcomes = try planner.plan([binding], truth: truth, reason: .clamp, now: 0)
            let expected = try Self.told(binding, entry.position, .clamp)
            #expect(outcomes == [expected])
        }
    }

    @Test("A stepped parameter is answered at the position of the step the host snapped to")
    func steppedParametersAreAnsweredAtTheSnappedStep() throws {
        let steps = try Self.descriptor(Self.level, unit: .index, range: 1...12, curve: .stepped)
        let binding = try Self.binding(unit: .index)
        let truth = try Self.truth([steps], [Self.level: 7])
        var planner = try Self.planner()
        let moved = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 0)
        #expect(moved == .move)
        #expect(planner.shownStep(of: binding.id) == 64)
        let outcomes = try planner.plan([binding], truth: truth, reason: .clamp, now: 0)
        let expected = try Self.told(binding, 6.0 / 11.0, .clamp)
        #expect(outcomes == [expected])
        #expect(planner.shownStep(of: binding.id) == 69)
    }

    @Test("A relative encoder is answered on the grid its declared width can express")
    func relativeEncodersAreAnsweredOnTheirDeclaredGrid() throws {
        let cases: [(profile: EncoderProfile, step: Int)] = [
            (.twosComplement(width: .seven), 76), (.binaryOffset(width: .fourteen), 9830)
        ]
        for entry in cases {
            var planner = try Self.planner()
            let binding = try Self.binding(profile: entry.profile)
            let result = try Self.answer(&planner, binding, host: 60, now: 0)
            let expected = try Self.message(0.6)
            #expect(result == .message(expected))
            #expect(planner.shownStep(of: binding.id) == entry.step)
        }
    }

    @Test("The undefined fader taper is refused for relative and absolute bindings and tracks nothing")
    func faderTaperIsRefused() throws {
        let taper = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, curve: .faderTaper)
        let truth = try Self.truth([taper], [Self.level: -10])
        for profile in [EncoderProfile.absolute(resolution: 128), .twosComplement(width: .seven)] {
            var planner = try Self.planner()
            let binding = try Self.binding(unit: .decibels, profile: profile)
            let outcomes = try planner.plan([binding], truth: truth, reason: .scene, now: 0)
            #expect(outcomes == [Self.refused(binding, .undefinedCurve(.faderTaper))])
            #expect(planner.trackedCount == 0)
        }
    }
}

// MARK: - Scenes and unchanged

extension ControlFeedbackTests {
    @Test("A scene recall tells only the bindings whose position changed, in input order")
    func sceneRecallTellsOnlyTheChangedBindings() throws {
        let targets = [Self.paramOne, Self.paramTwo, Self.paramThree]
        let descriptors = try targets.map { try Self.descriptor($0) }
        let bindings = try zip(["c", "a", "b"], targets).map { try Self.binding($0, target: $1) }
        var planner = try Self.planner()
        let before = try Self.truth(descriptors, [Self.paramOne: 10, Self.paramTwo: 20, Self.paramThree: 30])
        let first = try planner.plan(bindings, truth: before, reason: .scene, now: 0)
        #expect(first.map(\.binding) == bindings.map(\.id))
        #expect(first.allSatisfy { Self.isMessage($0.result) })
        let after = try Self.truth(descriptors, [Self.paramOne: 10, Self.paramTwo: 60, Self.paramThree: 90])
        let recalled = try planner.plan(bindings, truth: after, reason: .scene, now: 1)
        let toldSecond = try Self.told(bindings[1], 0.6, .scene)
        let toldThird = try Self.told(bindings[2], 0.9, .scene)
        #expect(recalled == [Self.withheld(bindings[0], .unchanged), toldSecond, toldThird])
    }

    @Test("A host value on the step the controller already shows emits nothing and changes nothing")
    func unchangedHostEmitsNothing() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        _ = try Self.answer(&planner, binding, host: 50, now: 5)
        let before = planner
        let same = try Self.answer(&planner, binding, host: 50, now: 5)
        #expect(same == .suppressed(.unchanged))
        #expect(planner == before)
        let subStep = try Self.answer(&planner, binding, host: 50.1, now: 5)
        #expect(subStep == .suppressed(.unchanged))
        #expect(planner == before)
        let nextStep = try Self.answer(&planner, binding, host: 51, now: 6)
        let expected = try Self.message(0.51)
        #expect(nextStep == .message(expected))
    }

    @Test("A plan carries its reason into the message; refresh forces nothing")
    func reasonsAreCarriedIntoMessages() throws {
        let binding = try Self.binding()
        for reason in ControlFeedbackReason.allCases where reason != .release {
            var planner = try Self.planner()
            let result = try Self.answer(&planner, binding, host: 60, reason, now: 0)
            let expected = try Self.message(0.6, reason)
            #expect(result == .message(expected))
        }
        var planner = try Self.planner()
        _ = try Self.answer(&planner, binding, host: 60, .scene, now: 0)
        let refreshed = try Self.answer(&planner, binding, host: 60, .refresh, now: 1)
        #expect(refreshed == .suppressed(.unchanged))
    }
}

// MARK: - Automation

extension ControlFeedbackTests {
    @Test("An automation value is answered at its own position under the reason automation")
    func automationValueIsAnsweredAtItsPosition() throws {
        let binding = try Self.binding()
        let truth = try Self.levelTruth(20)
        var planner = try Self.planner()
        let result = ArbitrationResult(outcome: .applied, owner: .automation, value: 80)
        let outcomes = try planner.plan(automation: result, target: Self.level, bindings: [binding],
                                        truth: truth, now: 1)
        let expected = try Self.told(binding, 0.8, .automation)
        #expect(outcomes == [expected])
        #expect(planner.shownStep(of: binding.id) == 102)
        let owned = ArbitrationResult(outcome: .applied, owner: .gesture(Self.sourceB), value: 80)
        let again = try planner.plan(automation: owned, target: Self.level, bindings: [binding],
                                     truth: truth, now: 2)
        #expect(again == [Self.withheld(binding, .unchanged)])
    }

    @Test("An automation result without a value emits nothing and tracks nothing")
    func nilAutomationValueEmitsNothing() throws {
        let binding = try Self.binding()
        let result = ArbitrationResult(outcome: .applied, owner: .automation, value: nil)
        var planner = try Self.planner()
        let outcomes = try planner.plan(automation: result, target: Self.level, bindings: [binding],
                                        truth: Self.levelTruth(20), now: 3)
        #expect(outcomes == [Self.withheld(binding, .noValue)])
        #expect(planner.trackedCount == 0)
        let expected = try Self.advanced(Self.planner(), to: 3)
        #expect(planner == expected)
    }

    @Test("An automation result for another parameter, or one the catalog lacks, refuses the binding")
    func automationTargetMismatchIsRefused() throws {
        let binding = try Self.binding()
        let result = ArbitrationResult(outcome: .applied, owner: .automation, value: 80)
        let truth = try Self.truth([Self.descriptor(Self.level), Self.descriptor(Self.other)], [:])
        var planner = try Self.planner()
        let mismatch = try planner.plan(automation: result, target: Self.other, bindings: [binding],
                                        truth: truth, now: 1)
        let wrong = ControlBindingRefusal.descriptorMismatch(expected: Self.level, found: Self.other)
        #expect(mismatch == [Self.refused(binding, wrong)])
        let absent = try planner.plan(automation: result, target: Self.missing, bindings: [binding],
                                      truth: truth, now: 2)
        #expect(absent == [Self.refused(binding, .targetMissing(Self.missing))])
        #expect(planner.trackedCount == 0)
    }
}

// MARK: - Refusals

extension ControlFeedbackTests {
    @Test("A missing target or value refuses only that binding; the others are still answered")
    func missingTargetOrValueRefusesOnlyThatBinding() throws {
        let present = try Self.binding("a")
        let absent = try Self.binding("b", target: Self.missing)
        let valueless = try Self.binding("c", target: Self.other)
        let truth = try Self.truth([Self.descriptor(Self.level), Self.descriptor(Self.other)], [Self.level: 40])
        var planner = try Self.planner()
        let outcomes = try planner.plan([absent, valueless, present], truth: truth, reason: .scene, now: 0)
        let told = try Self.told(present, 0.4, .scene)
        let expected = [Self.refused(absent, .targetMissing(Self.missing)),
                        Self.refused(valueless, .valueUnavailable(Self.other)), told]
        #expect(outcomes == expected)
        #expect(planner.trackedCount == 1)
    }

    @Test("A non-finite host value is refused and leaves the controller's shown position alone")
    func nonFiniteHostValuesAreRefused() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        _ = try Self.answer(&planner, binding, host: 60, now: 0)
        for (offset, bad) in [Double.nan, .infinity, -.infinity].enumerated() {
            let tick = UInt64(offset) + 1
            let before = planner
            let result = try Self.answer(&planner, binding, host: bad, now: tick)
            #expect(result == .refused(.nonFinite))
            let expected = try Self.advanced(before, to: tick)
            #expect(planner == expected)
        }
        let settled = try Self.answer(&planner, binding, host: 60, now: 4)
        #expect(settled == .suppressed(.unchanged))
    }

    @Test("Structural and hazardous parameters are refused as unboundable and tracked nowhere")
    func nonLiveClassesAreRefused() throws {
        let binding = try Self.binding()
        for controlClass in [ControlClass.structural, .hazardous] {
            let descriptor = try Self.descriptor(Self.level, controlClass: controlClass)
            let truth = try Self.truth([descriptor], [Self.level: 50])
            var planner = try Self.planner()
            let outcomes = try planner.plan([binding], truth: truth, reason: .scene, now: 0)
            #expect(outcomes == [Self.refused(binding, .unboundableClass(controlClass))])
            #expect(planner.trackedCount == 0)
        }
    }

    @Test("A disagreeing unit and an empty binding range are refused per binding")
    func unitAndRangeRefusals() throws {
        let wrongUnit = try Self.binding("a", unit: .decibels)
        let fine = try Self.binding("b")
        let outside = try ControlBinding(.init(
            id: BindingID("bnd.c"), source: ControlSourceID("ctl.c"), target: Self.level, unit: .percent,
            profile: .absolute(resolution: 128), step: nil, lower: 120, upper: 130, pickup: .jump
        ))
        var planner = try Self.planner()
        let outcomes = try planner.plan([wrongUnit, fine, outside], truth: Self.levelTruth(40), reason: .scene, now: 0)
        let toldFine = try Self.told(fine, 0.4, .scene)
        let unit = ControlBindingRefusal.unitMismatch(expected: .percent, found: .decibels)
        let range = ControlBindingRefusal.emptyRange(lower: 120, upper: 100)
        #expect(outcomes == [Self.refused(wrongUnit, unit), toldFine, Self.refused(outside, range)])
        var other = try Self.planner()
        let measured = try Self.levelTruth(40, unit: .decibels)
        let stale = try other.plan([fine], truth: measured, reason: .scene, now: 0)
        #expect(stale == [Self.refused(fine, unit)])
        #expect(other.trackedCount == 0)
    }
}

// MARK: - Tables and ordering

extension ControlFeedbackTests {
    @Test("All 120 orderings of five mixed bindings give the same outcomes by ID and the same planner")
    func orderingNeverChangesTheAnswers() throws {
        let targets = [Self.level, Self.missing, Self.other, Self.level, Self.level]
        let bindings = try zip(["a", "b", "c", "d", "e"], targets).map { try Self.binding($0, target: $1) }
        let truth = try Self.truth([Self.descriptor(Self.level), Self.descriptor(Self.other)], [Self.level: 40])
        let expected = try [
            bindings[0].id: Self.told(bindings[0], 0.4, .scene).result,
            bindings[1].id: Self.refused(bindings[1], .targetMissing(Self.missing)).result,
            bindings[2].id: Self.refused(bindings[2], .valueUnavailable(Self.other)).result,
            bindings[3].id: Self.told(bindings[3], 0.4, .scene).result,
            bindings[4].id: ControlFeedbackResult.tableFull(capacity: 2)
        ]
        let orders = Self.permutations(Array(bindings.indices))
        #expect(orders.count == 120)
        var baseline: ControlFeedbackPlanner?
        for order in orders {
            var planner = try Self.planner(bindings: 2)
            let input = order.map { bindings[$0] }
            let outcomes = try planner.plan(input, truth: truth, reason: .scene, now: 7)
            #expect(outcomes.map(\.binding) == input.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.binding, $0.result) })
            #expect(byID == expected)
            if let baseline {
                #expect(planner == baseline)
            } else {
                baseline = planner
            }
        }
    }

    @Test("A full binding table refuses a new binding, still answers a tracked one and evicts no hold")
    func fullBindingTableRefusesOnlyNewBindings() throws {
        var planner = try Self.planner(bindings: 2, holds: 1)
        let bindings = try ["a", "b", "c"].map { try Self.binding($0) }
        let full = ControlFeedbackOutcome(binding: bindings[2].id, result: .tableFull(capacity: 2))
        _ = try planner.touch(Self.sourceA, now: 0)
        let first = try planner.plan(bindings, truth: Self.levelTruth(40), reason: .scene, now: 1)
        let toldSecond = try Self.told(bindings[1], 0.4, .scene)
        #expect(first == [Self.withheld(bindings[0], .hold), toldSecond, full])
        #expect(planner.trackedCount == 2)
        #expect(planner.holds.isHeld(Self.sourceA, at: 1))
        let second = try planner.plan(bindings, truth: Self.levelTruth(80), reason: .scene, now: 2)
        let retold = try Self.told(bindings[1], 0.8, .scene)
        #expect(second == [Self.withheld(bindings[0], .hold), retold, full])
        planner.forget(bindings[1].id)
        let third = try planner.plan([bindings[2]], truth: Self.levelTruth(80), reason: .scene, now: 3)
        let admitted = try Self.told(bindings[2], 0.8, .scene)
        #expect(third == [admitted])
        #expect(planner.trackedCount == 2)
        #expect(planner.holds.isHeld(Self.sourceA, at: 3))
    }

    @Test("Forget makes the controller be told again, is idempotent and never touches a hold or the clock")
    func forgetForcesAResend() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        _ = try planner.touch(Self.sourceB, now: 4)
        _ = try Self.answer(&planner, binding, host: 60, now: 5)
        let same = try Self.answer(&planner, binding, host: 60, now: 6)
        #expect(same == .suppressed(.unchanged))
        planner.forget(binding.id)
        #expect(!planner.isTracked(binding.id))
        #expect(planner.lastTick == 6)
        #expect(planner.holds.isHeld(Self.sourceB, at: 6))
        let once = planner
        let unknown = try BindingID("bnd.unknown")
        planner.forget(binding.id)
        planner.forget(unknown)
        #expect(planner == once)
        let again = try Self.answer(&planner, binding, host: 60, now: 7)
        let expected = try Self.message(0.6)
        #expect(again == .message(expected))
    }
}

// MARK: - Time and budget

extension ControlFeedbackTests {
    @Test("Every entry point refuses an earlier tick and leaves the planner equal; the same tick is accepted")
    func everyEntryPointRefusesATickRegression() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let truth = try Self.levelTruth(50)
        _ = try Self.answer(&planner, binding, host: 50, now: 9)
        let before = planner
        let regressed = ControlFeedbackRefusal.tickRegressed(last: 9, now: 8)
        let result = ArbitrationResult(outcome: .applied, owner: .automation, value: 50)
        #expect(throws: regressed) { try planner.plan([binding], truth: truth, reason: .scene, now: 8) }
        #expect(throws: regressed) {
            try planner.plan(automation: result, target: Self.level, bindings: [binding], truth: truth, now: 8)
        }
        #expect(throws: regressed) {
            try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 8)
        }
        #expect(throws: regressed) { try planner.touch(Self.sourceA, now: 8) }
        #expect(throws: regressed) {
            try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 8)
        }
        #expect(throws: regressed) { try planner.due(at: 8) }
        #expect(planner == before)
        #expect(try planner.due(at: 9).isEmpty)
        let sameTick = try planner.plan([binding], truth: truth, reason: .scene, now: 9)
        #expect(sameTick == [Self.withheld(binding, .unchanged)])
    }

    @Test("A spent emit budget coalesces to the newest value; due lists the binding once a slot frees")
    func emitBudgetCoalescesToTheNewestValue() throws {
        var planner = try Self.planner(window: 10, budget: 2)
        let binding = try Self.binding()
        let hosts: [(tick: UInt64, host: Double)] = [(0, 10), (1, 20), (2, 30), (3, 40)]
        var results: [ControlFeedbackResult] = []
        for entry in hosts {
            results.append(try Self.answer(&planner, binding, host: entry.host, now: entry.tick))
        }
        let first = try Self.message(0.1)
        let second = try Self.message(0.2)
        let coalesced = ControlFeedbackResult.suppressed(.coalesced)
        #expect(results == [.message(first), .message(second), coalesced, coalesced])
        #expect(try planner.due(at: 10).isEmpty)
        #expect(try planner.due(at: 11) == [binding.id])
        let newest = try Self.answer(&planner, binding, host: 40, .refresh, now: 11)
        let expected = try Self.message(0.4, .refresh)
        #expect(newest == .message(expected))
        #expect(try planner.due(at: 11).isEmpty)
    }

    @Test("A coalesced correction the host takes back is no longer owed")
    func takenBackCorrectionIsNoLongerOwed() throws {
        var planner = try Self.planner(window: 10, budget: 1)
        let binding = try Self.binding()
        _ = try Self.answer(&planner, binding, host: 10, now: 0)
        let spent = try Self.answer(&planner, binding, host: 90, now: 1)
        #expect(spent == .suppressed(.coalesced))
        #expect(try planner.due(at: 11) == [binding.id])
        let takenBack = try Self.answer(&planner, binding, host: 10, now: 2)
        #expect(takenBack == .suppressed(.unchanged))
        #expect(try planner.due(at: 11).isEmpty)
    }
}

// MARK: - Swallowed echoes

extension ControlFeedbackTests {
    @Test("A real move onto a value just sent is swallowed as an echo, yet the host's value is sent back once")
    func swallowedMoveIsCorrectedToTheHostValue() throws {
        var planner = try Self.planner(window: 10, budget: 3)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(40)
        _ = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
        let away = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: truth, now: 102)
        #expect(away == .move)
        let back = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 104)
        #expect(back == .echo)
        #expect(planner.shownStep(of: binding.id) == nil)
        #expect(try planner.due(at: 104) == [binding.id])
        // The controller's own move to 40 stays live through tick 112, so the correction waits for tick 113.
        var waiting: [ControlFeedbackResult] = []
        for tick: UInt64 in 104...112 {
            waiting.append(try Self.answer(&planner, binding, host: 40, .refresh, now: tick))
        }
        #expect(waiting.count == 9)
        #expect(waiting.allSatisfy { $0 == .suppressed(.echo) })
        #expect(try planner.due(at: 112).isEmpty)
        #expect(try planner.due(at: 113) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 40, .refresh, now: 113)
        let expected = try Self.message(0.4, .refresh)
        #expect(corrected == .message(expected))
        #expect(planner.shownStep(of: binding.id) == 51)
        #expect(try planner.due(at: 113).isEmpty)
        let echoed = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: truth, now: 114)
        #expect(echoed == .echo)
        var later: [ControlFeedbackResult] = []
        for tick: UInt64 in 114...140 {
            later.append(try Self.answer(&planner, binding, host: 40, .refresh, now: tick))
        }
        #expect(later.count == 27)
        #expect(later.allSatisfy { $0 == .suppressed(.unchanged) })
    }

    @Test("The same swallowed move after an automation write is corrected to the automation's value at once")
    func swallowedMoveAfterAutomationIsCorrected() throws {
        var planner = try Self.planner(window: 10, budget: 3)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(80)
        _ = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
        let result = ArbitrationResult(outcome: .applied, owner: .automation, value: 80)
        let automated = try planner.plan(automation: result, target: Self.level, bindings: [binding],
                                         truth: truth, now: 102)
        let toldAutomated = try Self.told(binding, 0.8, .automation)
        #expect(automated == [toldAutomated])
        let landed = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 104)
        #expect(landed == .echo)
        #expect(planner.shownStep(of: binding.id) == nil)
        #expect(try planner.due(at: 104) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 80, .refresh, now: 104)
        let expected = try Self.message(0.8, .refresh)
        #expect(corrected == .message(expected))
        #expect(planner.shownStep(of: binding.id) == 102)
        #expect(try planner.due(at: 104).isEmpty)
        let echoed = try planner.receive(.absolute(normalized: 0.8), for: binding, truth: truth, now: 105)
        #expect(echoed == .echo)
        #expect(planner.shownStep(of: binding.id) == 102)
    }

    @Test("An echo of the step the controller is believed to show changes nothing, not even an owed correction")
    func plainEchoLeavesTheTrackAlone() throws {
        var planner = try Self.planner(window: 10, budget: 1)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(80)
        _ = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
        let quiet = planner
        let first = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 104)
        #expect(first == .echo)
        let expectedQuiet = try Self.advanced(quiet, to: 104)
        #expect(planner == expectedQuiet)
        #expect(try planner.due(at: 104).isEmpty)
        let spent = try Self.answer(&planner, binding, host: 80, now: 105)
        #expect(spent == .suppressed(.coalesced))
        let owing = planner
        let second = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 106)
        #expect(second == .echo)
        let expectedOwing = try Self.advanced(owing, to: 106)
        #expect(planner == expectedOwing)
        #expect(try planner.due(at: 110).isEmpty)
        #expect(try planner.due(at: 111) == [binding.id])
    }

    @Test("A repeated echo of the contradicting value at the same tick leaves the planner as it was and owes one")
    func repeatedSwallowedEchoIsIdempotent() throws {
        var planner = try Self.planner(window: 10, budget: 3)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(40)
        _ = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
        _ = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: truth, now: 102)
        let first = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 104)
        #expect(first == .echo)
        let once = planner
        let second = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 104)
        #expect(second == .echo)
        #expect(planner == once)
        let later = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 109)
        #expect(later == .echo)
        #expect(planner.shownStep(of: binding.id) == nil)
        #expect(try planner.due(at: 109) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 40, .refresh, now: 113)
        let expected = try Self.message(0.4, .refresh)
        #expect(corrected == .message(expected))
        #expect(planner.shownStep(of: binding.id) == 51)
    }
}
