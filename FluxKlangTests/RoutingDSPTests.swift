import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct RoutingDSPTests {
    private typealias Fixtures = AudioRoutingTestFixtures

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
