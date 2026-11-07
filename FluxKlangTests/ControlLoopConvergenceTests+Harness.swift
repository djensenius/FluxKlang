import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The fake loop of the closed-loop convergence harness (#86, I1): a fake host, fake controllers and an integer tick
/// counter around the real `ControlFeedbackPlanner`. Nothing here reads a clock, a socket, MIDI or a random source.
enum LoopHarness {
    /// The only literal limit of the harness: a loop that is not quiet after this many steps did not converge.
    static let stepBound = 64
    static let level = ParameterID(validated: "par.level")
    static let sourceA = ControlSourceID(validated: "ctl.a")
    static let sourceB = ControlSourceID(validated: "ctl.b")
    static let sourceC = ControlSourceID(validated: "ctl.c")
    static let absolute = EncoderProfile.absolute(resolution: 128)
    static let relative = EncoderProfile.binaryOffset(width: .seven)

    enum Outcome: Hashable {
        case converged(steps: Int)
        /// The loop was still busy after `stepBound` steps; `step` is the step that would have been needed next.
        case didNotConverge(step: Int)
    }

    /// How a fake controller answers a message it is shown.
    enum Reaction {
        /// Shows it and says nothing.
        case quiet
        /// A motorised fader: reports the position it was just sent, exactly.
        case reflect
        /// The deliberately looping fake: reports a position two grid steps away from the one it was sent.
        case divergent
    }

    enum Event: Hashable {
        case received(step: Int, binding: BindingID, inbound: ControlFeedbackInbound)
        case planned(step: Int, outcome: ControlFeedbackOutcome)
    }

    struct Delivery: Hashable {
        let step: Int
        let message: ControlFeedbackMessage
    }

    struct Input {
        let binding: ControlBinding
        let input: ControlInput
    }

    static func descriptor(ceiling: Double? = nil, curve: ParameterCurve = .linear,
                           range: ClosedRange<Double> = 0...100) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: level, unit: .percent, lower: range.lowerBound, upper: range.upperBound,
            defaultValue: range.lowerBound, ceiling: ceiling, curve: curve, ramp: .step, controlClass: .live,
            verification: .unverified
        ))
    }

    /// Binding `bnd.<name>` of control `ctl.<source or name>` on `level`; relative profiles step by 1.
    static func binding(_ name: String, source: String? = nil,
                        profile: EncoderProfile = absolute) throws -> ControlBinding {
        try ControlBinding(.init(
            id: BindingID("bnd.\(name)"), source: ControlSourceID("ctl.\(source ?? name)"), target: level,
            unit: .percent, profile: profile, step: profile.isRelative ? 1 : nil, lower: nil, upper: nil,
            pickup: profile.isRelative ? nil : .jump
        ))
    }

    static func policy(bindings: Int = 16, holds: Int = 4, window: UInt64 = 10, timeout: UInt64 = 100,
                       budget: Int = 3) throws -> ControlFeedbackPolicy {
        try ControlFeedbackPolicy(bindingCapacity: bindings, holdCapacity: holds, windowTicks: window,
                                  holdTimeoutTicks: timeout, emitBudget: budget)
    }

    /// A controller report of raw value `raw` on the 128-step absolute profile, decoded by the production profile.
    static func raw(_ raw: Int) throws -> ControlInput { try absolute.decode(raw: raw) }

    /// Reports that alternate between raw 10 and raw 20, so every one is a real move.
    static func alternating(_ index: Int) throws -> ControlInput { try raw(index.isMultiple(of: 2) ? 10 : 20) }

    /// A world whose host holds `par.level` at 0 and whose controllers are `bindings`.
    static func world(_ bindings: [ControlBinding], reaction: Reaction = .reflect, policy: ControlFeedbackPolicy? = nil,
                      writeLimit: Double? = nil, start: Double = 0) throws -> LoopHarnessWorld {
        let catalog = try ParameterCatalog([descriptor()])
        let host = LoopHarnessHost(catalog: catalog, values: [level: start], writeLimit: writeLimit)
        var world = try LoopHarnessWorld(policy: policy ?? self.policy(), bindings: bindings, host: host)
        world.reaction = reaction
        return world
    }

    /// The grid step of a position on the 128-step absolute control.
    static func step(of position: Double) -> Int? { ControlFeedbackEcho.step(of: position, grid: 128) }
}

/// The fake host: the catalog and the current values. `writeLimit` is a ceiling that arrives after the controller
/// computed its write, so the applied value differs from the requested one. `ratchet` is the looping fake: every
/// write lands one grid step above what was asked, wrapping at 100.
struct LoopHarnessHost: Hashable {
    var catalog: ParameterCatalog
    var values: [ParameterID: Double]
    var writeLimit: Double?
    var ratchet = false

    func truth() throws -> ControlHostTruth {
        try ControlHostTruth(
            catalog: catalog, values: values.mapValues { ParameterValue(value: $0, unit: .percent) }
        )
    }

    /// Applies one controller input through the binding; `true` when the host value was written.
    mutating func apply(_ binding: ControlBinding, _ input: ControlInput) throws -> Bool {
        let (descriptor, current) = try truth().target(binding.target)
        guard case .set(let id, let value)? = try binding.operation(for: input, current: current,
                                                                    descriptor: descriptor) else { return false }
        var applied = writeLimit.map { min(value.value, $0) } ?? value.value
        if ratchet { applied = (applied + 100.0 / 127.0).truncatingRemainder(dividingBy: 100) }
        values[id] = applied
        return true
    }
}

/// The closed loop: controllers and host exchange values through the real planner, one step at a time.
struct LoopHarnessWorld {
    var planner: ControlFeedbackPlanner
    var host: LoopHarnessHost
    var bindings: [ControlBinding]
    var reaction = LoopHarness.Reaction.reflect
    /// The fake clock: an integer, advanced by one at the end of every step.
    var tick: UInt64 = 0
    var step = 0
    var outbox: [LoopHarness.Input] = []
    /// A plan is owed with this label (the host value changed).
    var owed: ControlFeedbackReason?
    /// When set, every plan answers at this automation value instead of host truth.
    var automation: Double?
    var trace: [LoopHarness.Event] = []
    /// What each controller shows: the position of the last message it received.
    var shown: [BindingID: Double] = [:]
    var osc: LoopHarnessOSC

    init(policy: ControlFeedbackPolicy, bindings: [ControlBinding], host: LoopHarnessHost) throws {
        planner = ControlFeedbackPlanner(policy: policy)
        self.host = host
        self.bindings = bindings
        osc = try LoopHarnessOSC(catalog: host.catalog)
    }

    var deliveries: [LoopHarness.Delivery] {
        trace.compactMap { event in
            guard case .planned(let step, let outcome) = event, case .message(let message) = outcome.result else {
                return nil
            }
            return LoopHarness.Delivery(step: step, message: message)
        }.sorted { ($0.step, $0.message.binding) < ($1.step, $1.message.binding) }
    }

    func results(of binding: ControlBinding) -> [ControlFeedbackResult] {
        trace.compactMap { event in
            guard case .planned(_, let outcome) = event, outcome.binding == binding.id else { return nil }
            return outcome.result
        }
    }

    func inbound(of binding: ControlBinding) -> [ControlFeedbackInbound] {
        trace.compactMap { event in
            guard case .received(_, let id, let inbound) = event, id == binding.id else { return nil }
            return inbound
        }
    }

    mutating func queue(_ binding: ControlBinding, _ input: ControlInput) {
        outbox.append(LoopHarness.Input(binding: binding, input: input))
    }

    mutating func hostChanged(to value: Double, because reason: ControlFeedbackReason) {
        host.values[LoopHarness.level] = value
        owed = reason
    }

    /// Whether nothing is pending on either side: no queued report, no owed plan, no correction owed in the planner.
    func isQuiescent() throws -> Bool {
        try outbox.isEmpty && osc.outbox.isEmpty && owed == nil && planner.due(at: .max).isEmpty
    }

    /// Steps until quiescent, at most `stepBound` steps from now.
    @discardableResult
    mutating func run() throws -> LoopHarness.Outcome {
        let start = step
        while true {
            if try isQuiescent() { return .converged(steps: step - start) }
            if step - start >= LoopHarness.stepBound { return .didNotConverge(step: step - start + 1) }
            try stepOnce()
        }
    }

    /// A controller connects: every control is told the host position; the controllers stay quiet meanwhile.
    @discardableResult
    mutating func connect() throws -> LoopHarness.Outcome {
        let saved = reaction
        reaction = .quiet
        defer { reaction = saved }
        owed = .refresh
        return try run()
    }

    /// One step: the next OSC datagram, the next controller report, then a plan when one is owed or due.
    mutating func stepOnce() throws {
        step += 1
        if !osc.outbox.isEmpty { try ingestOSC(osc.outbox.removeFirst()) }
        if !outbox.isEmpty { try deliver(outbox.removeFirst()) }
        let due = try planner.due(at: tick)
        if owed != nil || !due.isEmpty {
            let reason = owed ?? .refresh
            owed = nil
            for outcome in try plan(reason) { try record(outcome) }
        }
        tick += 1
    }

    private mutating func plan(_ reason: ControlFeedbackReason) throws -> [ControlFeedbackOutcome] {
        let truth = try host.truth()
        guard let value = automation else {
            return try planner.plan(bindings, truth: truth, reason: reason, now: tick)
        }
        let result = ArbitrationResult(outcome: .applied, owner: .automation, value: value)
        return try planner.plan(automation: result, target: LoopHarness.level, bindings: bindings, truth: truth,
                                now: tick)
    }

    private mutating func deliver(_ item: LoopHarness.Input) throws {
        let inbound = try planner.receive(item.input, for: item.binding, truth: host.truth(), now: tick)
        trace.append(.received(step: step, binding: item.binding.id, inbound: inbound))
        if inbound == .move, try host.apply(item.binding, item.input) { owed = .clamp }
    }

    mutating func record(_ outcome: ControlFeedbackOutcome) throws {
        trace.append(.planned(step: step, outcome: outcome))
        guard case .message(let message) = outcome.result, let binding = bindings.first(where: {
            $0.id == message.binding
        }) else { return }
        shown[message.binding] = message.position
        switch reaction {
        case .quiet: break
        case .reflect: queue(binding, .absolute(normalized: message.position))
        case .divergent:
            let target = ((LoopHarness.step(of: message.position) ?? 0) + 2) % 128
            queue(binding, .absolute(normalized: Double(target) / 127))
        }
        try osc.remoteSaw(message)
    }
}
