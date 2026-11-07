import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Echo ledger

extension ControlFeedbackTests {
    @Test("A sent entry is live through its deadline and expired one tick later")
    func sentEntryExpiryBoundary() {
        var ledger = ControlFeedbackEcho()
        #expect(ledger.sent.isEmpty && ledger.caused.isEmpty)
        ledger.recordSent(step: 5, now: 100, window: 10)
        #expect(ledger.sent == [ControlFeedbackEcho.Entry(step: 5, deadline: 110)])
        #expect(ledger.caused.isEmpty)
        #expect(ledger.isSent(step: 5, at: 100))
        #expect(ledger.isSent(step: 5, at: 110))
        #expect(!ledger.isSent(step: 5, at: 111))
        #expect(!ledger.isSent(step: 6, at: 105))
    }

    @Test("A caused entry reports the latest deadline among the live entries of its step")
    func causedDeadlineIsTheLatestLiveOne() {
        var ledger = ControlFeedbackEcho()
        ledger.recordCaused(step: 5, now: 100, window: 10)
        ledger.recordCaused(step: 5, now: 105, window: 10)
        ledger.recordCaused(step: 9, now: 105, window: 10)
        #expect(ledger.causedDeadline(of: 5, at: 106) == 115)
        #expect(ledger.causedDeadline(of: 5, at: 111) == 115)
        #expect(ledger.causedDeadline(of: 5, at: 115) == 115)
        #expect(ledger.causedDeadline(of: 5, at: 116) == nil)
        #expect(ledger.causedDeadline(of: 7, at: 106) == nil)
        #expect(ledger.sent.isEmpty)
    }

    @Test("Each ring keeps 8 entries and the 9th drops the oldest")
    func ringDepthBoundary() {
        var ledger = ControlFeedbackEcho()
        for step in 0..<8 {
            ledger.recordSent(step: step, now: 0, window: 100)
            ledger.recordCaused(step: step, now: 0, window: 100)
        }
        #expect(ledger.sent.map(\.step) == Array(0..<8))
        #expect(ledger.caused.map(\.step) == Array(0..<8))
        ledger.recordSent(step: 8, now: 0, window: 100)
        ledger.recordCaused(step: 8, now: 0, window: 100)
        #expect(ledger.sent.map(\.step) == Array(1...8))
        #expect(ledger.caused.map(\.step) == Array(1...8))
    }

    @Test("Recording drops expired entries before evicting a live one: N keeps them, N+1 drops them")
    func recordingDropsExpiredFirst() {
        var ledger = ControlFeedbackEcho()
        for step in 0..<8 {
            ledger.recordSent(step: step, now: 0, window: 10)
            ledger.recordCaused(step: step, now: 0, window: 10)
        }
        var atDeadline = ledger
        atDeadline.recordSent(step: 99, now: 10, window: 10)
        atDeadline.recordCaused(step: 99, now: 10, window: 10)
        #expect(atDeadline.sent.map(\.step) == [1, 2, 3, 4, 5, 6, 7, 99])
        #expect(atDeadline.caused.map(\.step) == [1, 2, 3, 4, 5, 6, 7, 99])
        var pastDeadline = ledger
        pastDeadline.recordSent(step: 99, now: 11, window: 10)
        pastDeadline.recordCaused(step: 99, now: 11, window: 10)
        #expect(pastDeadline.sent == [ControlFeedbackEcho.Entry(step: 99, deadline: 21)])
        #expect(pastDeadline.caused == [ControlFeedbackEcho.Entry(step: 99, deadline: 21)])
    }

    @Test("Sending waits until fewer than budget entries are live; a budget below 1 acts as 1")
    func sendableAtFollowsTheBudgetedEntry() {
        var ledger = ControlFeedbackEcho()
        #expect(ledger.sendableAt(budget: 3, now: 0) == nil)
        for step in 0..<3 { ledger.recordSent(step: step, now: UInt64(step), window: 10) }
        // The live deadlines are 10, 11 and 12.
        #expect(ledger.sendableAt(budget: 4, now: 2) == nil)
        #expect(ledger.sendableAt(budget: 3, now: 2) == 11)
        #expect(ledger.sendableAt(budget: 3, now: 10) == 11)
        #expect(ledger.sendableAt(budget: 3, now: 11) == nil)
        #expect(ledger.sendableAt(budget: 2, now: 2) == 12)
        #expect(ledger.sendableAt(budget: 2, now: 11) == 12)
        #expect(ledger.sendableAt(budget: 1, now: 2) == 13)
        #expect(ledger.sendableAt(budget: 1, now: 12) == 13)
        #expect(ledger.sendableAt(budget: 1, now: 13) == nil)
        #expect(ledger.sendableAt(budget: 0, now: 2) == 13)
        #expect(ledger.sendableAt(budget: -1, now: 2) == 13)
    }

    @Test("Deadlines saturate at UInt64.max: the sum fits at N and overflows at N+1")
    func deadlinesSaturate() {
        let top = UInt64.max
        #expect(ControlFeedbackEcho.deadline(from: top - 11, window: 10) == top - 1)
        #expect(ControlFeedbackEcho.deadline(from: top - 10, window: 10) == top)
        #expect(ControlFeedbackEcho.deadline(from: top - 9, window: 10) == top)
        #expect(ControlFeedbackEcho.deadline(from: top, window: 1) == top)
        #expect(ControlFeedbackEcho.following(41) == 42)
        #expect(ControlFeedbackEcho.following(top - 1) == top)
        #expect(ControlFeedbackEcho.following(top) == top)
        var ledger = ControlFeedbackEcho()
        ledger.recordSent(step: 3, now: top - 9, window: 10)
        #expect(ledger.sent == [ControlFeedbackEcho.Entry(step: 3, deadline: top)])
        #expect(ledger.isSent(step: 3, at: top))
        #expect(ledger.sendableAt(budget: 1, now: top) == top)
    }
}

// MARK: - Planner echo

extension ControlFeedbackTests {
    @Test("Own feedback echoed back is an echo, exact or read back from the control's own grid")
    func ownFeedbackEchoedBackIsAnEcho() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let truth = try Self.levelTruth(60)
        let sent = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
        let expected = try Self.message(0.6, .clamp)
        #expect(sent == .message(expected))
        let exact = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 100)
        #expect(exact == .echo)
        let readBack = 76.0 / 127.0
        let quantised = try planner.receive(.absolute(normalized: readBack), for: binding, truth: truth, now: 101)
        #expect(quantised == .echo)
        #expect(planner.shownStep(of: binding.id) == 76)
    }

    @Test("A sent position is an echo through window N and a move at N+1")
    func sentEchoWindowBoundary() throws {
        let cases: [(tick: UInt64, inbound: ControlFeedbackInbound)] = [(110, .echo), (111, .move)]
        for entry in cases {
            var planner = try Self.planner(window: 10)
            let binding = try Self.binding()
            _ = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
            let truth = try Self.levelTruth(60)
            let inbound = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: entry.tick)
            #expect(inbound == entry.inbound)
        }
    }

    @Test("An echo changes nothing but the clock and repeats while its window is open")
    func echoChangesNothingButTheClock() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let truth = try Self.levelTruth(60)
        _ = try Self.answer(&planner, binding, host: 60, .clamp, now: 100)
        let before = planner
        for tick: UInt64 in [100, 103, 110] {
            let inbound = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: tick)
            #expect(inbound == .echo)
        }
        let expected = try Self.advanced(before, to: 110)
        #expect(planner == expected)
    }

    @Test("A host write equal to the controller's own move is an echo through its window, then unchanged")
    func controllerMoveMakesTheHostWriteAnEcho() throws {
        let cases: [(tick: UInt64, why: ControlFeedbackSuppression)] = [(110, .echo), (111, .unchanged)]
        for entry in cases {
            var planner = try Self.planner(window: 10)
            let binding = try Self.binding()
            let truth = try Self.levelTruth(20)
            let move = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 100)
            #expect(move == .move)
            let result = try Self.answer(&planner, binding, host: 50, .clamp, now: entry.tick)
            #expect(result == .suppressed(entry.why))
            #expect(try planner.due(at: entry.tick).isEmpty)
        }
    }

    @Test("A host value different from the controller's move is a correction at the applied position")
    func differentHostValueIsACorrection() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let truth = try Self.levelTruth(20)
        _ = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 100)
        let result = try Self.answer(&planner, binding, host: 40, .clamp, now: 100)
        let expected = try Self.message(0.4, .clamp)
        #expect(result == .message(expected))
        #expect(planner.shownStep(of: binding.id) == 51)
        let echoed = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: truth, now: 101)
        #expect(echoed == .echo)
    }

    @Test("A suppressed echo defers its correction to the end of the window instead of dropping it")
    func echoSuppressionDefersTheCorrection() throws {
        var planner = try Self.planner(window: 10)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(50)
        _ = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 0)
        _ = try planner.receive(.absolute(normalized: 0.7), for: binding, truth: truth, now: 2)
        let held = try Self.answer(&planner, binding, host: 50, .clamp, now: 3)
        #expect(held == .suppressed(.echo))
        #expect(try planner.due(at: 10).isEmpty)
        #expect(try planner.due(at: 11) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 50, .refresh, now: 11)
        let expected = try Self.message(0.5, .refresh)
        #expect(corrected == .message(expected))
        #expect(try planner.due(at: 11).isEmpty)
    }

    @Test("A relative input is a move that records nothing; the wrong kind of input is refused")
    func relativeInputIsAMoveThatRecordsNothing() throws {
        var planner = try Self.planner()
        let encoder = try Self.binding("enc", profile: .twosComplement(width: .seven))
        let fader = try Self.binding("fad")
        let truth = try Self.levelTruth(50)
        let forward = try planner.receive(.relative(delta: 1), for: encoder, truth: truth, now: 1)
        let backward = try planner.receive(.relative(delta: -3), for: encoder, truth: truth, now: 1)
        #expect(forward == .move && backward == .move)
        let wrongAbsolute = try planner.receive(.absolute(normalized: 0.5), for: encoder, truth: truth, now: 1)
        #expect(wrongAbsolute == .refused(.inputMismatch))
        let wrongRelative = try planner.receive(.relative(delta: 1), for: fader, truth: truth, now: 1)
        #expect(wrongRelative == .refused(.inputMismatch))
        #expect(planner.trackedCount == 0)
        let expected = try Self.advanced(Self.planner(), to: 1)
        #expect(planner == expected)
    }

    @Test("Receiving refuses what operation(for:) refuses, judging the host's truth before the input")
    func receiveRefusalsMirrorTheBindingChecks() throws {
        let binding = try Self.binding()
        let healthy = try Self.levelTruth(50)
        let inputs: [(Double, ControlFeedbackInbound)] = [
            (0, .move), (1, .move), (0.5, .move), (1.0.nextUp, .refused(.inputOutOfRange(1.0.nextUp))),
            (-0.5, .refused(.inputOutOfRange(-0.5))), (.nan, .refused(.nonFinite)),
            (.infinity, .refused(.nonFinite)), (-.infinity, .refused(.nonFinite))
        ]
        for (position, expected) in inputs {
            #expect(try Self.hear(.absolute(normalized: position), binding, healthy) == expected)
        }
        let hazard = try Self.truth([Self.descriptor(Self.level, controlClass: .hazardous)], [Self.level: 5])
        let truths: [(ControlHostTruth, ControlBindingRefusal)] = try [
            (Self.truth([], [:]), .targetMissing(Self.level)), (Self.levelTruth(nil), .valueUnavailable(Self.level)),
            (hazard, .unboundableClass(.hazardous)), (Self.levelTruth(.nan), .nonFinite),
            (Self.levelTruth(5, unit: .decibels), .unitMismatch(expected: .percent, found: .decibels))
        ]
        for (truth, refusal) in truths {
            let inbound = try Self.hear(.absolute(normalized: .nan), binding, truth)
            #expect(inbound == .refused(refusal))
        }
        let decibels = try Self.binding("db", unit: .decibels)
        let unit = try Self.hear(.absolute(normalized: 0.5), decibels, healthy)
        #expect(unit == .refused(.unitMismatch(expected: .percent, found: .decibels)))
    }

    @Test("A refused input never creates a track")
    func refusedInputCreatesNoTrack() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let bad: [(ControlInput, ControlHostTruth)] = try [
            (.absolute(normalized: .nan), Self.levelTruth(50)), (.absolute(normalized: 2), Self.levelTruth(50)),
            (.absolute(normalized: 0.5), Self.levelTruth(nil)), (.absolute(normalized: 0.5), Self.levelTruth(.nan))
        ]
        var results: [ControlFeedbackInbound] = []
        for (input, truth) in bad {
            results.append(try planner.receive(input, for: binding, truth: truth, now: 4))
        }
        #expect(results == [.refused(.nonFinite), .refused(.inputOutOfRange(2)),
                            .refused(.valueUnavailable(Self.level)), .refused(.nonFinite)])
        #expect(planner.trackedCount == 0)
        #expect(planner.shownStep(of: binding.id) == nil)
        let expected = try Self.advanced(Self.planner(), to: 4)
        #expect(planner == expected)
    }

    @Test("A refused move still makes the shown step unknown and owes the correction until a plan can answer")
    func refusedMoveStillOwesTheCorrection() throws {
        var planner = try Self.planner(window: 10, budget: 3)
        let binding = try Self.binding()
        let down = try Self.levelTruth(nil)
        let truth = try Self.levelTruth(60)
        _ = try Self.answer(&planner, binding, host: 60, now: 100)
        let refusal = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: down, now: 102)
        #expect(refusal == .refused(.valueUnavailable(Self.level)))
        #expect(planner.shownStep(of: binding.id) == nil)
        #expect(try planner.due(at: 102) == [binding.id])
        let unanswered = try planner.plan([binding], truth: down, reason: .refresh, now: 103)
        #expect(unanswered == [Self.refused(binding, .valueUnavailable(Self.level))])
        #expect(try planner.due(at: 103) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 60, .refresh, now: 104)
        let expected = try Self.message(0.6, .refresh)
        #expect(corrected == .message(expected))
        #expect(planner.shownStep(of: binding.id) == 76)
        #expect(try planner.due(at: 104).isEmpty)
        let before = planner
        let echo = try planner.receive(.absolute(normalized: 0.6), for: binding, truth: truth, now: 105)
        #expect(echo == .echo)
        let unchanged = try Self.advanced(before, to: 105)
        #expect(planner == unchanged)
    }

    @Test("A refused move keeps the echo ledger, so the owed correction still waits for the emit budget")
    func refusedMoveKeepsTheEmitBudget() throws {
        var planner = try Self.planner(window: 10, budget: 1)
        let binding = try Self.binding()
        let down = try Self.levelTruth(nil)
        _ = try Self.answer(&planner, binding, host: 60, now: 100)
        let refusal = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: down, now: 102)
        #expect(refusal == .refused(.valueUnavailable(Self.level)))
        // The host took no move, so a host value on the reported step is not taken for the controller's own move.
        let notCaused = try Self.answer(&planner, binding, host: 40, .refresh, now: 102)
        #expect(notCaused == .suppressed(.coalesced))
        let coalesced = try Self.answer(&planner, binding, host: 60, .refresh, now: 102)
        #expect(coalesced == .suppressed(.coalesced))
        #expect(try planner.due(at: 110).isEmpty)
        #expect(try planner.due(at: 111) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 60, .refresh, now: 111)
        let expected = try Self.message(0.6, .refresh)
        #expect(corrected == .message(expected))
        let settled = try Self.answer(&planner, binding, host: 60, .refresh, now: 112)
        #expect(settled == .suppressed(.unchanged))
    }

    @Test("Receiving admits N bindings and answers tableFull for the N+1st; tracked ones stay answerable")
    func receiveTableBoundary() throws {
        var planner = try Self.planner(bindings: 2)
        let truth = try Self.levelTruth(50)
        let bindings = try ["a", "b", "c"].map { try Self.binding($0) }
        for index in 0..<2 {
            let inbound = try planner.receive(.absolute(normalized: 0.5), for: bindings[index], truth: truth, now: 0)
            #expect(inbound == .move)
        }
        let full = try planner.receive(.absolute(normalized: 0.5), for: bindings[2], truth: truth, now: 0)
        #expect(full == .tableFull(capacity: 2))
        #expect(planner.trackedCount == 2)
        #expect(!planner.isTracked(bindings[2].id))
        let again = try planner.receive(.absolute(normalized: 0.7), for: bindings[0], truth: truth, now: 1)
        #expect(again == .move)
        #expect(planner.shownStep(of: bindings[0].id) == 89)
    }

    @Test("A binding whose source or grid changed starts a fresh track and is told its position again")
    func changedSourceOrGridStartsFresh() throws {
        var planner = try Self.planner()
        let original = try Self.binding("a")
        let rewired = try Self.binding("a", source: "b")
        let finer = try Self.binding("a", profile: .absolute(resolution: 64))
        let steps: [(ControlBinding, UInt64)] = [(original, 0), (rewired, 2), (finer, 4)]
        let truth = try Self.levelTruth(60)
        for (binding, tick) in steps {
            let first = try planner.plan([binding], truth: truth, reason: .scene, now: tick)
            let expected = try Self.told(binding, 0.6, .scene)
            #expect(first == [expected])
            let second = try planner.plan([binding], truth: truth, reason: .scene, now: tick + 1)
            #expect(second == [Self.withheld(binding, .unchanged)])
        }
        #expect(planner.trackedCount == 1)
        #expect(planner.shownStep(of: original.id) == 38)
    }

    @Test("A binding whose grid alone changed starts a fresh track, even where both grids show the same step")
    func changedGridAloneStartsFresh() throws {
        var planner = try Self.planner()
        let coarse = try Self.binding("a", profile: .absolute(resolution: 64))
        let fine = try Self.binding("a", profile: .absolute(resolution: 16_384))
        let truth = try Self.levelTruth(0)
        // Position 0 is step 0 on every grid, so a track kept across the change would find nothing to say.
        let steps: [(ControlBinding, UInt64)] = [(coarse, 0), (fine, 2), (coarse, 4)]
        for (binding, tick) in steps {
            let first = try planner.plan([binding], truth: truth, reason: .scene, now: tick)
            let expected = try Self.told(binding, 0, .scene)
            #expect(first == [expected])
            let second = try planner.plan([binding], truth: truth, reason: .scene, now: tick + 1)
            #expect(second == [Self.withheld(binding, .unchanged)])
        }
        #expect(planner.trackedCount == 1)
        #expect(planner.shownStep(of: coarse.id) == 0)
    }

    @Test("A full table still rebuilds a tracked binding whose source or grid changed, in plan and in receive")
    func fullTableRebuildsATrackedBinding() throws {
        var planner = try Self.planner(bindings: 2)
        let truth = try Self.levelTruth(60)
        let first = try Self.binding("a")
        let second = try Self.binding("b")
        _ = try planner.plan([first, second], truth: truth, reason: .scene, now: 0)
        #expect(planner.trackedCount == 2)
        let rewired = try Self.binding("a", source: "c")
        let finer = try Self.binding("b", profile: .absolute(resolution: 64))
        let rebuilt = try planner.plan([rewired, finer], truth: truth, reason: .refresh, now: 1)
        let toldAgain = try [Self.told(rewired, 0.6, .refresh), Self.told(finer, 0.6, .refresh)]
        #expect(rebuilt == toldAgain)
        #expect(planner.trackedCount == 2)
        let newcomer = try Self.binding("n")
        let refused = try planner.plan([newcomer], truth: truth, reason: .refresh, now: 2)
        #expect(refused == [ControlFeedbackOutcome(binding: newcomer.id, result: .tableFull(capacity: 2))])
        let moved = try Self.binding("a", source: "d")
        let heard = try planner.receive(.absolute(normalized: 0.6), for: moved, truth: truth, now: 3)
        #expect(heard == .move)
        #expect(planner.trackedCount == 2)
        #expect(planner.shownStep(of: moved.id) == 76)
    }
}

// MARK: - Storms

extension ControlFeedbackTests {
    @Test("10_000 alternating host events with echoed feedback stay within the emit budget and converge")
    func echoStormStaysWithinBudgetAndConverges() throws {
        var planner = try Self.planner(window: 14, budget: 3)
        let binding = try Self.binding()
        let low = try Self.levelTruth(25)
        let high = try Self.levelTruth(75)
        var sentTicks: [UInt64] = []
        var misclassified = 0
        for tick in UInt64(0)..<10_000 {
            let truth = tick.isMultiple(of: 2) ? low : high
            let outcomes = try planner.plan([binding], truth: truth, reason: .scene, now: tick)
            guard case .message(let message)? = outcomes.first?.result else { continue }
            sentTicks.append(tick)
            let inbound = try planner.receive(.absolute(normalized: message.position), for: binding,
                                              truth: truth, now: tick)
            if inbound != .echo { misclassified += 1 }
        }
        // A cycle is window + 1 = 15 ticks (odd, so the alternation never lines up with it): three messages at
        // its ticks 0, 1 and 2, then the budget is spent until the first of them expires.
        let oracle = (0..<10_000).filter { $0 % 15 < 3 }.map { UInt64($0) }
        #expect(sentTicks == oracle)
        #expect(sentTicks.count == 2001)
        #expect(misclassified == 0)
        var busiest = 0
        var start = 0
        for end in sentTicks.indices {
            while sentTicks[end] - sentTicks[start] > 14 { start += 1 }
            busiest = max(busiest, end - start + 1)
        }
        #expect(busiest == 3)
        #expect(planner.trackedCount == 1)
        // Tick 9_999 is the 10th tick of its cycle, so its correction toward `high` was coalesced, not dropped.
        #expect(planner.shownStep(of: binding.id) == 32)
        #expect(try planner.due(at: 9_999).isEmpty)
        #expect(try planner.due(at: 10_004).isEmpty)
        #expect(try planner.due(at: 10_005) == [binding.id])
        let settled = try planner.plan([binding], truth: high, reason: .refresh, now: 10_005)
        let refreshed = try Self.told(binding, 0.75, .refresh)
        #expect(settled == [refreshed])
        #expect(planner.shownStep(of: binding.id) == 95)
        #expect(try planner.due(at: 10_005).isEmpty)
        let quiet = try planner.plan([binding], truth: high, reason: .refresh, now: 10_006)
        #expect(quiet == [Self.withheld(binding, .unchanged)])
    }

    @Test("A controller that reports every message back as a move cannot start a loop")
    func reportedBackMovesDoNotLoop() throws {
        var planner = try Self.planner(window: 10)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(60)
        guard case .message(let message) = try Self.answer(&planner, binding, host: 60, now: 0) else {
            Issue.record("The first plan must emit")
            return
        }
        let late = try planner.receive(.absolute(normalized: message.position), for: binding, truth: truth, now: 11)
        #expect(late == .move)
        var later: [ControlFeedbackResult] = []
        for tick: UInt64 in 11..<100 {
            later.append(try Self.answer(&planner, binding, host: 60, now: tick))
        }
        #expect(later.count == 89)
        #expect(!later.contains(where: Self.isMessage))
        #expect(later.prefix(11).allSatisfy { $0 == .suppressed(.echo) })
        #expect(later.dropFirst(11).allSatisfy { $0 == .suppressed(.unchanged) })
        #expect(try planner.due(at: 99).isEmpty)
    }
}
