import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

extension RealtimeHandoffTests {
    struct PolicyValidation {
        @Test func policyRequiresExactlyOneConsumer() {
            #expect(Root.violation(Root.policy()) == nil)
            #expect(Root.violation(Root.telemetryPolicy()) == nil)
            #expect(Root.violation(Root.sysexPolicy()) == nil)
            for count in Root.adversarialInts where count != 1 {
                #expect(Root.violation(Root.policy(consumers: count)) == .r1SingleConsumer)
                #expect(Root.violation(Root.telemetryPolicy(consumers: count)) == .r1SingleConsumer)
                #expect(Root.violation(Root.sysexPolicy(consumers: count)) == .r1SingleConsumer)
            }
        }

        @Test func singleProducerRequiresVerifiedOrAppOwnedEvidence() {
            for producer in [ExecutionContext.midiReceive, .auHost] {
                let single = { (evidence: CardinalityEvidence) in
                    Root.policy(producer: producer, producers: .init(maximum: 1, evidence: evidence))
                }
                for evidence in CardinalityEvidence.allCases {
                    #expect(Root.violation(single(evidence)) == (evidence == .verified ? nil : .r2Cardinality))
                }
                let fanIn = ProducerCardinality(maximum: 2, evidence: .appOwned)
                #expect(Root.violation(Root.policy(producer: producer, producers: fanIn)) == .r2Cardinality)
            }
            for producer in [ExecutionContext.render, .control, .ui, .worker] {
                for evidence in CardinalityEvidence.allCases {
                    let single = Root.policy(producer: producer, producers: .init(maximum: 1, evidence: evidence))
                    #expect(Root.violation(single) == (evidence == .assumedConservative ? .r2Cardinality : nil))
                }
            }
        }

        @Test func midiAndAUProducersDefaultToFanIn() {
            #expect(KernelLimits.defaultFanInProducers == 64)
            for producer in [ExecutionContext.midiReceive, .auHost, .worker] {
                #expect(ProducerCardinality.conservativeDefault(for: producer)
                        == .init(maximum: KernelLimits.defaultFanInProducers, evidence: .assumedConservative))
                let assumedSingle = ProducerCardinality(maximum: 1, evidence: .assumedConservative)
                #expect(Root.violation(Root.policy(producer: producer, producers: assumedSingle)) == .r2Cardinality)
            }
            for producer in [ExecutionContext.render, .control, .ui] {
                #expect(ProducerCardinality.conservativeDefault(for: producer)
                        == .init(maximum: 1, evidence: .appOwned))
            }
            for producer in ExecutionContext.allCases {
                let cardinality = ProducerCardinality.conservativeDefault(for: producer)
                #expect(Root.violation(Root.policy(producer: producer, producers: cardinality)) == nil)
                for maximum in [2, KernelLimits.maximumProducers] {
                    let fanIn = ProducerCardinality(maximum: maximum, evidence: .assumedConservative)
                    #expect(Root.violation(Root.policy(producer: producer, producers: fanIn)) == nil)
                }
            }
            #expect(KernelLimits.maximumProducers == 64)
            for maximum in Root.adversarialInts + [65] where !(1...64).contains(maximum) {
                let verified = ProducerCardinality(maximum: maximum, evidence: .verified)
                #expect(Root.violation(Root.policy(producers: verified)) == .r2Cardinality)
            }
        }

        @Test func capacityBoundsAreInclusive() {
            #expect(KernelLimits.maximumCapacity == 65_536)
            for capacity in [1, 2, 65_535, 65_536] {
                #expect(Root.violation(Root.policy(capacity: capacity)) == nil)
            }
            for capacity in Root.adversarialInts + [65_537] where !(1...65_536).contains(capacity) {
                #expect(Root.violation(Root.policy(capacity: capacity)) == .r3Capacity)
            }
        }

        @Test func latestOnlyIsTelemetryOnlyAndViceVersa() {
            #expect(Root.violation(Root.policy(ordering: .latestOnly)) == .r4LatestOnly)
            #expect(Root.violation(Root.policy(overflow: .overwriteLatest)) == .r4LatestOnly)
            #expect(Root.violation(Root.policy(ordering: .latestOnly, overflow: .overwriteLatest)) == .r4LatestOnly)
            #expect(Root.violation(Root.sysexPolicy(overflow: .overwriteLatest)) == .r4LatestOnly)
            #expect(Root.violation(Root.sysexPolicy(ordering: .latestOnly)) == .r4LatestOnly)
            let telemetry = { (ordering: HandoffOrdering, overflow: OverflowPolicy) in
                Root.policy(purpose: .telemetry, producer: .render, consumer: .ui, ordering: ordering,
                            deadline: .none, overflow: overflow)
            }
            #expect(Root.violation(telemetry(.latestOnly, .overwriteLatest)) == nil)
            #expect(Root.violation(telemetry(.fifo, .overwriteLatest)) == .r4LatestOnly)
            #expect(Root.violation(telemetry(.latestOnly, .refuseProducer)) == .r4LatestOnly)
            #expect(Root.violation(telemetry(.latestOnly, .reservedCritical(reserved: 1))) == .r4LatestOnly)
        }

        @Test func telemetryNeverDrainsOnRender() {
            #expect(Root.violation(Root.telemetryPolicy(consumer: .render)) == .r5TelemetryNotRender)
            for consumer in [ExecutionContext.ui, .control] {
                #expect(Root.violation(Root.telemetryPolicy(consumer: consumer)) == nil)
            }
            for consumer in [ExecutionContext.worker, .midiReceive, .auHost] {
                #expect(Root.violation(Root.telemetryPolicy(consumer: consumer)) == .r5TelemetryNotRender)
            }
            let fromControl = Root.policy(purpose: .telemetry, producer: .control, consumer: .ui,
                                          ordering: .latestOnly, deadline: .none, overflow: .overwriteLatest)
            #expect(Root.violation(fromControl) == .r5TelemetryNotRender)
            #expect(Root.violation(Root.sysexPolicy(consumer: .render)) == .r5TelemetryNotRender)
            #expect(Root.violation(Root.policy(purpose: .faults)) == .r5TelemetryNotRender)
            #expect(Root.violation(Root.policy(purpose: .faults, consumer: .control)) == nil)
            #expect(Root.violation(Root.policy(purpose: .retire, deadline: .none)) == .r5TelemetryNotRender)
            for consumer in ExecutionContext.allCases {
                let retire = Root.policy(purpose: .retire, producer: .render, consumer: consumer, deadline: .none)
                #expect(Root.violation(retire) == (consumer == .control ? nil : .r5TelemetryNotRender))
            }
            for purpose in HandoffPurpose.allCases {
                let onRender = switch purpose {
                case .events: Root.policy()
                case .telemetry: Root.telemetryPolicy(consumer: .render)
                case .sysex: Root.sysexPolicy(consumer: .render)
                case .faults, .retire: Root.policy(purpose: purpose, deadline: .none)
                }
                #expect(onRender.consumer == .render)
                #expect(Root.violation(onRender) == (purpose == .events ? nil : .r5TelemetryNotRender))
            }
        }

        @Test func renderEventsRequireFiniteDeadline() {
            #expect(Root.violation(Root.policy(deadline: .none)) == .r6RenderDeadline)
            #expect(Root.violation(Root.policy(consumer: .control, deadline: .none)) == nil)
            #expect(Root.violation(Root.policy(deadline: .frames(lateTolerance: 0, lookahead: 1))) == nil)
            for frame in Root.adversarialFrames {
                let tolerance = Root.policy(deadline: .frames(lateTolerance: frame, lookahead: 1))
                let lookahead = Root.policy(deadline: .frames(lateTolerance: 0, lookahead: frame))
                #expect(Root.violation(tolerance) == ((0...1).contains(frame) ? nil : .r6RenderDeadline))
                #expect(Root.violation(lookahead) == ((1...(1 << 24)).contains(frame) ? nil : .r6RenderDeadline))
            }
            #expect(KernelLimits.maximumHorizonFrames == 1 << 24)
            let horizon = KernelLimits.maximumHorizonFrames
            let valid: [DeadlineHorizon] = [.frames(lateTolerance: 0, lookahead: horizon),
                                            .frames(lateTolerance: horizon, lookahead: horizon),
                                            .frames(lateTolerance: 1, lookahead: 1)]
            let invalid: [DeadlineHorizon] = [.frames(lateTolerance: 0, lookahead: horizon + 1),
                                              .frames(lateTolerance: horizon + 1, lookahead: horizon + 1),
                                              .frames(lateTolerance: 0, lookahead: .max),
                                              .frames(lateTolerance: 2, lookahead: 1)]
            for deadline in valid {
                #expect(Root.violation(Root.policy(deadline: deadline)) == nil)
            }
            for deadline in invalid {
                #expect(Root.violation(Root.policy(deadline: deadline)) == .r6RenderDeadline)
            }
            // The horizon bounds apply to every declared `.frames`, not only render-consumed events.
            let malformed: [DeadlineHorizon] = [.frames(lateTolerance: -1, lookahead: 1),
                                                .frames(lateTolerance: 0, lookahead: 0)]
            for deadline in malformed {
                #expect(Root.violation(Root.policy(consumer: .control, deadline: deadline)) == .r6RenderDeadline)
            }
            let telemetry = Root.policy(purpose: .telemetry, producer: .render, consumer: .ui, ordering: .latestOnly,
                                        deadline: .frames(lateTolerance: 0, lookahead: 0), overflow: .overwriteLatest)
            #expect(Root.violation(telemetry) == .r6RenderDeadline)
        }

        @Test func reserveMustLeaveGeneralRoom() {
            for reserved in [1, 128, 255] {
                #expect(Root.violation(Root.policy(overflow: .reservedCritical(reserved: reserved))) == nil)
            }
            for reserved in Root.adversarialInts + [256, 257] where !(1..<256).contains(reserved) {
                #expect(Root.violation(Root.policy(overflow: .reservedCritical(reserved: reserved))) == .r7Reserve)
            }
            #expect(Root.violation(Root.policy(capacity: 1, overflow: .reservedCritical(reserved: 1))) == .r7Reserve)
            let defaults = [(17, 16), (128, 16), (136, 17), (256, 32), (65_536, 8_192)]
            for (capacity, reserved) in defaults {
                let overflow = OverflowPolicy.defaultCriticalReserve(capacity: capacity)
                #expect(overflow == .reservedCritical(reserved: reserved))
                if let overflow {
                    #expect(Root.violation(Root.policy(capacity: capacity, overflow: overflow)) == nil)
                }
            }
            for capacity in Root.adversarialInts + [16, 65_537] {
                #expect(OverflowPolicy.defaultCriticalReserve(capacity: capacity) == nil)
            }
        }

        @Test func sysexIsCompleteMessagesAndRefusing() {
            #expect(Root.violation(Root.sysexPolicy()) == nil)
            #expect(Root.violation(Root.sysexPolicy(ordering: .fifo)) == .r8SysExSeparate)
            #expect(Root.violation(Root.sysexPolicy(ordering: .fifoPerProducer)) == .r8SysExSeparate)
            #expect(Root.violation(Root.sysexPolicy(overflow: .reservedCritical(reserved: 1))) == .r8SysExSeparate)
            #expect(Root.violation(Root.sysexPolicy(ordering: .latestOnly, overflow: .overwriteLatest))
                    == .r4LatestOnly)
            // Complete-message ordering is SysEx-only (R8 is two-way, like R4).
            #expect(Root.violation(Root.policy(ordering: .completeMessagesFIFO)) == .r8SysExSeparate)
            #expect(Root.violation(Root.policy(purpose: .faults, consumer: .control, ordering: .completeMessagesFIFO))
                    == .r8SysExSeparate)
        }

        /// `validate()` reports the lowest-numbered broken rule; repairing one rule at a time walks R1…R8.
        @Test func firstViolationFollowsRuleOrder() {
            let assumedSingle = ProducerCardinality(maximum: 1, evidence: .assumedConservative)
            let appOwned = ProducerCardinality(maximum: 1, evidence: .appOwned)
            let badDeadline = DeadlineHorizon.frames(lateTolerance: -1, lookahead: 0)
            let stages: [(HandoffPolicy, HandoffPolicyRule?)] = [
                (Root.policy(purpose: .telemetry, producers: assumedSingle, consumers: 2, capacity: 0,
                             ordering: .completeMessagesFIFO, deadline: badDeadline,
                             overflow: .reservedCritical(reserved: 0)), .r1SingleConsumer),
                (Root.policy(purpose: .telemetry, producers: assumedSingle, capacity: 0,
                             ordering: .completeMessagesFIFO,
                             deadline: badDeadline, overflow: .reservedCritical(reserved: 0)), .r2Cardinality),
                (Root.policy(purpose: .telemetry, producers: appOwned, capacity: 0, ordering: .completeMessagesFIFO,
                             deadline: badDeadline, overflow: .reservedCritical(reserved: 0)), .r3Capacity),
                (Root.policy(purpose: .telemetry, ordering: .completeMessagesFIFO, deadline: badDeadline,
                             overflow: .reservedCritical(reserved: 0)), .r4LatestOnly),
                (Root.policy(purpose: .faults, ordering: .completeMessagesFIFO, deadline: badDeadline,
                             overflow: .reservedCritical(reserved: 0)), .r5TelemetryNotRender),
                (Root.policy(purpose: .faults, consumer: .control, ordering: .completeMessagesFIFO,
                             deadline: badDeadline, overflow: .reservedCritical(reserved: 0)), .r6RenderDeadline),
                (Root.policy(purpose: .faults, consumer: .control, ordering: .completeMessagesFIFO, deadline: .none,
                             overflow: .reservedCritical(reserved: 0)), .r7Reserve),
                (Root.policy(purpose: .faults, consumer: .control, ordering: .completeMessagesFIFO, deadline: .none),
                 .r8SysExSeparate),
                (Root.policy(purpose: .faults, consumer: .control, deadline: .none), nil)
            ]
            for (policy, rule) in stages {
                #expect(Root.violation(policy) == rule)
            }
        }

        @Test func statusValuesAreBitwiseCopyable() {
            Root.requireBitwise(KernelStatus.self)
            Root.requireBitwise(KernelRefusal.self)
            Root.requireBitwise(SilenceReason.self)
            Root.requireBitwise(ExecutionContext.self)
            #expect(MemoryLayout<KernelStatus>.size <= 2)
            let statuses: [KernelStatus] = [.ok, .empty] + KernelRefusal.allCases.map { .refused($0) }
                + SilenceReason.allCases.map { .silenced($0) }
            #expect(statuses.count == 2 + 7 + 4)
            for (index, status) in statuses.enumerated() {
                #expect(statuses.indices.filter { statuses[$0] == status } == [index])
            }
        }
    }
}
