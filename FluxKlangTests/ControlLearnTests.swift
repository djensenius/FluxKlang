import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct ControlLearnTests {
    static let size = ParameterID(validated: "par.verb.size")
    static let trim = ParameterID(validated: "par.mic.trim")
    static let level = ParameterID(validated: "par.mains.gain")
    static let newID = BindingID(validated: "bnd.knob5-size")
    static let deviceA = DeviceID(validated: "dev.ctl-a")
    static let deviceB = DeviceID(validated: "dev.ctl-b")
    static let knob5 = LearnHeardControl(device: deviceA, source: ControlSourceID(validated: "ctl.knob-5"),
                                         profile: .absolute(resolution: 128))
    static let encoder2 = LearnHeardControl(device: deviceA, source: ControlSourceID(validated: "ctl.enc-2"),
                                            profile: .twosComplement(width: .seven))

    @Test
    func reviewFlowCommitsAbsoluteControlWithCatchPickup() throws {
        let target = try Self.sizeDescriptor()
        var session = LearnSession()
        #expect(session.phase == .idle)
        let started = try session.start(target, binding: Self.newID, policy: LearnEligibilityPolicy(),
                                        timeoutTicks: 100, now: 5)
        #expect(started.kind == .listening)
        let hearing = try session.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 6)
        let proposal = try #require(Self.proposal(hearing))
        #expect(session.phase.kind == .awaitingReview)
        #expect(proposal.device == Self.deviceA && proposal.conflicts.isEmpty)
        #expect(proposal.binding.pickup == .catch && proposal.binding.step == nil)
        #expect(proposal.binding.source == Self.knob5.source && proposal.binding.target == Self.size)
        #expect(proposal.binding.unit == .normalized && proposal.binding.id == Self.newID)
        let commit = try session.confirm(descriptor: target, existing: [])
        #expect(commit.binding == proposal.binding && commit.removing.isEmpty)
        #expect(session.phase == .committed(commit))
        #expect(try commit.binding.validate(against: target) == 0...1)
    }

    @Test
    func relativeControlStepsFromItsProfileAndRange() throws {
        let capped = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, ceiling: 0)
        let binding = try Self.recordedBinding(Self.encoder2, on: capped)
        #expect(binding.profile == .twosComplement(width: .seven))
        #expect(binding.pickup == nil && binding.step == 0.9)
        let index = try Self.descriptor(Self.level, unit: .index, range: 0...7, curve: .stepped)
        #expect(try Self.recordedBinding(Self.encoder2, on: index).step == 1)
        #expect(LearnDefaults.relativeStep(for: try Self.sizeDescriptor()) == 0.01)
    }

    @Test
    func ineligibleTargetsAreBlockedWithTypedReasons() throws {
        let hazardous = try Self.descriptor(Self.trim, unit: .decibels, range: 0...60, controlClass: .hazardous)
        let structural = try Self.descriptor(Self.level, unit: .index, range: 0...3, curve: .stepped,
                                             controlClass: .structural)
        let excludingAll = try LearnEligibilityPolicy(excluded: [Self.trim, Self.size])
        struct Case { let descriptor: ParameterDescriptor, policy: LearnEligibilityPolicy, reason: LearnBlockReason }
        let cases = [
            Case(descriptor: hazardous, policy: try LearnEligibilityPolicy(), reason: .hazardous),
            Case(descriptor: hazardous, policy: excludingAll, reason: .hazardous),
            Case(descriptor: structural, policy: try LearnEligibilityPolicy(), reason: .notLive(.structural)),
            Case(descriptor: try Self.sizeDescriptor(), policy: excludingAll, reason: .excluded)
        ]
        for item in cases {
            var session = LearnSession()
            let phase = try session.start(item.descriptor, binding: Self.newID, policy: item.policy,
                                          timeoutTicks: 10, now: 0)
            guard case .blocked(let blocked) = phase else { Issue.record("not blocked: \(phase)"); continue }
            #expect(blocked.target == item.descriptor.id && blocked.reason == item.reason)
            #expect(throws: LearnRefusal.notListening(.blocked)) {
                try session.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 1)
            }
            #expect(throws: LearnRefusal.noActiveSession(.blocked)) { try session.cancel() }
            let restarted = try session.start(Self.sizeDescriptor(), binding: Self.newID,
                                              policy: LearnEligibilityPolicy(), timeoutTicks: 10, now: 1)
            #expect(restarted.kind == .listening)
        }
        #expect(try LearnEligibilityPolicy(excluded: [Self.trim]).blockReason(for: Self.sizeDescriptor()) == nil)
    }

    @Test
    func exclusionSetIsBounded() throws {
        let ids = try (0...LearnEligibilityPolicy.maximumExcluded).map { try ParameterID("par.x\($0)") }
        #expect(try LearnEligibilityPolicy(excluded: Set(ids.dropLast())).excluded.count == 4096)
        #expect(throws: LearnRefusal.tooManyExcluded(4097)) { try LearnEligibilityPolicy(excluded: Set(ids)) }
    }

    @Test
    func absentDevicesAreIgnoredUntilPresent() throws {
        var session = try Self.listening()
        let other = LearnHeardControl(device: Self.deviceB, source: Self.knob5.source, profile: Self.knob5.profile)
        #expect(try session.hear(other, present: [Self.deviceA], existing: [], now: 1)
            == .ignored(.deviceAbsent(Self.deviceB)))
        #expect(try session.hear(Self.knob5, present: [], existing: [], now: 2)
            == .ignored(.deviceAbsent(Self.deviceA)))
        #expect(session.phase.kind == .listening && session.lastTick == 2)
        let recorded = try session.hear(other, present: [Self.deviceA, Self.deviceB], existing: [], now: 3)
        #expect(Self.proposal(recorded)?.device == Self.deviceB)
    }

    @Test
    func presenceSetIsBounded() throws {
        let devices = try (0...LearnSession.maximumPresentDevices).map { try DeviceID("dev.d\($0)") }
        var session = try Self.listening()
        let before = session
        #expect(throws: LearnRefusal.tooManyPresentDevices(257)) {
            try session.hear(Self.knob5, present: Set(devices), existing: [], now: 1)
        }
        #expect(session == before)
        var atLimit = Set(devices.dropLast())
        atLimit.remove(devices[0])
        atLimit.insert(Self.deviceA)
        #expect(atLimit.count == 256)
        #expect(Self.proposal(try session.hear(Self.knob5, present: atLimit, existing: [], now: 1)) != nil)
    }

    @Test
    func controlsThatCannotBindAreIgnored() throws {
        let taper = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, curve: .faderTaper)
        var session = try Self.listening(on: taper)
        #expect(try session.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 1)
            == .ignored(.incompatible(.undefinedCurve(.faderTaper))))
        #expect(session.phase.kind == .listening)
        #expect(Self.proposal(try session.hear(Self.encoder2, present: [Self.deviceA], existing: [], now: 2)) != nil)
        let flat = try Self.descriptor(Self.size, unit: .normalized, range: 0.5...0.5)
        var flatSession = try Self.listening(on: flat)
        #expect(try flatSession.hear(Self.encoder2, present: [Self.deviceA], existing: [], now: 1)
            == .ignored(.noUsableStep))
        #expect(flatSession.phase.kind == .listening)
    }

    @Test
    func invalidCallerProfileIsRefusedWithoutChange() throws {
        var session = try Self.listening()
        let before = session
        let bad = LearnHeardControl(device: Self.deviceA, source: Self.knob5.source, profile: .absolute(resolution: 1))
        #expect(throws: LearnRefusal.invalidProfile(.invalidResolution(1))) {
            try session.hear(bad, present: [Self.deviceA], existing: [], now: 3)
        }
        #expect(session == before)
    }

    @Test
    func timeoutTicksAreBounded() throws {
        for (ticks, valid) in [(UInt64(0), false), (1, true), (3_600_000, true), (3_600_001, false)] {
            var session = LearnSession()
            if valid {
                #expect(try session.start(Self.sizeDescriptor(), binding: Self.newID, policy: LearnEligibilityPolicy(),
                                          timeoutTicks: ticks, now: 0).kind == .listening)
            } else {
                #expect(throws: LearnRefusal.invalidTimeout(ticks)) {
                    try session.start(Self.sizeDescriptor(), binding: Self.newID, policy: LearnEligibilityPolicy(),
                                      timeoutTicks: ticks, now: 0)
                }
                #expect(session == LearnSession())
            }
        }
    }

    @Test
    func listeningTimesOutExactlyAtItsDeadline() throws {
        var session = try Self.listening(timeoutTicks: 5, now: 10)
        #expect(try session.advance(to: 14).kind == .listening)
        #expect(try session.advance(to: 15) == .cancelled(.timedOut))
        var hearing = try Self.listening(timeoutTicks: 5, now: 10)
        #expect(try hearing.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 15) == .timedOut)
        #expect(hearing.phase == .cancelled(.timedOut))
        var early = try Self.listening(timeoutTicks: 5, now: 10)
        #expect(Self.proposal(try early.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 14)) != nil)
        #expect(try early.advance(to: 100).kind == .awaitingReview)
    }

    @Test
    func deadlineIsCheckedBeforeAnyOtherHearCheck() throws {
        let absent = LearnHeardControl(device: Self.deviceB, source: Self.knob5.source, profile: Self.knob5.profile)
        let twice = try [ControlLearnConflictTests.binding("bnd.dup", source: "ctl.a", target: Self.level),
                         ControlLearnConflictTests.binding("bnd.dup", source: "ctl.b", target: Self.level)]
        let many = try (0...LearnConflicts.maximumExistingBindings).map {
            try ControlLearnConflictTests.binding("bnd.n\($0)", source: "ctl.n\($0)", target: Self.level)
        }
        let devices = try (0...LearnSession.maximumPresentDevices).map { try DeviceID("dev.d\($0)") }
        struct Attempt { let heard: LearnHeardControl, present: Set<DeviceID>, existing: [ControlBinding] }
        let attempts = [
            Attempt(heard: absent, present: [Self.deviceA], existing: []),
            Attempt(heard: Self.knob5, present: [Self.deviceA], existing: twice),
            Attempt(heard: Self.knob5, present: [Self.deviceA], existing: many),
            Attempt(heard: Self.knob5, present: Set(devices), existing: [])
        ]
        for item in attempts {
            var session = try Self.listening(timeoutTicks: 5, now: 10)
            #expect(try session.hear(item.heard, present: item.present, existing: item.existing, now: 15) == .timedOut)
            #expect(session.phase == .cancelled(.timedOut) && session.lastTick == 15)
            var late = try Self.listening(timeoutTicks: 5, now: 10)
            #expect(try late.hear(item.heard, present: item.present, existing: item.existing, now: 99) == .timedOut)
        }
    }

    @Test
    func advancedTicksBindLaterHearing() throws {
        var session = try Self.listening(timeoutTicks: 100, now: 0)
        #expect(try session.advance(to: 50).kind == .listening && session.lastTick == 50)
        #expect(throws: LearnRefusal.tickRegressed(last: 50, now: 20)) {
            try session.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 20)
        }
    }

    @Test
    func ticksMustNotRegress() throws {
        var session = try Self.listening(now: 10)
        #expect(try session.advance(to: 10).kind == .listening)
        let before = session
        #expect(throws: LearnRefusal.tickRegressed(last: 10, now: 9)) { try session.advance(to: 9) }
        #expect(throws: LearnRefusal.tickRegressed(last: 10, now: 9)) {
            try session.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 9)
        }
        #expect(session == before)
        try session.cancel()
        #expect(throws: LearnRefusal.tickRegressed(last: 10, now: 9)) {
            try session.start(Self.sizeDescriptor(), binding: Self.newID, policy: LearnEligibilityPolicy(),
                              timeoutTicks: 5, now: 9)
        }
        #expect(session.phase == .cancelled(.user))
    }

    @Test
    func onlyOneSessionRunsAtATime() throws {
        var session = try Self.listening()
        #expect(throws: LearnRefusal.sessionInProgress(.listening)) {
            try session.start(Self.sizeDescriptor(), binding: Self.newID, policy: LearnEligibilityPolicy(),
                              timeoutTicks: 5, now: 1)
        }
        _ = try session.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 1)
        #expect(throws: LearnRefusal.sessionInProgress(.awaitingReview)) {
            try session.start(Self.sizeDescriptor(), binding: Self.newID, policy: LearnEligibilityPolicy(),
                              timeoutTicks: 5, now: 2)
        }
        #expect(throws: LearnRefusal.notListening(.awaitingReview)) {
            try session.hear(Self.encoder2, present: [Self.deviceA], existing: [], now: 2)
        }
        _ = try session.confirm(descriptor: Self.sizeDescriptor(), existing: [])
        #expect(try session.start(Self.sizeDescriptor(), binding: Self.newID, policy: LearnEligibilityPolicy(),
                                  timeoutTicks: 5, now: 3).kind == .listening)
    }

    @Test
    func cancelLeavesNoBinding() throws {
        var idle = LearnSession()
        #expect(throws: LearnRefusal.noActiveSession(.idle)) { try idle.cancel() }
        #expect(throws: LearnRefusal.notAwaitingReview(.idle)) {
            try idle.confirm(descriptor: Self.sizeDescriptor(), existing: [])
        }
        var listening = try Self.listening()
        try listening.cancel()
        #expect(listening.phase == .cancelled(.user))
        var reviewing = try Self.listening()
        _ = try reviewing.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 1)
        try reviewing.cancel()
        #expect(reviewing.phase == .cancelled(.user))
        #expect(throws: LearnRefusal.noActiveSession(.cancelled)) { try reviewing.cancel() }
        #expect(throws: LearnRefusal.notAwaitingReview(.cancelled)) {
            try reviewing.confirm(descriptor: Self.sizeDescriptor(), existing: [])
        }
        #expect(throws: LearnRefusal.notListening(.cancelled)) {
            try reviewing.hear(Self.knob5, present: [Self.deviceA], existing: [], now: 2)
        }
    }

    @Test
    func confirmRevalidatesAgainstCurrentHostTruth() throws {
        var session = try Self.reviewing(Self.knob5)
        let before = session
        let other = try Self.descriptor(Self.level, unit: .normalized, range: 0...1)
        #expect(throws: LearnRefusal.targetMismatch(expected: Self.size, found: Self.level)) {
            try session.confirm(descriptor: other, existing: [])
        }
        let nowHazardous = try Self.descriptor(Self.size, unit: .normalized, range: 0...1, controlClass: .hazardous)
        #expect(throws: LearnRefusal.targetBlocked(.hazardous)) {
            try session.confirm(descriptor: nowHazardous, existing: [])
        }
        let nowTaper = try Self.descriptor(Self.size, unit: .normalized, range: 0...1, curve: .faderTaper)
        #expect(throws: LearnRefusal.invalidBinding(.undefinedCurve(.faderTaper))) {
            try session.confirm(descriptor: nowTaper, existing: [])
        }
        #expect(session == before)
        #expect(try session.confirm(descriptor: Self.sizeDescriptor(), existing: []).removing.isEmpty)
    }

    @Test
    func sameInputsGiveEqualOutputs() throws {
        func run() throws -> (LearnHearing, LearnSession) {
            var session = try Self.listening(timeoutTicks: 50, now: 7)
            let hearing = try session.hear(Self.encoder2, present: [Self.deviceB, Self.deviceA],
                                           existing: ControlLearnConflictTests.crowd(), now: 9)
            return (hearing, session)
        }
        let (first, second) = (try run(), try run())
        #expect(first.0 == second.0 && first.1 == second.1)
    }

    // Compile-time fence: session states, proposals and commits have fileprivate initializers in
    // LearnSession.swift, so none of these compile outside it; a session starts only via `init()`.
    #if false
    static let forgedListening = LearnListening(target: target, startTick: 9, timeoutTicks: 0)
    static let forgedCommit = LearnCommit(binding: binding, removing: [])
    static let forgedProposal = LearnProposal(device: deviceA, binding: binding, conflicts: [])
    static let forgedSession = LearnSession(phase: .idle, lastTick: 0)
    #endif

    // MARK: - Helpers

    static func sizeDescriptor() throws -> ParameterDescriptor {
        try descriptor(size, unit: .normalized, range: 0...1)
    }

    static func descriptor(
        _ id: ParameterID, unit: ParameterUnit, range: ClosedRange<Double>, curve: ParameterCurve = .linear,
        ceiling: Double? = nil, controlClass: ControlClass = .live
    ) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
            ceiling: ceiling, curve: curve, ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    static func listening(on target: ParameterDescriptor? = nil, timeoutTicks: UInt64 = 100,
                          now: UInt64 = 0) throws -> LearnSession {
        var session = LearnSession()
        try session.start(target ?? sizeDescriptor(), binding: newID, policy: LearnEligibilityPolicy(),
                          timeoutTicks: timeoutTicks, now: now)
        return session
    }

    static func reviewing(_ heard: LearnHeardControl, existing: [ControlBinding] = []) throws -> LearnSession {
        var session = try listening()
        _ = try #require(proposal(session.hear(heard, present: [heard.device], existing: existing, now: 1)))
        return session
    }

    static func recordedBinding(_ heard: LearnHeardControl, on target: ParameterDescriptor) throws -> ControlBinding {
        var session = try listening(on: target)
        return try #require(proposal(session.hear(heard, present: [heard.device], existing: [], now: 1))).binding
    }

    static func proposal(_ hearing: LearnHearing) -> LearnProposal? {
        if case .recorded(let proposal) = hearing { return proposal }
        return nil
    }
}
