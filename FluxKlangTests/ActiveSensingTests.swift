import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("MIDI Active Sensing observer", .productionAccessAudit)
#else
@Suite("MIDI Active Sensing observer")
#endif
struct ActiveSensingTests {
    static let inputSeven = MIDIInputID(7)
    static let inputNine = MIDIInputID(9)
    static let sensing = MIDI1Event.realTime(status: 0xFE)
    static let reset = MIDI1Event.realTime(status: 0xFF)
    static let channelEvent = MIDI1Event.channel(status: 0x90, data1: 60, data2: 100)

    /// Every event kind that is neither 0xFE nor 0xFF, with a label for failure messages.
    static let otherEvents: [(label: String, event: MIDI1Event)] = [
        ("note on", channelEvent),
        ("program change", .channel(status: 0xC3, data1: 5, data2: nil)),
        ("song position", .systemCommon(status: 0xF2, data1: 1, data2: 2)),
        ("tune request", .systemCommon(status: 0xF6, data1: nil, data2: nil)),
        ("sysEx", .sysEx(payload: [0x7E, 0x7F, 0x09])),
        ("empty sysEx", .sysEx(payload: [])),
        ("timing clock", .realTime(status: 0xF8)),
        ("start", .realTime(status: 0xFA)),
        ("continue", .realTime(status: 0xFB)),
        ("stop", .realTime(status: 0xFC)),
        ("undefined 0xFD", .realTime(status: 0xFD))
    ]

    /// One call of the scripted sequence: an event (or a bare poll) at a tick, and the expected result.
    struct ScriptStep {
        let event: MIDI1Event?
        let tick: UInt64
        let outcome: ActiveSensingOutcome
        let phase: ActiveSensingPhase

        init(_ event: MIDI1Event?, _ tick: UInt64, _ outcome: ActiveSensingOutcome, _ phase: ActiveSensingPhase) {
            self.event = event
            self.tick = tick
            self.outcome = outcome
            self.phase = phase
        }
    }

    static func at(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    static func policy(
        _ timeout: UInt64 = 100,
        _ action: ActiveSensingLossAction = .reportOnly
    ) throws -> ActiveSensingPolicy {
        try ActiveSensingPolicy.make(timeoutTicks: timeout, lossAction: action)
    }

    static func observer(
        timeout: UInt64 = 100,
        action: ActiveSensingLossAction = .reportOnly,
        input: MIDIInputID = inputSeven
    ) throws -> ActiveSensingObserver {
        ActiveSensingObserver(input: input, policy: try policy(timeout, action))
    }

    /// An observer armed by a 0xFE at `ticks`.
    static func armed(
        timeout: UInt64 = 100,
        action: ActiveSensingLossAction = .reportOnly,
        input: MIDIInputID = inputSeven,
        at ticks: UInt64 = 0
    ) throws -> ActiveSensingObserver {
        var observer = try observer(timeout: timeout, action: action, input: input)
        _ = try observer.observe(sensing, at: at(ticks))
        return observer
    }

    static func lost(_ input: MIDIInputID = inputSeven, request: Bool = false) -> ActiveSensingOutcome {
        .lost(input: input, requestInputLost: request)
    }

    @Test
    func policyAcceptsTimeoutOneAndTheMaximum() throws {
        let smallest = try ActiveSensingPolicy.make(timeoutTicks: 1, lossAction: .reportOnly)
        let largest = try ActiveSensingPolicy.make(timeoutTicks: 281_474_976_710_656, lossAction: .requestInputLost)
        #expect(smallest.timeoutTicks == 1)
        #expect(smallest.lossAction == .reportOnly)
        #expect(largest.timeoutTicks == 281_474_976_710_656)
        #expect(largest.lossAction == .requestInputLost)
        #expect(ActiveSensingPolicy.maximumTimeoutTicks == 281_474_976_710_656)
    }

    @Test
    func policyRefusesZeroOneAboveTheMaximumAndUInt64Max() {
        #expect(throws: ActiveSensingRefusal.invalidTimeout(0)) {
            try ActiveSensingPolicy.make(timeoutTicks: 0, lossAction: .reportOnly)
        }
        #expect(throws: ActiveSensingRefusal.invalidTimeout(281_474_976_710_657)) {
            try ActiveSensingPolicy.make(timeoutTicks: 281_474_976_710_657, lossAction: .requestInputLost)
        }
        #expect(throws: ActiveSensingRefusal.invalidTimeout(UInt64.max)) {
            try ActiveSensingPolicy.make(timeoutTicks: UInt64.max, lossAction: .reportOnly)
        }
    }

    @Test
    func policyKeepsTheLossActionTheCallerChose() throws {
        #expect(try Self.policy(50, .reportOnly).lossAction == .reportOnly)
        #expect(try Self.policy(50, .requestInputLost).lossAction == .requestInputLost)
        #expect(try Self.policy(50, .reportOnly) != Self.policy(50, .requestInputLost))
        #expect(try Self.policy(50, .reportOnly) != Self.policy(51, .reportOnly))
    }

    @Test
    func freshObserverIsUnarmedWithNoLastTickAndKeepsItsInputAndPolicy() throws {
        let observer = try Self.observer(timeout: 77, action: .requestInputLost, input: Self.inputNine)
        #expect(observer.phase == .unarmed)
        #expect(observer.lastTick == nil)
        #expect(observer.input == Self.inputNine)
        #expect(observer.policy.timeoutTicks == 77)
        #expect(observer.policy.lossAction == .requestInputLost)
    }

    @Test
    func lossOutcomeCarriesTheInputAndTheRequestFlagFromThePolicy() throws {
        var report = try Self.armed(action: .reportOnly, input: Self.inputNine)
        var request = try Self.armed(action: .requestInputLost, input: Self.inputSeven)
        #expect(try report.poll(at: Self.at(100)) == Self.lost(Self.inputNine, request: false))
        #expect(try request.poll(at: Self.at(100)) == Self.lost(Self.inputSeven, request: true))
    }

    @Test
    func twoInputsAreIndependentValues() throws {
        var first = try Self.armed(timeout: 100, input: Self.inputSeven, at: 0)
        var second = try Self.armed(timeout: 100, input: Self.inputNine, at: 50)
        #expect(try first.poll(at: Self.at(100)) == Self.lost(Self.inputSeven))
        #expect(try second.poll(at: Self.at(100)) == .none)
        #expect(first.phase == .lost(since: 100))
        #expect(second.phase == .armed(deadline: 150))
        #expect(try second.poll(at: Self.at(150)) == Self.lost(Self.inputNine))
    }

    @Test
    func scriptedSequenceProducesTheExpectedOutcomesAndPhases() throws {
        var observer = try Self.observer(timeout: 100, action: .requestInputLost)
        let script: [ScriptStep] = [
            ScriptStep(.realTime(status: 0xF8), 0, .none, .unarmed),
            ScriptStep(Self.sensing, 10, .armed, .armed(deadline: 110)),
            ScriptStep(Self.channelEvent, 50, .none, .armed(deadline: 150)),
            ScriptStep(nil, 149, .none, .armed(deadline: 150)),
            ScriptStep(nil, 150, Self.lost(request: true), .lost(since: 150)),
            ScriptStep(nil, 400, .none, .lost(since: 150)),
            ScriptStep(Self.sensing, 500, .armed, .armed(deadline: 600)),
            ScriptStep(Self.reset, 510, .none, .unarmed),
            ScriptStep(nil, 9_999, .none, .unarmed),
            ScriptStep(Self.sensing, 10_000, .armed, .armed(deadline: 10_100)),
            ScriptStep(Self.sensing, 10_100, Self.lost(request: true), .armed(deadline: 10_200))
        ]
        for (index, step) in script.enumerated() {
            let outcome = if let event = step.event {
                try observer.observe(event, at: Self.at(step.tick))
            } else {
                try observer.poll(at: Self.at(step.tick))
            }
            #expect(outcome == step.outcome, "step \(index) outcome")
            #expect(observer.phase == step.phase, "step \(index) phase")
            #expect(observer.lastTick == step.tick, "step \(index) last tick")
        }
    }
}
