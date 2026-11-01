import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct ClockValidation {
        private let sample = ClockID(validated: "clock.sample")
        private let musical = ClockID(validated: "clock.musical")
        private let context = GenerationKey(.context, GenerationSubject(validated: "context.test"))

        @Test func requiredClockDependenciesCannotBeOmittedOrSubstituted() throws {
            let key = GenerationKey(.sampleClock, sample)
            let incomplete = TriggerStamp(
                id: TriggerID(validated: "trigger.invalid"), action: ActionID(validated: "action.test"),
                originHost: .init(ticks: 0), horizonFrame: 0, requires: [], target: .asap, latePolicy: .drop
            )
            #expect(throws: TriggerValidationError.missingPrimaryClock) {
                try incomplete.validate(primaryClock: key, musicalClock: musical)
            }
            let noTransport = TriggerStamp(
                id: incomplete.id, action: incomplete.action, originHost: incomplete.originHost, horizonFrame: 0,
                requires: [.init(key: key, generation: .initial), .init(key: context, generation: .initial)],
                target: .musical(atTicks: 10), latePolicy: .drop
            )
            #expect(throws: TriggerValidationError.missingTransport) {
                try noTransport.validate(primaryClock: key, musicalClock: musical)
            }
            for target: TriggerTarget in [.sample(atFrame: 0), .asap] {
                let fallback = trigger(requires: noTransport.requires, target: target,
                                       policy: .nextBoundary(gridTicks: 1))
                #expect(throws: TriggerValidationError.nextBoundaryWithoutTransport) {
                    try fallback.validate(primaryClock: key, musicalClock: musical)
                }
            }
            let ledger = try GenerationLedger(primaryClock: sample, musicalClock: musical, nominalRate: 48_000)
            #expect(!ledger.isCurrent(.init(key: GenerationKey(.transport, sample), generation: .initial)))
        }

        @Test func malformedLoopsAndOutOfBoundsConversionsThrowInsteadOfTrapping() throws {
            for json in [#"{"startTicks":10,"endTicks":0}"#, #"{"startTicks":0,"endTicks":0}"#] {
                #expect(throws: ClockMapError.self) {
                    try ContractCoding.decode(LoopRange.self, from: Data(json.utf8))
                }
            }
            let anchor = ClockAnchor(sample: .init(clock: sample, generation: .initial, frame: .max),
                                     host: .init(ticks: 0),
                                     musical: .init(transport: .initial, musicalMap: .initial,
                                                    ticks: 0, loopIteration: 0))
            let hostMap = try SampleClockMap(anchor: anchor, nominalRate: 48_000,
                                            timebase: .init(numer: 125, denom: 3))
            #expect(throws: ClockMapError.overflow) {
                try hostMap.frame(atHost: .init(ticks: 500), current: .initial)
            }
            let map = try MusicalMap(clock: musical, revision: .initial,
                                     segments: [TempoSegment(atTicks: 0, microsPerQuarter: 500_000)])
            let musicalMap = try MusicalClockMap(anchor: anchor, map: map, nominalRate: 48_000,
                                                currentSample: .initial, currentTransport: .initial)
            #expect(throws: ClockMapError.overflow) { try musicalMap.frame(atTicks: 1) }
            #expect(throws: ClockMapError.invalidMap) { try musicalMap.boundary(atOrAfterFrame: 0, grid: 0) }
            #expect(throws: ClockMapError.invalidRate(Int.max)) {
                try SampleClockMap(anchor: anchor, nominalRate: Int.max, timebase: .init(numer: 1, denom: 1))
            }
        }

        @Test func portablePoliciesPreserveNestedOptionalFieldsAndRequireExplicitTimePolicy() throws {
            let json = """
            {"media":"audio","timePolicy":"fixedRate","latePolicy":{"fireLate":{"maxLatenessMs":30,"future":true}},
             "retroactiveMs":10,"stoppedPolicy":"wait","extensions":{"vendor":1},"futurePolicy":"preserve"}
            """
            let decoded = try ContractCoding.decode(ActionPolicy.self, from: Data(json.utf8))
            let encoded = try ContractCoding.makeEncoder().encode(decoded)
            #expect(String(data: encoded, encoding: .utf8)?.contains("\"future\":true") == true)
            #expect(decoded.extensions == ["vendor": .int(1)])
            #expect(try ContractCoding.decode(ActionPolicy.self, from: encoded) == decoded)
            #expect(throws: ControlValidationError.self) {
                try ActionPolicy(media: .audio, timePolicy: nil, latePolicy: .drop)
            }
            #expect(throws: ControlValidationError.self) {
                try ActionPolicy(media: .midi, timePolicy: .timeStretch, latePolicy: .drop)
            }
        }

        @Test func timeStretchMustBeSupportedAndSourceChangesInvalidateReadyProof() throws {
            var ledger = try GenerationLedger(primaryClock: sample, musicalClock: musical, nominalRate: 48_000)
            let source = GenerationKey(.source, StreamID(validated: "source.test"))
            try ledger.declare(source)
            let action = ActionID(validated: "action.stretch")
            var readiness = ActionReadiness()
            try readiness.transition(action, to: .preparing)
            let policy = try ActionPolicy(media: .audio, timePolicy: .timeStretch, latePolicy: .drop)
            #expect(throws: ReadinessError.timeStretchUnavailable) {
                try readiness.markReady(action, preparedAgainst: [], ledger: ledger, policy: policy)
            }
            #expect(readiness.state(action) == .failed && readiness.reasons[action] == .timeStretchUnavailable)
            try readiness.transition(action, to: .preparing)
            try readiness.markReady(action, preparedAgainst: [.init(key: source, generation: .initial)],
                                    ledger: ledger, policy: policy, supportsTimeStretch: true)
            try ledger.bump(source, reason: .sourceLost)
            #expect(!readiness.isCurrent(action, ledger: ledger))
        }

        @Test func transportEnvelopeIsIndependentAndNeverPersistsHostTicks() throws {
            let fields = TransportFields(
                host: .init(host: HostID(validated: "host.test"), generation: .initial),
                primaryClock: sample, sampleGeneration: .initial, nominalRate: 48_000,
                musicalClock: nil, transportGeneration: nil, musicalMapRevision: nil,
                segments: [], meter: nil, loop: nil
            )
            var document = try TransportDocument(revision: .initial, payload: ControlRecord(fields))
            document.unknownFields["future"] = .bool(true)
            let data = try ContractCoding.makeEncoder().encode(document)
            #expect(try ContractCoding.decode(TransportDocument.self, from: data) == document)
            #expect(String(data: data, encoding: .utf8)?.contains("hostTicks") == false)
            #expect(throws: ContractVersionError.self) {
                try ContractCoding.decode(ParameterCatalogDocument.self, from: data)
            }
        }

        @Test func everyTargetRequiresContextAndContextChangesInvalidateFreshness() throws {
            var ledger = try GenerationLedger(primaryClock: sample, musicalClock: musical, nominalRate: 48_000)
            try ledger.declare(context)
            let clockRequirements = [ledger.primaryClock, GenerationKey(.transport, musical)]
                .map { GenerationRequirement(key: $0, generation: .initial) }
            for target: TriggerTarget in [.asap, .sample(atFrame: 10), .musical(atTicks: 0), .grid(ticks: 1)] {
                for policy: LatePolicy in [.drop, .nextBoundary(gridTicks: 1)] {
                    let missing = trigger(requires: clockRequirements, target: target, policy: policy)
                    #expect(throws: TriggerValidationError.missingContext) {
                        try missing.validate(primaryClock: ledger.primaryClock, musicalClock: musical)
                    }
                    let pending = trigger(requires: clockRequirements + [.init(key: context, generation: .initial)],
                                          target: target, policy: policy)
                    try pending.validate(primaryClock: ledger.primaryClock, musicalClock: musical)
                    #expect(pending.requires.allSatisfy(ledger.isCurrent))
                }
            }
            let pending = trigger(requires: clockRequirements + [.init(key: context, generation: .initial)])
            var readiness = ActionReadiness()
            try readiness.transition(pending.action, to: .preparing)
            try readiness.markReady(pending.action, preparedAgainst: pending.requires, ledger: ledger)
            try ledger.bump(context, reason: .contextChange)
            #expect(!pending.requires.allSatisfy(ledger.isCurrent))
            #expect(!readiness.isCurrent(pending.action, ledger: ledger))
            #expect(readiness.generationChanged(context) == [pending.action])
            #expect(readiness.state(pending.action) == .invalidated)
            let fresh = try trigger(requires: pending.requires.map {
                .init(key: $0.key, generation: try #require(ledger.generation($0.key)))
            })
            #expect(fresh.requires.allSatisfy(ledger.isCurrent))
        }

        private func trigger(requires: [GenerationRequirement], target: TriggerTarget = .asap,
                             policy: LatePolicy = .drop, retroactive: Int = 0) -> TriggerStamp {
            TriggerStamp(id: .init(validated: "trigger.test"), action: .init(validated: "action.test"),
                         originHost: .init(ticks: 0), horizonFrame: 0, requires: requires, target: target,
                         latePolicy: policy, retroactiveMs: retroactive)
        }

        @Test func undeclaredContextsAreNeverFreshAndDeclarationCannotResetCounters() throws {
            var ledger = try GenerationLedger(primaryClock: sample, musicalClock: musical,
                                              nominalRate: 48_000, declaring: [context])
            let foreign = GenerationKey(.context, GenerationSubject(validated: "context.unused"))
            let stamp = trigger(requires: [ledger.primaryClock, foreign].map {
                .init(key: $0, generation: .initial)
            })
            try stamp.validate(primaryClock: ledger.primaryClock, musicalClock: musical)
            #expect(ledger.generation(foreign) == nil)
            #expect(!stamp.requires.allSatisfy(ledger.isCurrent))
            let before = ledger.current
            #expect(throws: GenerationLedgerError.undeclaredCounter(foreign)) {
                try ledger.bump(foreign, reason: .contextChange)
            }
            #expect(ledger.current == before)
            var readiness = ActionReadiness()
            try readiness.transition(stamp.action, to: .preparing)
            #expect(throws: ReadinessError.stalePreparation(stamp.action)) {
                try readiness.markReady(stamp.action, preparedAgainst: stamp.requires, ledger: ledger)
            }
            #expect(ledger.isCurrent(.init(key: context, generation: .initial)))
            let next = try ledger.bump(context, reason: .contextChange)
            #expect(!stamp.requires.allSatisfy(ledger.isCurrent))
            #expect(!ledger.isCurrent(.init(key: context, generation: .initial)))
            #expect(ledger.isCurrent(.init(key: context, generation: next)))
            #expect(throws: GenerationLedgerError.alreadyDeclared(context)) { try ledger.declare(context) }
            #expect(ledger.generation(context) == next)
            try ledger.declare(foreign)
            #expect(ledger.isCurrent(.init(key: foreign, generation: .initial)))
            #expect(throws: GenerationLedgerError.alreadyDeclared(context)) {
                try GenerationLedger(primaryClock: sample, musicalClock: nil, nominalRate: 48_000,
                                     declaring: [context, context])
            }
            let otherSample = GenerationKey(.sampleClock, ClockID(validated: "clock.foreign"))
            #expect(throws: GenerationLedgerError.undeclaredSampleClock(otherSample)) {
                try ledger.declare(otherSample)
            }
            #expect(!ledger.isCurrent(.init(key: otherSample, generation: .initial)))
        }

        @Test func primaryMustBeASampleClockAndMusicalIdentityMustDiffer() throws {
            let stamp = trigger(requires: [.init(key: context, generation: .initial)])
            #expect(throws: TriggerValidationError.invalidPrimaryClock(context)) {
                try stamp.validate(primaryClock: context, musicalClock: nil)
            }
            let key = GenerationKey(.sampleClock, sample)
            let withSample = trigger(requires: [key, context].map { .init(key: $0, generation: .initial) })
            #expect(throws: TriggerValidationError.aliasedClocks) {
                try withSample.validate(primaryClock: key, musicalClock: sample)
            }
            #expect(throws: GenerationLedgerError.aliasedClocks) {
                try GenerationLedger(primaryClock: sample, musicalClock: sample, nominalRate: 48_000)
            }
        }

        @Test func mediaOutcomeShapeDoesNotAdmitCommandOnlyReasonsOrContradictoryFrames() throws {
            let id = TriggerID(validated: "trigger.outcome")
            for result: OutcomeResult in [.fired, .firedLate, .joined] {
                #expect(throws: TriggerOutcomeValidationError.invalidShape) {
                    try TriggerOutcome(trigger: id, result: result).validateMediaShape()
                }
            }
            for reason: DropReason in [.outsideLoop, .invalidTiming] {
                #expect(throws: TriggerOutcomeValidationError.invalidShape) {
                    try TriggerOutcome(trigger: id, result: .dropped, reason: reason).validateMediaShape()
                }
            }
            let staleReasons: [StaleDependency] = [
                .connectionEpoch, .hostEpoch, .generation(GenerationKey(.musicalMap, musical))
            ]
            for stale in staleReasons {
                #expect(throws: TriggerOutcomeValidationError.invalidShape) {
                    try TriggerOutcome(trigger: id, result: .cancelled, stale: stale).validateMediaShape()
                }
            }
            try TriggerOutcome(trigger: id, result: .dropped, reason: .notReady).validateMediaShape()
            try TriggerOutcome(trigger: id, result: .fired, assignedFrame: -1, frame: -1).validateMediaShape()
        }

        @Test func exactV1TimingBoundsApplyAtConstructionAndDecode() throws {
            let requirements = [GenerationKey(.sampleClock, sample), context]
                .map { GenerationRequirement(key: $0, generation: .initial) }
            for maximum in [-1, 0, 1_000, 1_001] {
                for retroactive in [-1, 0, 120, 121] {
                    let valid = (0...1_000).contains(maximum) && (0...120).contains(retroactive)
                        && retroactive <= maximum
                    for name in ["fireLate", "joinInProgress"] {
                        let policy: LatePolicy = name == "fireLate" ? .fireLate(maxLatenessMs: maximum)
                            : .joinInProgress(maxLatenessMs: maximum)
                        let value = trigger(requires: requirements, policy: policy, retroactive: retroactive)
                        let json = """
                        {"media":"state","latePolicy":{"\(name)":{"maxLatenessMs":\(maximum)}},
                        "retroactiveMs":\(retroactive),"stoppedPolicy":"wait"}
                        """
                        if valid {
                            try value.validate(primaryClock: requirements[0].key, musicalClock: musical)
                            _ = try ContractCoding.decode(ActionPolicy.self, from: Data(json.utf8))
                        } else {
                            #expect(throws: TriggerValidationError.self) {
                                try value.validate(primaryClock: requirements[0].key, musicalClock: musical)
                            }
                            #expect(throws: ControlValidationError.self) {
                                try ContractCoding.decode(ActionPolicy.self, from: Data(json.utf8))
                            }
                        }
                    }
                }
            }
        }

        @Test func musicalTargetsAndGridsMatchV1CountsWithoutInventedUpperBounds() throws {
            let requirements = [GenerationKey(.sampleClock, sample), GenerationKey(.transport, musical), context]
                .map { GenerationRequirement(key: $0, generation: .initial) }
            let negative = trigger(requires: requirements, target: .musical(atTicks: -1))
            #expect(throws: TriggerValidationError.invalidMusicalTicks(-1)) {
                try negative.validate(primaryClock: requirements[0].key, musicalClock: musical)
            }
            for target: TriggerTarget in [.musical(atTicks: 0), .musical(atTicks: .max), .grid(ticks: .max)] {
                try trigger(requires: requirements, target: target)
                    .validate(primaryClock: requirements[0].key, musicalClock: musical)
            }
            for grid in [Int64(-1), 0] {
                #expect(throws: TriggerValidationError.invalidGrid(grid)) {
                    try trigger(requires: requirements, target: .grid(ticks: grid))
                        .validate(primaryClock: requirements[0].key, musicalClock: musical)
                }
            }
            _ = try ActionPolicy(media: .state, timePolicy: nil, latePolicy: .nextBoundary(gridTicks: .max))
        }

        @Test func exactV1TempoMeterLoopAndRateBounds() throws {
            for tempo in [59_999, 60_000, 3_000_000, 3_000_001] {
                let json = #"{"atTicks":0,"microsPerQuarter":\#(tempo)}"#
                if (60_000...3_000_000).contains(tempo) {
                    _ = try ContractCoding.decode(TempoSegment.self, from: Data(json.utf8))
                } else {
                    #expect(throws: ClockMapError.self) {
                        try ContractCoding.decode(TempoSegment.self, from: Data(json.utf8))
                    }
                }
            }
            for denominator in [0, 1, 2, 4, 8, 16, 32, 64] {
                let json = #"{"numerator":64,"denominator":\#(denominator)}"#
                if denominator == 0 || denominator == 64 {
                    #expect(throws: ControlValidationError.self) {
                        try ContractCoding.decode(MusicalMeter.self, from: Data(json.utf8))
                    }
                } else {
                    _ = try ContractCoding.decode(MusicalMeter.self, from: Data(json.utf8))
                }
            }
            #expect(throws: ClockMapError.self) {
                try ContractCoding.decode(LoopRange.self, from: Data(#"{"startTicks":-1,"endTicks":1}"#.utf8))
            }
            _ = try LoopRange(startTicks: 0, endTicks: .max)
            _ = try TempoSegment(atTicks: .max, microsPerQuarter: 60_000)
            for rate in [0, 44_099, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 192_001, 768_000] {
                let fields = TransportFields(
                    host: .init(host: .init(validated: "host.test"), generation: .initial),
                    primaryClock: sample, sampleGeneration: .initial, nominalRate: rate,
                    musicalClock: nil, transportGeneration: nil, musicalMapRevision: nil,
                    segments: [], meter: nil, loop: nil
                )
                let data = try ContractCoding.makeEncoder().encode(fields)
                let anchor = ClockAnchor(sample: .init(clock: sample, generation: .initial, frame: 0),
                                         host: .init(ticks: 0),
                                         musical: .init(transport: .initial, musicalMap: .initial,
                                                        ticks: 0, loopIteration: 0))
                let map = try MusicalMap(clock: musical, revision: .initial,
                                         segments: [TempoSegment(atTicks: 0, microsPerQuarter: 500_000)])
                let accepted = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000].contains(rate)
                #expect(MediaNominalRate.isValid(rate) == accepted)
                if accepted {
                    _ = try ContractCoding.decode(ControlRecord<TransportFields>.self, from: data)
                    _ = try GenerationLedger(primaryClock: sample, musicalClock: nil, nominalRate: rate)
                    _ = try SampleClockMap(anchor: anchor, nominalRate: rate, timebase: .init(numer: 1, denom: 1))
                    _ = try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                            currentSample: .initial, currentTransport: .initial)
                } else {
                    #expect(throws: ClockMapError.self) {
                        try ContractCoding.decode(ControlRecord<TransportFields>.self, from: data)
                    }
                    #expect(throws: GenerationLedgerError.invalidRate) {
                        try GenerationLedger(primaryClock: sample, musicalClock: nil, nominalRate: rate)
                    }
                    var ledger = try GenerationLedger(primaryClock: sample, musicalClock: nil, nominalRate: 48_000)
                    #expect(throws: GenerationLedgerError.invalidRate) {
                        try ledger.bump(ledger.primaryClock, reason: .rateChange(nominalRate: rate))
                    }
                    #expect(ledger.nominalRate == 48_000 && ledger.generation(ledger.primaryClock) == .initial)
                    #expect(throws: ClockMapError.invalidRate(rate)) {
                        try SampleClockMap(anchor: anchor, nominalRate: rate, timebase: .init(numer: 1, denom: 1))
                    }
                    #expect(throws: ClockMapError.invalidRate(rate)) {
                        try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                            currentSample: .initial, currentTransport: .initial)
                    }
                }
            }
        }
    }
}
