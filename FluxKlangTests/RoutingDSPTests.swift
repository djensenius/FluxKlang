import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct RoutingDSPTests {
    private typealias Fixtures = AudioRoutingTestFixtures

    @Test func identityAndExplicitSingleTermMapDifferOnNegativeZero() throws {
        let identity = try render(Fixtures.documents(inputChannels: 1, outputChannels: 1), channels: [-0.0])
        let mapped = try render(
            Fixtures.documents(inputChannels: 1, outputChannels: 1, map: [[0]]), channels: [-0.0]
        )
        #expect(identity.output[0].bitPattern == Float(-0.0).bitPattern)
        #expect(mapped.output[0].bitPattern == Float.zero.bitPattern)
    }
}

extension RoutingDSPTests {
    private func replacingPlan(
        _ plan: PreparedAudioRoutingPlan, in documents: Fixtures.Documents,
        layout: AudioRoutingLayout? = nil, rows: [PreparedAudioRoutingPlan.Row]? = nil,
        terms: [Int]? = nil, mute: PreparedAudioRoutingPlan.Mute? = nil
    ) throws -> PreparedAudioRoutingPlan {
        let geometry = try AudioRoutingAdmission.preflight(
            project: documents.project, graph: documents.graph, limits: plan.bounds
        )
        return PreparedAudioRoutingPlan(
            layout: layout ?? plan.layout, bounds: plan.bounds, geometry: geometry,
            mute: mute ?? plan.mute, rows: rows ?? plan.rows, terms: terms ?? plan.terms
        )
    }

    private func validatePlan(
        _ plan: PreparedAudioRoutingPlan, in documents: Fixtures.Documents
    ) throws {
        let geometry = try AudioRoutingAdmission.preflight(
            project: documents.project, graph: documents.graph, limits: plan.bounds
        )
        try AudioRoutingCompiler.validateCorrespondence(
            plan: plan, graph: documents.graph, limits: plan.bounds, geometry: geometry
        )
    }

    @Test func planCorrespondenceRejectsWrongEndpointRoleAndOutputRowDescriptors() throws {
        var documents = Fixtures.documents()
        try Fixtures.appendEndpoint(to: &documents, input: true, suffix: "source2")
        try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "output2")
        let secondSource = try #require(documents.graph.nodes.first { $0.id == NodeID(validated: "node.source2") })
        let secondOutput = try #require(documents.graph.nodes.first { $0.id == NodeID(validated: "node.output2") })
        var secondEdge = documents.graph.edges[0]
        secondEdge.id = EdgeID(validated: "edge.second")
        secondEdge.from.node = secondSource.id
        secondEdge.to.node = secondOutput.id
        documents.graph.edges.append(secondEdge)
        let plan = try Fixtures.compile(documents)

        let firstRow = try #require(plan.rows.first)
        let invalidRows = [
            PreparedAudioRoutingPlan.Row(
                firstTerm: firstRow.firstTerm + 1, termCount: firstRow.termCount, isIdentity: firstRow.isIdentity
            ),
            PreparedAudioRoutingPlan.Row(
                firstTerm: firstRow.firstTerm, termCount: firstRow.termCount - 1, isIdentity: firstRow.isIdentity
            ),
            PreparedAudioRoutingPlan.Row(
                firstTerm: firstRow.firstTerm, termCount: firstRow.termCount, isIdentity: false
            )
        ]
        for invalidRow in invalidRows {
            var rows = plan.rows
            rows[0] = invalidRow
            let malformedRows = try replacingPlan(plan, in: documents, rows: rows)
            #expect(throws: AudioRoutingPreparationError.unsupported) {
                try validatePlan(malformedRows, in: documents)
            }
        }

        var inputs = plan.layout.inputs
        let firstInputNode = try #require(plan.layout.inputs.first?.node)
        let firstInputIndex = try #require(inputs.firstIndex { $0.node == firstInputNode })
        let firstInput = inputs[firstInputIndex]
        let alternateInput = try #require(inputs.first { $0.node != firstInputNode })
        let wrongInput = AudioRoutingEndpoint(
            node: firstInput.node, port: firstInput.port, role: alternateInput.role,
            channels: firstInput.channels, firstChannel: firstInput.firstChannel
        )
        inputs[firstInputIndex] = wrongInput
        let badLayout = AudioRoutingLayout(
            graph: plan.layout.graph, revision: plan.layout.revision, maxFrames: plan.layout.maxFrames,
            inputs: inputs, outputs: plan.layout.outputs,
            inputSampleCount: plan.layout.inputSampleCount, outputSampleCount: plan.layout.outputSampleCount,
            peakCount: plan.layout.peakCount
        )
        let wrongIdentity = try replacingPlan(plan, in: documents, layout: badLayout)
        #expect(throws: AudioRoutingPreparationError.unsupported) {
            try validatePlan(wrongIdentity, in: documents)
        }
    }

    @Test func planCorrespondenceRejectsReorderedAndDuplicatedConvertedTerms() throws {
        let documents = Fixtures.muteDocuments(
            false, channels: 3,
            inputMap: [[2, 0], [1, 1], [0]],
            outputMap: [[1, 0], [2, 2], [0, 1]]
        )
        let plan = try Fixtures.compile(documents)
        let mute = try #require(plan.mute)
        let muteRow = try #require(mute.rows.first { $0.termCount >= 2 })
        let muteSecondTerm = try #require(
            muteRow.firstTerm >= 0 && muteRow.firstTerm < plan.terms.count - 1 ? muteRow.firstTerm + 1 : nil
        )
        let outputRow = try #require(plan.rows.first { $0.termCount >= 2 })
        let outputSecondTerm = try #require(
            outputRow.firstTerm >= 0 && outputRow.firstTerm < plan.terms.count - 1
                ? outputRow.firstTerm + 1 : nil
        )
        var reorderedMuteTerms = plan.terms
        reorderedMuteTerms.swapAt(muteRow.firstTerm, muteSecondTerm)
        var duplicateMuteTerms = plan.terms
        duplicateMuteTerms[muteSecondTerm] = duplicateMuteTerms[muteRow.firstTerm]
        var reorderedOutputTerms = plan.terms
        reorderedOutputTerms.swapAt(outputRow.firstTerm, outputSecondTerm)
        var duplicateOutputTerms = plan.terms
        duplicateOutputTerms[outputSecondTerm] = duplicateOutputTerms[outputRow.firstTerm]

        for terms in [reorderedMuteTerms, duplicateMuteTerms, reorderedOutputTerms, duplicateOutputTerms] {
            let malformed = try replacingPlan(plan, in: documents, terms: terms)
            #expect(throws: AudioRoutingPreparationError.unsupported) {
                try validatePlan(malformed, in: documents)
            }
        }
    }

    @Test func planCorrespondenceRejectsWrongMuteGeometry() throws {
        let documents = Fixtures.muteDocuments(false)
        let plan = try Fixtures.compile(documents)
        let mute = try #require(plan.mute)
        let malformedMute = PreparedAudioRoutingPlan.Mute(
            node: mute.node, inputPort: mute.inputPort, outputPort: mute.outputPort, muted: mute.muted,
            inputOffset: mute.inputOffset + 1, resultOffset: mute.resultOffset, rows: mute.rows
        )
        #expect(throws: AudioRoutingPreparationError.unsupported) {
            try validatePlan(replacingPlan(plan, in: documents, mute: malformedMute), in: documents)
        }

        let wrongMuteBit = PreparedAudioRoutingPlan.Mute(
            node: mute.node, inputPort: mute.inputPort, outputPort: mute.outputPort, muted: !mute.muted,
            inputOffset: mute.inputOffset, resultOffset: mute.resultOffset, rows: mute.rows
        )
        #expect(throws: AudioRoutingPreparationError.unsupported) {
            try validatePlan(replacingPlan(plan, in: documents, mute: wrongMuteBit), in: documents)
        }

        let wrongPortIdentity = PreparedAudioRoutingPlan.Mute(
            node: mute.node, inputPort: mute.outputPort, outputPort: mute.outputPort, muted: mute.muted,
            inputOffset: mute.inputOffset, resultOffset: mute.resultOffset, rows: mute.rows
        )
        #expect(throws: AudioRoutingPreparationError.unsupported) {
            try validatePlan(replacingPlan(plan, in: documents, mute: wrongPortIdentity), in: documents)
        }

        let firstMuteRow = try #require(mute.rows.first)
        let invalidRows = [
            PreparedAudioRoutingPlan.Row(
                firstTerm: firstMuteRow.firstTerm + 1,
                termCount: firstMuteRow.termCount,
                isIdentity: firstMuteRow.isIdentity
            ),
            PreparedAudioRoutingPlan.Row(
                firstTerm: firstMuteRow.firstTerm,
                termCount: firstMuteRow.termCount - 1,
                isIdentity: firstMuteRow.isIdentity
            ),
            PreparedAudioRoutingPlan.Row(
                firstTerm: firstMuteRow.firstTerm, termCount: firstMuteRow.termCount, isIdentity: false
            )
        ]
        for invalidRow in invalidRows {
            var rows = mute.rows
            rows[0] = invalidRow
            let corruptedMute = PreparedAudioRoutingPlan.Mute(
                node: mute.node, inputPort: mute.inputPort, outputPort: mute.outputPort, muted: mute.muted,
                inputOffset: mute.inputOffset, resultOffset: mute.resultOffset, rows: rows
            )
            #expect(throws: AudioRoutingPreparationError.unsupported) {
                try validatePlan(replacingPlan(plan, in: documents, mute: corruptedMute), in: documents)
            }
        }
    }

    @Test func planCorrespondenceAcceptsSortedDisconnectedAndEmptyComponents() throws {
        var reordered = Fixtures.documents()
        reordered.graph.nodes.reverse()
        let reorderedPlan = try Fixtures.compile(reordered)
        try validatePlan(reorderedPlan, in: reordered)

        var disconnected = Fixtures.muteDocuments(false)
        disconnected.graph.edges = []
        let disconnectedPlan = try Fixtures.compile(disconnected)
        try validatePlan(disconnectedPlan, in: disconnected)

        var empty = Fixtures.documents()
        empty.graph.nodes = []
        empty.graph.edges = []
        let emptyPlan = try Fixtures.compile(empty)
        try validatePlan(emptyPlan, in: empty)
    }
}

extension RoutingDSPTests {
    @Test func muteBitCopiesOrStoresPositiveZeroAtWidthBoundariesAndReversedPorts() throws {
        let samples: [Float] = [0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude]
        for channels in [1, 64] {
            for muted in [false, true] {
                var documents = Fixtures.muteDocuments(muted, channels: channels)
                documents.graph.nodes[2].ports.reverse()
                documents.graph.nodes.reverse()
                documents.graph.edges.reverse()
                var processor = try OfflineAudioRoutingProcessor(
                    project: documents.project, selectedGraph: documents.graph,
                    limits: Fixtures.limits(
                        frames: 4, inputs: 64, outputs: 64, terms: 128, scratch: 65_536, work: 65_536
                    )
                )
                let input = (0..<(channels * 4)).map { samples[$0 % 4] }
                for frames in [4, 1, 0, 2, 4] {
                    var output = [Float](repeating: -37, count: channels * 4)
                    var peaks = [Float](repeating: -1, count: channels)
                    #expect(Fixtures.process(
                        &processor, frames: frames, input: input, output: &output, peaks: &peaks
                    ) == .processed)
                    for channel in 0..<channels {
                        for frame in 0..<4 {
                            let expected: Float = frame >= frames ? -37 : (muted ? 0 : samples[frame])
                            #expect(output[channel * 4 + frame].bitPattern == expected.bitPattern)
                        }
                        let peak: Float = !muted && frames == 4 ? .leastNonzeroMagnitude : 0
                        #expect(peaks[channel].bitPattern == peak.bitPattern)
                    }
                }
            }
        }
    }

    @Test func mapsOnBothSidesPreservePrimitiveBoundaryOrderAndDuplicates() throws {
        let documents = Fixtures.muteDocuments(
            false, channels: 3, inputMap: [[0, 1, 2], [0, 2, 1], [2, 2, 2]],
            outputMap: [[0, 2, 0], [1, 0], []]
        )
        let result = try render(documents, channels: [16_777_216, -16_777_216, 1])
        #expect(result.output == [5, 1, 0])
        #expect(result.peaks == [5, 1, 0])
        let downstream = Fixtures.muteDocuments(
            false, channels: 3, outputMap: [[0, 1, 2], [0, 2, 1], [2, 2, 2]]
        )
        #expect(try render(downstream, channels: [16_777_216, -16_777_216, 1]).output == [1, 0, 3])
        for inputMap in [nil, [[0]]] as [[[Int]]?] {
            for outputMap in [nil, [[0]]] as [[[Int]]?] {
                let mapped = Fixtures.muteDocuments(
                    false, channels: 1, inputMap: inputMap, outputMap: outputMap
                )
                let sample = try render(mapped, channels: [-0.0]).output[0]
                let expected: Float = inputMap == nil && outputMap == nil ? -0.0 : 0
                #expect(sample.bitPattern == expected.bitPattern)
            }
        }
        let widthChanges = Fixtures.muteDocuments(
            false, channels: 1, inputChannels: 2, outputChannels: 2,
            inputMap: [[1, 0]], outputMap: [[0], [0, 0]]
        )
        #expect(try render(widthChanges, channels: [2, -3]).output == [-1, -2])
    }

    @Test func muteFanoutDirectRoutesAndUnconnectedInputsAndOutputs() throws {
        for muted in [false, true] {
            var documents = Fixtures.muteDocuments(muted)
            try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "second")
            try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "direct")
            try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "unconnected")
            var fanout = documents.graph.edges[1]
            fanout.id = EdgeID(validated: "edge.fanout")
            fanout.to.node = NodeID(validated: "node.second")
            documents.graph.edges.append(fanout)
            var direct = Fixtures.documents().graph.edges[0]
            direct.to.node = NodeID(validated: "node.direct")
            documents.graph.edges.append(direct)
            let result = try render(documents, channels: [-2, 3])
            let branch: [Float] = muted ? [0, 0] : [-2, 3]
            #expect(result.output == [-2, 3] + branch + branch + [0, 0])
            #expect(result.peaks == result.output.map { abs($0) })
            documents.graph.edges.removeFirst() // Unconnected mute input is positive zero.
            let unconnected = try render(documents, channels: [-2, 3])
            #expect(unconnected.output == [-2, 3, 0, 0, 0, 0, 0, 0])
            #expect(unconnected.output.dropFirst(2).allSatisfy { $0.bitPattern == Float.zero.bitPattern })
        }
    }

    @Test func preparedMuteAndMapsDoNotObserveDocumentMutations() throws {
        var documents = Fixtures.muteDocuments(false)
        var original = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        var input = [Float](repeating: 0, count: 32)
        input[0] = 2
        input[16] = -3
        var output = [Float](repeating: -1, count: 32)
        var peaks: [Float] = [-1, -1]
        for muted in [true, false] {
            documents.graph.nodes[2].muted = muted
            documents.graph.edges[0].conversion = EdgeConversion(map: [[1], [0]])
            documents.graph.edges[1].conversion = EdgeConversion(map: [[0, 0], [1]])
            #expect(Fixtures.process(
                &original, frames: 1, input: input, output: &output, peaks: &peaks
            ) == .processed)
            #expect(output[0] == 2 && output[16] == -3 && peaks == [2, 3])
            let fresh = try render(documents, channels: [2, -3])
            #expect(fresh.output == (muted ? [0, 0] : [-6, 2]))
        }
        documents.graph.nodes = []
        documents.graph.edges = []
        #expect(Fixtures.process(
            &original, frames: 1, input: input, output: &output, peaks: &peaks
        ) == .processed)
        #expect(output[0] == 2 && output[16] == -3)
    }
}

extension RoutingDSPTests {
    @Test func identityCopiesFloat32AndComputesRealSamplePeaks() throws {
        let documents = Fixtures.documents()
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        var input = [Float](repeating: .nan, count: 32)
        input[0] = -0.25
        input[1] = 0.5
        input[16] = -2
        input[17] = 1.5
        var output = [Float](repeating: .nan, count: 32)
        var peaks: [Float] = [-1, -1]
        #expect(Fixtures.process(&processor, frames: 2, input: input, output: &output, peaks: &peaks) == .processed)
        #expect(Array(output[0..<2]) == [-0.25, 0.5])
        #expect(Array(output[16..<18]) == [-2, 1.5])
        #expect(peaks == [0.5, 2])
        let firstPaddingIsNaN = output[2..<16].allSatisfy(\.isNaN)
        let secondPaddingIsNaN = output[18..<32].allSatisfy(\.isNaN)
        #expect(firstPaddingIsNaN)
        #expect(secondPaddingIsNaN)
        input[0] = -Float.zero
        #expect(Fixtures.process(&processor, frames: 1, input: input, output: &output, peaks: &peaks) == .processed)
        #expect(output[0].bitPattern == (-Float.zero).bitPattern)
        #expect(peaks == [0, 2])
    }

    @Test func swapDuplicationStereoSumAndMixedSilentRows() throws {
        let cases: [(map: [[Int]], expected: [Float])] = [
            ([[1], [0]], [-2, 0.5]),
            ([[0], [0]], [0.5, 0.5]),
            ([[0, 1]], [-1.5]),
            ([[0, 1], []], [-1.5, 0]),
            ([[], [1]], [0, -2]),
            ([[0, 1, 0], [1, 1]], [-1, -4])
        ]
        for item in cases {
            let documents = Fixtures.documents(outputChannels: item.map.count, map: item.map)
            let result = try render(documents, channels: [0.5, -2])
            #expect(result.output == item.expected)
            #expect(result.peaks == item.expected.map { abs($0) })
        }
        let mono = Fixtures.documents(inputChannels: 1, map: [[0], [0]])
        let result = try render(mono, channels: [-0.75])
        #expect(result.output == [-0.75, -0.75])
        #expect(result.peaks == [0.75, 0.75])
    }

    @Test func declaredOrderAndDuplicateTermsAreFloat32NotWidenedOrReassociated() throws {
        let documents = Fixtures.documents(
            inputChannels: 3, outputChannels: 3,
            map: [[0, 1, 2], [0, 2, 1], [2, 2, 2]]
        )
        let result = try render(documents, channels: [16_777_216, -16_777_216, 1])
        #expect(result.output == [1, 0, 3])
        #expect(result.peaks == [1, 0, 3])
        let plan = try Fixtures.compile(documents)
        #expect(plan.terms == [0, 16, 32, 0, 32, 16, 32, 32, 32])
    }

    @Test func fanoutAndUnconnectedOutputsUseTheSameStagedInput() throws {
        var documents = Fixtures.documents()
        try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "second")
        try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "unconnected")
        try Fixtures.appendEndpoint(to: &documents, input: true, suffix: "unused")
        var fanout = documents.graph.edges[0]
        fanout.id = EdgeID(validated: "edge.fanout")
        fanout.to.node = NodeID(validated: "node.second")
        documents.graph.edges.append(fanout)
        let plan = try Fixtures.compile(documents)
        #expect(plan.terms == [0, 16, 0, 16])
        #expect(plan.layout.inputs.map(\.firstChannel) == [0, 2])
        let result = try render(documents, channels: [-3, 0.25, 42, -42])
        #expect(result.output == [-3, 0.25, -3, 0.25, 0, 0])
        #expect(result.peaks == [3, 0.25, 3, 0.25, 0, 0])

        documents.graph.nodes.reverse()
        documents.graph.edges.reverse()
        documents.project.roles.reverse()
        for index in documents.graph.nodes.indices {
            documents.graph.nodes[index].label = "mute -inf dB"
            documents.graph.nodes[index].position = GraphPoint(x: -99, y: 1_000)
        }
        let reordered = try render(documents, channels: [-3, 0.25, 42, -42])
        #expect(reordered.output == result.output)
        #expect(reordered.peaks == result.peaks)
    }

    @Test func maximumBlockAndRepeatedCallsReuseScratchWithoutStalePeaks() throws {
        let documents = Fixtures.documents(map: [[0, 1], []])
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        var input = [Float](repeating: 2, count: 32)
        var output = [Float](repeating: -1, count: 32)
        var peaks: [Float] = [-1, -1]
        for iteration in 0..<20 {
            input[0] = Float(iteration)
            #expect(Fixtures.process(
                &processor, frames: 16, input: input, output: &output, peaks: &peaks
            ) == .processed)
            #expect(output[0] == Float(iteration) + 2)
            #expect(output[1..<16].allSatisfy { $0 == 4 })
            #expect(output[16..<32].allSatisfy { $0 == 0 })
            #expect(peaks == [max(Float(iteration) + 2, 4), 0])
        }
        input = [Float](repeating: 0, count: 32)
        #expect(Fixtures.process(&processor, frames: 16, input: input, output: &output, peaks: &peaks) == .processed)
        #expect(output.allSatisfy { $0 == 0 })
        #expect(peaks == [0, 0])
    }

    @Test func entirelyUnconnectedOutputsAreSilence() throws {
        var documents = Fixtures.documents()
        documents.graph.edges = []
        let result = try render(documents, channels: [12, -9])
        #expect(result.output == [0, 0])
        #expect(result.peaks == [0, 0])
    }

    private func render(
        _ documents: Fixtures.Documents, channels: [Float]
    ) throws -> (output: [Float], peaks: [Float]) {
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        let layout = processor.layout
        var input = [Float](repeating: .nan, count: layout.inputSampleCount)
        for (channel, sample) in channels.enumerated() { input[channel * layout.maxFrames] = sample }
        var output = [Float](repeating: .nan, count: layout.outputSampleCount)
        var peaks = [Float](repeating: -1, count: layout.peakCount)
        #expect(Fixtures.process(&processor, frames: 1, input: input, output: &output, peaks: &peaks) == .processed)
        for channel in 0..<layout.peakCount {
            let start = channel * layout.maxFrames
            let paddingIsNaN = output[(start + 1)..<(start + layout.maxFrames)].allSatisfy(\.isNaN)
            #expect(paddingIsNaN)
        }
        return ((0..<layout.peakCount).map { output[$0 * layout.maxFrames] }, peaks)
    }
}
