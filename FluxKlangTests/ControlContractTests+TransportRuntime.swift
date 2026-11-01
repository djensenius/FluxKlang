import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct TransportRuntime {
        private let clock = ClockID(validated: "clock.sample")
        private let musical = ClockID(validated: "clock.musical")
        private let context = GenerationSubject(validated: "context.main")
        private let action = ActionID(validated: "action.clip")
        private let triggerID = TriggerID(validated: "trigger.clip")
        private let stream = StreamID(validated: "stream.clip")

        private func preparation() throws -> RuntimePreparation {
            try RuntimePreparation(primaryClock: clock, musicalClock: musical, bindings: [
                (.sampleClock(clock), 0), (.musicalClock(musical), 1), (.context(context), 2),
                (.action(action), 3), (.trigger(triggerID), 4), (.stream(stream, direction: .capture), 5)
            ])
        }

        private func requireBitwise<Value: BitwiseCopyable>(_: Value.Type) {}

        @Test func kernelVocabularyIsStaticallyBitwiseCopyableAndRequirementsAreBounded() throws {
            requireBitwise(RuntimeSampleStamp.self)
            requireBitwise(HostStamp.self)
            requireBitwise(HostTimebase.self)
            requireBitwise(RuntimeMusicalStamp.self)
            requireBitwise(RuntimeClockAnchor.self)
            requireBitwise(RuntimeGenerationKey.self)
            requireBitwise(RuntimeRequirements.self)
            requireBitwise(RuntimeTriggerStamp.self)
            requireBitwise(RuntimeTriggerOutcome.self)
            requireBitwise(RuntimeDiscontinuity.self)
            let entries = (0..<8).map {
                RuntimeGenerationRequirement(key: .init(kind: .source, slot: UInt32($0)), generation: UInt64($0 + 1))
            }
            let empty = try RuntimeRequirements([])
            let full = try RuntimeRequirements(entries)
            #expect(empty.count == 0 && empty[0] == nil)
            #expect(full.count == 8 && full[-1] == nil && full[8] == nil)
            for index in entries.indices { #expect(full[index] == entries[index]) }
            #expect(MemoryLayout.size(ofValue: empty) == MemoryLayout.size(ofValue: full))
            #expect(throws: TriggerValidationError.tooManyRequirements(9)) {
                try RuntimeRequirements(entries + [entries[0]])
            }
        }

        @Test func explicitMappingsRejectDuplicatesGapsAndMissingIdentities() throws {
            let other = GenerationSubject(validated: "context.other")
            let invalidBindings: [[(RuntimeIdentity, UInt32)]] = [
                [(.context(context), 0), (.context(context), 1)],
                [(.context(context), 0), (.context(other), 0)], [(.context(context), 1)], [(.context(context), .max)]
            ]
            for bindings in invalidBindings {
                #expect(throws: RuntimePreparationError.invalidMapping) {
                    try RuntimePreparation(primaryClock: clock, musicalClock: nil, bindings: bindings)
                }
            }
            let prepared = try preparation()
            #expect(throws: RuntimePreparationError.unmappedIdentity(.context(other))) {
                try prepared.slot(for: .context(other))
            }
            // Text that resembles a slot is still opaque, never numerically parsed.
            let numeric = GenerationSubject(validated: "clock.0")
            #expect(throws: RuntimePreparationError.unmappedIdentity(.context(numeric))) {
                try prepared.slot(for: .context(numeric))
            }
            #expect(try prepared.slot(for: .context(context)) == 2)
        }

        @Test func preparationPreservesStampTriggerAndOutcomeSemantics() throws {
            let prepared = try preparation()
            let generation = try Generation(7)
            let stamp = SampleStamp(clock: clock, generation: generation, frame: -123)
            let anchor = try prepared.anchor(.init(
                sample: stamp, host: .init(ticks: .max),
                musical: .init(transport: generation, musicalMap: .initial, ticks: 15_360, loopIteration: 3)
            ))
            #expect(anchor.sample.clock == 0 && anchor.sample.generation == 7 && anchor.sample.frame == -123)
            #expect(anchor.host.ticks == .max && anchor.musical?.ticks == 15_360)
            #expect(anchor.musical?.transport == 7 && anchor.musical?.musicalMap == 1)
            #expect(anchor.musical?.loopIteration == 3)
            let sampleKey = GenerationKey(.sampleClock, clock)
            let contextKey = GenerationKey(.context, context)
            for target: TriggerTarget in [.asap, .sample(atFrame: -100), .musical(atTicks: 0), .grid(ticks: .max)] {
                for policy: LatePolicy in [.drop, .fireLate(maxLatenessMs: 1_000),
                                           .joinInProgress(maxLatenessMs: 1_000), .nextBoundary(gridTicks: 15_360)] {
                    let value = TriggerStamp(
                        id: triggerID, action: action, originHost: .init(ticks: 77), horizonFrame: -9,
                        requires: [sampleKey, contextKey, GenerationKey(.transport, musical)]
                            .map { .init(key: $0, generation: generation) },
                        target: target, latePolicy: policy, retroactiveMs: policy.maxLatenessMs == nil ? 0 : 120,
                        stoppedPolicy: .startTransport, loopIteration: 4
                    )
                    let runtime = try prepared.trigger(value)
                    #expect(runtime.id == 4 && runtime.action == 3 && runtime.originHost.ticks == 77)
                    #expect(runtime.horizonFrame == -9 && runtime.target == target && runtime.latePolicy == policy)
                    #expect(runtime.retroactiveMs == value.retroactiveMs && runtime.stoppedPolicy == .startTransport)
                    #expect(runtime.loopIteration == 4 && runtime.requires.count == 3)
                    for (index, requirement) in value.requires.enumerated() {
                        #expect(try runtime.requires[index]?.key == prepared.key(requirement.key))
                        #expect(runtime.requires[index]?.generation == 7)
                    }
                }
            }
            let invalid = TriggerStamp(id: triggerID, action: action, originHost: .init(ticks: 0), horizonFrame: 0,
                                       requires: [.init(key: sampleKey, generation: .initial)],
                                       target: .asap, latePolicy: .drop)
            #expect(throws: TriggerValidationError.missingContext) {
                try prepared.trigger(invalid)
            }
        }

        @Test func bindingsCannotInventRolesFromSharedTextOrAliasClocks() throws {
            let prepared = try preparation()
            let wrongAction = try ActionID(clock.rawValue)
            let value = TriggerStamp(
                id: triggerID, action: wrongAction, originHost: .init(ticks: 0), horizonFrame: 0,
                requires: [GenerationKey(.sampleClock, clock), GenerationKey(.context, context)]
                    .map { .init(key: $0, generation: .initial) }, target: .asap, latePolicy: .drop
            )
            #expect(throws: RuntimePreparationError.unmappedIdentity(.action(wrongAction))) {
                try prepared.trigger(value)
            }
            #expect(throws: RuntimePreparationError.unmappedIdentity(.sampleClock(musical))) {
                try prepared.sample(.init(clock: musical, generation: .initial, frame: 0))
            }
            #expect(throws: RuntimePreparationError.unmappedIdentity(.musicalClock(clock))) {
                try prepared.key(.init(.transport, clock))
            }
            #expect(throws: RuntimePreparationError.unmappedIdentity(.cancelScope(context))) {
                try prepared.key(.init(.cancelScope, context))
            }
            #expect(throws: RuntimePreparationError.invalidClockDeclarations) {
                try RuntimePreparation(primaryClock: clock, musicalClock: clock,
                                       bindings: [(.sampleClock(clock), 0), (.musicalClock(clock), 1)])
            }
            #expect(throws: RuntimePreparationError.unmappedIdentity(.musicalClock(musical))) {
                try RuntimePreparation(primaryClock: clock, musicalClock: musical, bindings: [(.sampleClock(clock), 0)])
            }
            #expect(throws: RuntimePreparationError.unmappedIdentity(.sampleClock(clock))) {
                try RuntimePreparation(primaryClock: clock, musicalClock: nil,
                                       bindings: [(.context(GenerationSubject(clock.rawValue)), 0)])
            }
            // Same text can have two explicitly declared, distinct roles; it
            // cannot acquire the second role merely because the first exists.
            let explicit = try RuntimePreparation(primaryClock: clock, musicalClock: nil,
                                                  bindings: [(.sampleClock(clock), 0), (.action(wrongAction), 1)])
            #expect(try explicit.slot(for: .action(wrongAction)) == 1)
            #expect(try explicit.slot(for: .sampleClock(clock)) == 0)
        }

        @Test func anchorsRejectNegativeMusicalTicksAndUndeclaredMusicalClocks() throws {
            let prepared = try preparation()
            let sample = SampleStamp(clock: clock, generation: .initial, frame: .min)
            var anchor = ClockAnchor(sample: sample, host: .init(ticks: 0),
                                     musical: .init(transport: .initial, musicalMap: .initial,
                                                    ticks: -1, loopIteration: 0))
            #expect(throws: RuntimePreparationError.invalidMusicalStamp) { try prepared.anchor(anchor) }
            anchor.musical = .init(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: .max)
            #expect(try prepared.anchor(anchor).musical?.ticks == 0)
            let noMusical = try RuntimePreparation(primaryClock: clock, musicalClock: nil,
                                                   bindings: [(.sampleClock(clock), 0)])
            #expect(throws: RuntimePreparationError.invalidClockDeclarations) { try noMusical.anchor(anchor) }
            anchor.musical = nil
            #expect(try noMusical.anchor(anchor).sample.frame == .min)
        }

        @Test func validMediaOutcomesPreserveTheirDistinctShapes() throws {
            let prepared = try preparation()
            let generation = try Generation(7)
            let contextKey = GenerationKey(.context, context)
            let values: [TriggerOutcome] = [
                .init(trigger: triggerID, result: .fired, assignedFrame: -10, frame: -10, musicalMap: generation),
                .init(trigger: triggerID, result: .firedLate, assignedFrame: -10, frame: 20),
                .init(trigger: triggerID, result: .joined, assignedFrame: -10, frame: 20, startOffsetFrames: 30),
                .init(trigger: triggerID, result: .cancelled, stale: .generation(contextKey)),
                .init(trigger: triggerID, result: .rejectedStale, stale: .generation(contextKey)),
                .init(trigger: triggerID, result: .dropped, reason: .late, assignedFrame: -10),
                .init(trigger: triggerID, result: .dropped, reason: .notReady)
            ]
            for value in values {
                let runtime = try prepared.outcome(value)
                #expect(runtime.trigger == 4 && runtime.result == value.result && runtime.reason == value.reason)
                #expect(runtime.assignedFrame == value.assignedFrame && runtime.frame == value.frame)
                #expect(runtime.startOffsetFrames == value.startOffsetFrames)
                #expect(runtime.musicalMap == value.musicalMap.map { UInt64($0.value) })
                let expectedStale: RuntimeStaleDependency? = value.stale == nil ? nil
                    : .generation(.init(kind: .context, slot: 2))
                #expect(runtime.stale == expectedStale)
            }
        }

        @Test func conversionRejectsInvalidOffsetsMissingFramesAndContradictoryOutcomes() throws {
            let prepared = try preparation()
            let values: [TriggerOutcome] = [
                .init(trigger: triggerID, result: .joined, assignedFrame: -10, frame: 20, startOffsetFrames: -1),
                .init(trigger: triggerID, result: .joined, startOffsetFrames: 30),
                .init(trigger: triggerID, result: .joined, assignedFrame: -10, startOffsetFrames: 30),
                .init(trigger: triggerID, result: .joined, frame: 20, startOffsetFrames: 30),
                .init(trigger: triggerID, result: .joined, assignedFrame: -10, frame: 20, startOffsetFrames: 29),
                .init(trigger: triggerID, result: .joined, assignedFrame: .min, frame: .max, startOffsetFrames: .max),
                .init(trigger: triggerID, result: .firedLate, assignedFrame: 10, frame: 10),
                .init(trigger: triggerID, result: .fired, assignedFrame: 10, frame: 20),
                .init(trigger: triggerID, result: .dropped, reason: .late),
                .init(trigger: triggerID, result: .dropped, reason: .notReady, frame: 0),
                .init(trigger: triggerID, result: .cancelled),
                .init(trigger: triggerID, result: .fired, reason: .late,
                      stale: .generation(.init(.context, context)), assignedFrame: -10, frame: 20,
                      startOffsetFrames: 30, musicalMap: .initial)
            ]
            for value in values {
                #expect(throws: TriggerOutcomeValidationError.invalidShape) { try prepared.outcome(value) }
            }
        }

        @Test func discontinuitiesPreserveRestartLossAndStopPayloads() throws {
            let prepared = try preparation()
            let stamp = SampleStamp(clock: clock, generation: .initial, frame: 12)
            let restart = try prepared.discontinuity(.clockRestart(previousFrame: 99), sample: stamp,
                                                     host: .init(ticks: 123))
            #expect(restart.sample.clock == 0 && restart.sample.frame == 12 && restart.host?.ticks == 123)
            if case .clockRestart(let previousFrame) = restart.kind { #expect(previousFrame == 99) } else {
                Issue.record("Lost restart payload")
            }
            let loss = try prepared.discontinuity(.overflow, sample: stamp, frames: .max, stream: stream)
            #expect(loss.frames == .max && loss.stream == 5 && loss.host == nil)
            let stop = try prepared.discontinuity(.captureStopped(reason: .diskFull), sample: stamp, stream: stream)
            if case .captureStopped(let reason) = stop.kind { #expect(reason == .diskFull) } else {
                Issue.record("Lost stop reason")
            }
            #expect(throws: RuntimePreparationError.invalidDiscontinuity) {
                try prepared.discontinuity(.clockRestart(previousFrame: 0), sample: stamp)
            }
            #expect(throws: RuntimePreparationError.invalidDiscontinuity) {
                try prepared.discontinuity(.underrun, sample: stamp, frames: 0)
            }
        }

        @Test func streamDiscontinuitiesRequireDeclaredStreamsAndLossCounts() throws {
            let prepared = try preparation()
            let stamp = SampleStamp(clock: clock, generation: .initial, frame: 0)
            let streamKinds: [RuntimeDiscontinuityKind] = [
                .underrun, .overflow, .sourceLost, .sourceRestored, .formatChange,
                .captureStopped(reason: .diskFull), .captureStopped(reason: .deviceLost)
            ]
            for kind in streamKinds {
                #expect(throws: RuntimePreparationError.invalidDiscontinuity) {
                    try prepared.discontinuity(kind, sample: stamp)
                }
                #expect(throws: RuntimePreparationError.invalidDiscontinuity) {
                    try prepared.discontinuity(kind, sample: stamp, frames: 1)
                }
            }
            for kind: RuntimeDiscontinuityKind in [.underrun, .overflow] {
                for frames: UInt32? in [nil, 0] {
                    #expect(throws: RuntimePreparationError.invalidDiscontinuity) {
                        try prepared.discontinuity(kind, sample: stamp, frames: frames, stream: stream)
                    }
                }
            }
            #expect(throws: RuntimePreparationError.unmappedIdentity(.stream(stream, direction: .playback))) {
                try prepared.discontinuity(.underrun, sample: stamp, frames: 1, stream: stream)
            }
            let playback = try RuntimePreparation(primaryClock: clock, musicalClock: nil,
                bindings: [(.sampleClock(clock), 0), (.stream(stream, direction: .playback), 1)])
            _ = try playback.discontinuity(.underrun, sample: stamp, frames: 1, stream: stream)
            for kind: RuntimeDiscontinuityKind in [
                .captureStopped(reason: .diskFull), .captureStopped(reason: .deviceLost)
            ] {
                #expect(throws: RuntimePreparationError.unmappedIdentity(.stream(stream, direction: .capture))) {
                    try playback.discontinuity(kind, sample: stamp, stream: stream)
                }
                _ = try prepared.discontinuity(kind, sample: stamp, stream: stream)
            }
            let missing = StreamID(validated: "stream.unknown")
            #expect(throws: RuntimePreparationError.undeclaredStream(missing)) {
                try prepared.discontinuity(.sourceLost, sample: stamp, stream: missing)
            }
            for kind: RuntimeDiscontinuityKind in [.sourceLost, .sourceRestored, .formatChange] {
                _ = try prepared.discontinuity(kind, sample: stamp, stream: stream)
            }
            for kind: RuntimeDiscontinuityKind in [.sampleJump, .locate, .loopWrap] {
                _ = try prepared.discontinuity(kind, sample: stamp)
            }
        }
    }
}
