import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphCompilerPlanTests {
    @Test
    func oneForgedDraftTableCoversStructuralInvariantsAndOverflow() throws {
        let valid = try RoutingScheduleBuilder.build(Self.directGraph(), request: Self.request())
        let baseline = RoutingScheduleDraft(
            graph: valid.graph, revision: valid.revision, inputs: valid.inputs, steps: valid.steps,
            outputs: valid.outputs, delayLines: valid.delayLines
        )
        let inputNode = baseline.inputs[0].endpoint.node
        let inputSlot = baseline.inputs[0].slot
        let edge = EdgeID(validated: "plan.forged.feedback")
        let cut = try FeedbackCut.make(
            edge: edge, feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: 0),
            channels: 2, blockFrames: valid.blockFrames
        )
        let cases: [(RoutingInconsistency, (inout RoutingScheduleDraft) -> Void)] = [
            (.duplicateNode, { $0.steps[0] = Self.withNode($0.steps[0], inputNode) }),
            (.slotLayout, {
                $0.inputs[0] = RoutingEndpoint(endpoint: $0.inputs[0].endpoint,
                                               slot: RoutingSlot(offset: 1, channels: 1, frames: 2))
            }),
            (.stepOrder, { $0.steps[0] = Self.withLevel($0.steps[0], -1) }),
            (.rowShape, { $0.steps[0] = Self.withRows($0.steps[0], []) }),
            (.termSource, { $0.steps[0] = Self.withRows(
                $0.steps[0], [RoutingRow(terms: [999], isBitCopy: true)]
            ) }),
            (.causality, { $0.steps[0] = Self.withLevel($0.steps[0], 0) }),
            (.endpoint, {
                $0.inputs[0] = RoutingEndpoint(
                    endpoint: Self.withFirstChannel($0.inputs[0].endpoint, 1), slot: $0.inputs[0].slot
                )
            }),
            (.delayLine, { $0.delayLines.append(RoutingDelayLine(
                cut: cut, source: inputSlot, delayed: inputSlot, storage: inputSlot
            )) })
        ]
        for (invariant, mutate) in cases {
            var forged = baseline
            mutate(&forged)
            #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(invariant)) {
                try RoutingSchedule.make(draft: forged, request: Self.request())
            }
        }
        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.slotSamples)) {
            try RoutingMath.multiply(Int.max, 2, resource: .slotSamples)
        }
    }

    @Test
    func feedbackSourceCannotAliasAnotherDelayLinesDelayedSlot() throws {
        let valid = try Self.twoLineFeedbackPlan()
        var forged = RoutingScheduleDraft(
            graph: valid.graph, revision: valid.revision, inputs: valid.inputs, steps: valid.steps,
            outputs: valid.outputs, delayLines: valid.delayLines
        )
        let first = valid.delayLines[0]
        let otherDelayed = valid.delayLines[1].delayed
        forged.delayLines[0] = RoutingDelayLine(
            cut: first.cut, source: otherDelayed, delayed: first.delayed, storage: first.storage
        )
        #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.delayLine)) {
            try RoutingSchedule.make(draft: forged, request: Self.request(frames: 2))
        }
    }

    static func withNode(_ step: RoutingStep, _ node: NodeID) -> RoutingStep {
        RoutingStep(
            node: node, level: step.level, operation: step.operation, output: step.output,
            rows: step.rows, mixOrder: step.mixOrder
        )
    }

    static func withLevel(_ step: RoutingStep, _ level: Int) -> RoutingStep {
        RoutingStep(
            node: step.node, level: level, operation: step.operation, output: step.output,
            rows: step.rows, mixOrder: step.mixOrder
        )
    }

    static func withRows(_ step: RoutingStep, _ rows: [RoutingRow]) -> RoutingStep {
        RoutingStep(
            node: step.node, level: step.level, operation: step.operation, output: step.output,
            rows: rows, mixOrder: step.mixOrder
        )
    }

    static func withFirstChannel(_ endpoint: AudioRoutingEndpoint, _ first: Int) -> AudioRoutingEndpoint {
        AudioRoutingEndpoint(
            node: endpoint.node, port: endpoint.port, role: endpoint.role,
            channels: endpoint.channels, firstChannel: first
        )
    }
}
