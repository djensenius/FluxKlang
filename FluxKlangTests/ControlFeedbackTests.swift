import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Controller feedback: host truth in, neutral correction messages out. The suite is split across `+Echo`,
/// `+TouchHold` and `+Corrections`; every fixture is nested here so no name leaves the suite.
#if os(macOS)
@Suite("Control feedback", .productionAccessAudit)
#else
@Suite("Control feedback")
#endif
struct ControlFeedbackTests {
    static let level = ParameterID(validated: "par.level")
    static let other = ParameterID(validated: "par.other")
    static let missing = ParameterID(validated: "par.missing")
    static let sourceA = ControlSourceID(validated: "ctl.a")
    static let sourceB = ControlSourceID(validated: "ctl.b")
    static let sourceC = ControlSourceID(validated: "ctl.c")

    // MARK: Fixtures

    /// A live parameter: percent 0...100 unless told otherwise; its default is the lower bound.
    static func descriptor(_ id: ParameterID, unit: ParameterUnit = .percent, range: ClosedRange<Double> = 0...100,
                           curve: ParameterCurve = .linear, ceiling: Double? = nil,
                           controlClass: ControlClass = .live) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
            ceiling: ceiling, curve: curve, ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    /// Binding `bnd.<name>` of control `ctl.<source or name>`; relative profiles step by 1, absolute ones jump.
    static func binding(_ name: String = "a", source: String? = nil,
                        target: ParameterID = ControlFeedbackTests.level, unit: ParameterUnit = .percent,
                        profile: EncoderProfile = .absolute(resolution: 128)) throws -> ControlBinding {
        try ControlBinding(.init(
            id: BindingID("bnd.\(name)"), source: ControlSourceID("ctl.\(source ?? name)"), target: target,
            unit: unit, profile: profile, step: profile.isRelative ? 1 : nil, lower: nil, upper: nil,
            pickup: profile.isRelative ? nil : .jump
        ))
    }

    /// `count` absolute bindings `bnd.n0000`..., all on `level` and the control `ctl.bulk`.
    static func bulk(_ count: Int) throws -> [ControlBinding] {
        try (0..<count).map { index in
            try ControlBinding(.init(
                id: BindingID("bnd.n" + String(format: "%04d", index)), source: ControlSourceID("ctl.bulk"),
                target: level, unit: .percent, profile: .absolute(resolution: 128), step: nil, lower: nil,
                upper: nil, pickup: .jump
            ))
        }
    }

    /// Host truth whose values carry each listed descriptor's unit.
    static func truth(_ descriptors: [ParameterDescriptor],
                      _ values: [ParameterID: Double]) throws -> ControlHostTruth {
        let catalog = try ParameterCatalog(descriptors)
        let typed = values.reduce(into: [ParameterID: ParameterValue]()) { result, entry in
            result[entry.key] = ParameterValue(value: entry.value, unit: catalog[entry.key]?.unit ?? .percent)
        }
        return try ControlHostTruth(catalog: catalog, values: typed)
    }

    /// Host truth with the percent parameter `level` at `value` (no value when `nil`), reported in `unit`.
    static func levelTruth(_ value: Double?, unit: ParameterUnit = .percent) throws -> ControlHostTruth {
        let catalog = try ParameterCatalog([descriptor(level)])
        let values = value.map { [level: ParameterValue(value: $0, unit: unit)] } ?? [:]
        return try ControlHostTruth(catalog: catalog, values: values)
    }

    static func policy(bindings: Int = 16, holds: Int = 4, window: UInt64 = 10, timeout: UInt64 = 100,
                       budget: Int = 3) throws -> ControlFeedbackPolicy {
        try ControlFeedbackPolicy(bindingCapacity: bindings, holdCapacity: holds, windowTicks: window,
                                  holdTimeoutTicks: timeout, emitBudget: budget)
    }

    static func planner(bindings: Int = 16, holds: Int = 4, window: UInt64 = 10, timeout: UInt64 = 100,
                        budget: Int = 3) throws -> ControlFeedbackPlanner {
        let bounds = try policy(bindings: bindings, holds: holds, window: window, timeout: timeout, budget: budget)
        return ControlFeedbackPlanner(policy: bounds)
    }

    /// The refusal a policy with these arguments throws, or `nil` when it is valid.
    static func policyRefusal(_ bindings: Int, _ holds: Int, _ window: UInt64, _ timeout: UInt64,
                              _ budget: Int) -> ControlFeedbackRefusal? {
        do throws(ControlFeedbackRefusal) {
            _ = try ControlFeedbackPolicy(bindingCapacity: bindings, holdCapacity: holds, windowTicks: window,
                                          holdTimeoutTicks: timeout, emitBudget: budget)
            return nil
        } catch {
            return error
        }
    }

    /// A message for `bnd.a` of `ctl.a`.
    static func message(_ position: Double, _ reason: ControlFeedbackReason = .scene) throws -> ControlFeedbackMessage {
        try ControlFeedbackMessage(binding: BindingID(validated: "bnd.a"), source: sourceA, position: position,
                                   reason: reason)
    }

    /// The outcome expected when `binding` is told `position`.
    static func told(_ binding: ControlBinding, _ position: Double,
                     _ reason: ControlFeedbackReason) throws -> ControlFeedbackOutcome {
        let message = try ControlFeedbackMessage(binding: binding.id, source: binding.source, position: position,
                                                 reason: reason)
        return ControlFeedbackOutcome(binding: binding.id, result: .message(message))
    }

    static func withheld(_ binding: ControlBinding, _ why: ControlFeedbackSuppression) -> ControlFeedbackOutcome {
        ControlFeedbackOutcome(binding: binding.id, result: .suppressed(why))
    }

    static func refused(_ binding: ControlBinding, _ refusal: ControlBindingRefusal) -> ControlFeedbackOutcome {
        ControlFeedbackOutcome(binding: binding.id, result: .refused(refusal))
    }

    /// Plans the single `binding` against `level` at `value` and returns its one result.
    static func answer(_ planner: inout ControlFeedbackPlanner, _ binding: ControlBinding, host value: Double,
                       _ reason: ControlFeedbackReason = .scene, now: UInt64) throws -> ControlFeedbackResult {
        let outcomes = try planner.plan([binding], truth: levelTruth(value), reason: reason, now: now)
        return try #require(outcomes.first).result
    }

    static func isMessage(_ result: ControlFeedbackResult) -> Bool {
        if case .message = result { return true }
        return false
    }

    /// What a fresh planner says about `input` for `binding` against `truth`.
    static func hear(_ input: ControlInput, _ binding: ControlBinding,
                     _ truth: ControlHostTruth) throws -> ControlFeedbackInbound {
        var planner = try Self.planner()
        return try planner.receive(input, for: binding, truth: truth, now: 0)
    }

    /// A copy of `planner` with nothing changed but its clock: an empty plan call moves only `lastTick`.
    static func advanced(_ planner: ControlFeedbackPlanner, to tick: UInt64) throws -> ControlFeedbackPlanner {
        var copy = planner
        _ = try copy.plan([], truth: levelTruth(0), reason: .refresh, now: tick)
        return copy
    }

    /// Every ordering of `items`.
    static func permutations<Element>(_ items: [Element]) -> [[Element]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[Element]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }
}

// MARK: - Policy

extension ControlFeedbackTests {
    @Test("Binding capacity accepts 1 and 4096; 0, -1 and 4097 are refused")
    func bindingCapacityBoundaries() throws {
        #expect(try Self.policy(bindings: 1).bindingCapacity == 1)
        #expect(try Self.policy(bindings: 4096).bindingCapacity == 4096)
        for bad in [0, -1, 4097] {
            #expect(throws: ControlFeedbackRefusal.invalidBindingCapacity(bad)) { try Self.policy(bindings: bad) }
        }
    }

    @Test("Hold capacity accepts 1 and 4096; 0, -1 and 4097 are refused")
    func holdCapacityBoundaries() throws {
        #expect(try Self.policy(holds: 1).holdCapacity == 1)
        #expect(try Self.policy(holds: 4096).holdCapacity == 4096)
        for bad in [0, -1, 4097] {
            #expect(throws: ControlFeedbackRefusal.invalidHoldCapacity(bad)) { try Self.policy(holds: bad) }
        }
    }

    @Test("Window and hold timeout accept 1 and 3_600_000 ticks; 0 and 3_600_001 are refused")
    func tickBoundaries() throws {
        for ticks: UInt64 in [1, 3_600_000] {
            #expect(try Self.policy(window: ticks).windowTicks == ticks)
            #expect(try Self.policy(timeout: ticks).holdTimeoutTicks == ticks)
        }
        for bad: UInt64 in [0, 3_600_001] {
            #expect(throws: ControlFeedbackRefusal.invalidWindow(bad)) { try Self.policy(window: bad) }
            #expect(throws: ControlFeedbackRefusal.invalidHoldTimeout(bad)) { try Self.policy(timeout: bad) }
        }
    }

    @Test("Emit budget accepts 1 and the ledger depth 8; 0, -1 and 9 are refused")
    func emitBudgetBoundaries() throws {
        #expect(try Self.policy(budget: 1).emitBudget == 1)
        #expect(try Self.policy(budget: 8).emitBudget == 8)
        for bad in [0, -1, 9] {
            #expect(throws: ControlFeedbackRefusal.invalidEmitBudget(bad)) { try Self.policy(budget: bad) }
        }
    }

    @Test("A policy with several bad arguments reports the first one in declaration order")
    func policyChecksArgumentsInOrder() {
        #expect(Self.policyRefusal(0, 0, 0, 0, 0) == .invalidBindingCapacity(0))
        #expect(Self.policyRefusal(1, 0, 0, 0, 0) == .invalidHoldCapacity(0))
        #expect(Self.policyRefusal(1, 1, 0, 0, 0) == .invalidWindow(0))
        #expect(Self.policyRefusal(1, 1, 1, 0, 0) == .invalidHoldTimeout(0))
        #expect(Self.policyRefusal(1, 1, 1, 1, 0) == .invalidEmitBudget(0))
        #expect(Self.policyRefusal(1, 1, 1, 1, 1) == nil)
    }

    @Test("Policy limits come from their sources: the host truth cap, one hour of ticks and the ledger depth")
    func policyLimits() {
        #expect(ControlFeedbackPolicy.maximumCapacity == ControlHostTruth.maximumValues)
        #expect(ControlFeedbackPolicy.maximumCapacity == 4096)
        #expect(ControlFeedbackPolicy.maximumTicks == 3_600_000)
        #expect(ControlFeedbackPolicy.maximumEmitBudget == ControlFeedbackEcho.depth)
        #expect(ControlFeedbackEcho.depth == 8)
    }
}

// MARK: - Message

extension ControlFeedbackTests {
    @Test("A message keeps exactly the binding, source, position and reason it was built with")
    func messageKeepsItsFields() throws {
        let message = try Self.message(0.25, .automation)
        #expect(message.binding == BindingID(validated: "bnd.a"))
        #expect(message.source == Self.sourceA)
        #expect(message.position == 0.25)
        #expect(message.reason == .automation)
        #expect(try Self.message(0.25, .automation) != Self.message(0.25, .scene))
        #expect(ControlFeedbackReason.allCases == [.clamp, .scene, .automation, .refresh, .release])
    }

    @Test("A message accepts 0, 1 and the positions just inside them")
    func messageAcceptsTheClosedUnitInterval() throws {
        let positions: [Double] = [0, 1, 0.5, .leastNonzeroMagnitude, 1.0.nextDown]
        for position in positions {
            #expect(try Self.message(position).position == position)
        }
    }

    @Test("A message refuses positions just outside 0...1")
    func messageRefusesOutsideTheUnitInterval() {
        let positions: [Double] = [-.leastNonzeroMagnitude, 1.0.nextUp, -1, 2, -.greatestFiniteMagnitude]
        for position in positions {
            #expect(throws: ControlBindingRefusal.inputOutOfRange(position)) { try Self.message(position) }
        }
    }

    @Test("A message refuses NaN and infinities as non-finite")
    func messageRefusesNonFinitePositions() {
        for position in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ControlBindingRefusal.nonFinite) { try Self.message(position) }
        }
    }
}

// MARK: - Grid

extension ControlFeedbackTests {
    @Test("Each encoder profile declares the grid its feedback is compared on")
    func profilesDeclareTheirFeedbackGrid() {
        #expect(EncoderProfile.absolute(resolution: 2).feedbackGrid == 2)
        #expect(EncoderProfile.absolute(resolution: 128).feedbackGrid == 128)
        #expect(EncoderProfile.absolute(resolution: 16384).feedbackGrid == 16384)
        #expect(EncoderProfile.binaryOffset(width: .seven).feedbackGrid == 128)
        #expect(EncoderProfile.twosComplement(width: .seven).feedbackGrid == 128)
        #expect(EncoderProfile.signMagnitude(width: .fourteen).feedbackGrid == 16384)
        #expect(EncoderProfile.binaryOffset(width: .fourteen).feedbackGrid == 16384)
    }

    @Test("A position lands on the nearest step of the grid, halves away from zero")
    func stepRoundsOnTheGrid() {
        #expect(ControlFeedbackEcho.step(of: 0, grid: 128) == 0)
        #expect(ControlFeedbackEcho.step(of: 1, grid: 128) == 127)
        #expect(ControlFeedbackEcho.step(of: 0.5, grid: 128) == 64)
        #expect(ControlFeedbackEcho.step(of: 0.25, grid: 128) == 32)
        #expect(ControlFeedbackEcho.step(of: 0.6, grid: 128) == 76)
        #expect(ControlFeedbackEcho.step(of: 0.4, grid: 128) == 51)
        #expect(ControlFeedbackEcho.step(of: 0.5, grid: 2) == 1)
        #expect(ControlFeedbackEcho.step(of: 0.4999, grid: 2) == 0)
        #expect(ControlFeedbackEcho.step(of: 1, grid: 16384) == 16383)
        #expect(ControlFeedbackEcho.step(of: 0.6, grid: 16384) == 9830)
        #expect(ControlFeedbackEcho.step(of: .leastNonzeroMagnitude, grid: 128) == 0)
        #expect(ControlFeedbackEcho.step(of: 1.0.nextDown, grid: 128) == 127)
    }

    @Test("A step is never guessed: positions outside 0...1, non-finite ones and grids below 2 have none")
    func stepRefusesWhatItCannotPlace() {
        let outside: [Double] = [-.leastNonzeroMagnitude, 1.0.nextUp, -1, 2, .nan, .infinity, -.infinity]
        for position in outside {
            #expect(ControlFeedbackEcho.step(of: position, grid: 128) == nil)
        }
        for grid in [1, 0, -1, Int.min] {
            #expect(ControlFeedbackEcho.step(of: 0.5, grid: grid) == nil)
            #expect(ControlFeedbackEcho.step(of: 0, grid: grid) == nil)
        }
        #expect(ControlFeedbackEcho.step(of: 0, grid: 2) == 0)
    }
}

// MARK: - Call shape

extension ControlFeedbackTests {
    @Test("A refused plan call names the first failing check and leaves the planner equal")
    func planChecksInOrder() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let truth = try Self.levelTruth(40)
        _ = try planner.plan([binding], truth: truth, reason: .scene, now: 5)
        let before = planner
        let twice = [binding, binding]
        #expect(throws: ControlFeedbackRefusal.tickRegressed(last: 5, now: 4)) {
            try planner.plan(twice, truth: truth, reason: .release, now: 4)
        }
        #expect(throws: ControlFeedbackRefusal.reasonNotPlannable(.release)) {
            try planner.plan(twice, truth: truth, reason: .release, now: 5)
        }
        let crowd = Array(repeating: binding, count: 4097)
        #expect(throws: ControlFeedbackRefusal.tooManyBindings(4097)) {
            try planner.plan(crowd, truth: truth, reason: .scene, now: 5)
        }
        #expect(throws: ControlFeedbackRefusal.duplicateBinding(binding.id)) {
            try planner.plan(twice, truth: truth, reason: .scene, now: 5)
        }
        #expect(planner == before)
    }

    @Test("A call accepts 4096 bindings and refuses 4097, leaving the planner equal")
    func bindingsPerCallBoundary() throws {
        let truth = try Self.levelTruth(40)
        var planner = try Self.planner(bindings: 4096)
        let full = try Self.bulk(4096)
        let outcomes = try planner.plan(full, truth: truth, reason: .scene, now: 0)
        #expect(outcomes.map(\.binding) == full.map(\.id))
        #expect(outcomes.allSatisfy { $0.result == .message(Self.bulkMessage($0.binding)) })
        #expect(planner.trackedCount == 4096)
        let before = planner
        let tooMany = try Self.bulk(4097)
        #expect(throws: ControlFeedbackRefusal.tooManyBindings(4097)) {
            try planner.plan(tooMany, truth: truth, reason: .scene, now: 1)
        }
        #expect(planner == before)
    }

    /// The message a `bulk` binding is told when `level` is 40 percent.
    static func bulkMessage(_ id: BindingID, _ reason: ControlFeedbackReason = .scene) -> ControlFeedbackMessage {
        do {
            return try ControlFeedbackMessage(binding: id, source: ControlSourceID("ctl.bulk"), position: 0.4,
                                              reason: reason)
        } catch {
            preconditionFailure("Invalid fixture message: \(error)")
        }
    }

    @Test("Release and automation planning refuse 4097 bindings and a repeated ID like plan, changing nothing")
    func otherEntryPointsShareTheCallShapeChecks() throws {
        let truth = try Self.levelTruth(40)
        let bulkSource = ControlSourceID(validated: "ctl.bulk")
        let full = try Self.bulk(4096)
        let crowd = try Self.bulk(4097)
        let twice = try Self.bulk(1) + Self.bulk(1)
        var releasing = try Self.planner(bindings: 4096)
        _ = try releasing.touch(bulkSource, now: 0)
        let touched = releasing
        #expect(throws: ControlFeedbackRefusal.tooManyBindings(4097)) {
            try releasing.release(bulkSource, bindings: crowd, truth: truth, now: 1)
        }
        #expect(throws: ControlFeedbackRefusal.duplicateBinding(twice[0].id)) {
            try releasing.release(bulkSource, bindings: twice, truth: truth, now: 1)
        }
        #expect(releasing == touched)
        #expect(releasing.holds.isHeld(bulkSource, at: 1))
        let released = try releasing.release(bulkSource, bindings: full, truth: truth, now: 1)
        #expect(released.map(\.binding) == full.map(\.id))
        #expect(released.allSatisfy { $0.result == .message(Self.bulkMessage($0.binding, .release)) })

        var automated = try Self.planner(bindings: 4096)
        let fresh = automated
        let value = ArbitrationResult(outcome: .applied, owner: .automation, value: 40)
        #expect(throws: ControlFeedbackRefusal.tooManyBindings(4097)) {
            try automated.plan(automation: value, target: Self.level, bindings: crowd, truth: truth, now: 1)
        }
        #expect(throws: ControlFeedbackRefusal.duplicateBinding(twice[0].id)) {
            try automated.plan(automation: value, target: Self.level, bindings: twice, truth: truth, now: 1)
        }
        #expect(automated == fresh)
        let answered = try automated.plan(automation: value, target: Self.level, bindings: full, truth: truth, now: 1)
        #expect(answered.map(\.binding) == full.map(\.id))
        #expect(answered.allSatisfy { $0.result == .message(Self.bulkMessage($0.binding, .automation)) })
    }

    @Test("The smallest repeated binding ID is reported whatever the input order")
    func duplicateReportsTheSmallestID() throws {
        let truth = try Self.levelTruth(40)
        let names = ["a", "b", "c", "d"]
        let bindings = try names.map { try Self.binding($0) }
        let orders = [[3, 2, 1, 0, 2, 3], [2, 3, 0, 1, 3, 2], [3, 3, 2, 2, 1, 0], [0, 1, 2, 3, 3, 2]]
        for order in orders {
            var planner = try Self.planner()
            let before = planner
            let input = order.map { bindings[$0] }
            #expect(throws: ControlFeedbackRefusal.duplicateBinding(bindings[2].id)) {
                try planner.plan(input, truth: truth, reason: .scene, now: 3)
            }
            #expect(planner == before)
        }
    }
}

// MARK: - Refused reports

extension ControlFeedbackTests {
    @Test("A refused report changes nothing unless it contradicts an existing track of the same source and grid")
    func refusedReportOnlyContradictsAnExistingTrack() throws {
        struct Case {
            let planned: ControlBinding?
            let binding: ControlBinding
            let input: ControlInput
            let truth: ControlHostTruth
            let refusal: ControlBindingRefusal
        }
        let fader = try Self.binding()
        let encoder = try Self.binding("enc", profile: .twosComplement(width: .seven))
        let rewired = try Self.binding("a", source: "b")
        let finer = try Self.binding("a", profile: .absolute(resolution: 64))
        let down = try Self.levelTruth(nil)
        let healthy = try Self.levelTruth(60)
        let low = ControlInput.absolute(normalized: 0.4)
        let believed = ControlInput.absolute(normalized: 0.6)
        let unavailable = ControlBindingRefusal.valueUnavailable(Self.level)
        let cases = [
            Case(planned: nil, binding: fader, input: low, truth: down, refusal: unavailable),
            Case(planned: fader, binding: fader, input: believed, truth: down, refusal: unavailable),
            Case(planned: fader, binding: fader, input: .absolute(normalized: .nan), truth: healthy,
                 refusal: .nonFinite),
            Case(planned: fader, binding: fader, input: .absolute(normalized: 2), truth: healthy,
                 refusal: .inputOutOfRange(2)),
            Case(planned: fader, binding: fader, input: .relative(delta: 1), truth: healthy,
                 refusal: .inputMismatch),
            Case(planned: encoder, binding: encoder, input: .absolute(normalized: 0.5), truth: healthy,
                 refusal: .inputMismatch),
            Case(planned: fader, binding: rewired, input: low, truth: down, refusal: unavailable),
            Case(planned: fader, binding: finer, input: low, truth: down, refusal: unavailable)
        ]
        for item in cases {
            var planner = try Self.planner()
            if let planned = item.planned { _ = try Self.answer(&planner, planned, host: 60, now: 100) }
            let before = planner
            let inbound = try planner.receive(item.input, for: item.binding, truth: item.truth, now: 102)
            #expect(inbound == .refused(item.refusal))
            let unchanged = try Self.advanced(before, to: 102)
            #expect(planner == unchanged)
            #expect(planner.trackedCount == (item.planned == nil ? 0 : 1))
        }
    }

    @Test("Whatever the host refuses, a report that contradicts the shown step still owes the correction")
    func everyHostRefusalOwesTheCorrection() throws {
        let binding = try Self.binding()
        let hazard = try Self.truth([Self.descriptor(Self.level, controlClass: .hazardous)], [Self.level: 5])
        let truths: [(ControlHostTruth, ControlBindingRefusal)] = try [
            (Self.truth([], [:]), .targetMissing(Self.level)), (Self.levelTruth(nil), .valueUnavailable(Self.level)),
            (hazard, .unboundableClass(.hazardous)), (Self.levelTruth(.nan), .nonFinite),
            (Self.levelTruth(5, unit: .decibels), .unitMismatch(expected: .percent, found: .decibels))
        ]
        for (truth, refusal) in truths {
            var planner = try Self.planner()
            _ = try Self.answer(&planner, binding, host: 60, now: 100)
            let inbound = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: truth, now: 102)
            #expect(inbound == .refused(refusal))
            #expect(planner.shownStep(of: binding.id) == nil)
            #expect(try planner.due(at: 102) == [binding.id])
        }
    }
}
