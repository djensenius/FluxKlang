import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct RoutingBoundaryTests {
    private typealias Fixtures = AudioRoutingTestFixtures

    private struct RoutingBufferCounts {
        let inputs: Int
        let outputs: Int
        let peaks: Int
    }
}

extension RoutingBoundaryTests {
    @Test func upstreamOverflowInUnusedMuteChannelRefusesEvenMutedOrWithoutConsumers() throws {
        for muted in [false, true] {
            for consumers in [false, true] {
                var documents = Fixtures.muteDocuments(
                    muted, inputChannels: 3, inputMap: [[2], [0, 1, 2]], outputMap: [[0], [0]]
                )
                if !consumers {
                    documents.graph.edges.removeLast()
                    documents.graph.edges.append(Fixtures.documents(
                        inputChannels: 3, map: [[2], [2]]
                    ).graph.edges[0])
                }
                var processor = try OfflineAudioRoutingProcessor(
                    project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
                )
                for _ in 0..<3 {
                    var input = [Float](repeating: .nan, count: 48)
                    for frame in 0..<2 {
                        input[frame] = .greatestFiniteMagnitude
                        input[16 + frame] = .greatestFiniteMagnitude
                        input[32 + frame] = -.greatestFiniteMagnitude
                    }
                    var output = [Float](repeating: .nan, count: 32)
                    var peaks: [Float] = [99, 99]
                    #expect(Fixtures.process(
                        &processor, frames: 2, input: input, output: &output, peaks: &peaks
                    ) == .refused(.nonFiniteSum))
                    expectSilenceWithNaNPadding(output, peaks: peaks)
                    for channel in 0..<3 {
                        input[channel * 16] = 1
                        input[channel * 16 + 1] = -2
                    }
                    #expect(Fixtures.process(
                        &processor, frames: 2, input: input, output: &output, peaks: &peaks
                    ) == .processed)
                    let expected: [Float] = muted && consumers ? [0, 0] : [1, -2]
                    #expect(Array(output[0..<2]) == expected && Array(output[16..<18]) == expected)
                    #expect(peaks == (muted && consumers ? [0, 0] : [2, 2]))
                }
            }
        }
    }

    @Test func lateDownstreamOrDirectOverflowSilencesCompletedFanoutAndRecovers() throws {
        for muted in [false, true] {
            var documents = Fixtures.muteDocuments(muted)
            try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "direct")
            try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "zzz")
            var direct = Fixtures.documents().graph.edges[0]
            direct.to.node = NodeID(validated: "node.direct")
            documents.graph.edges.append(direct)
            var late = documents.graph.edges[1]
            late.id = EdgeID(validated: "edge.late")
            late.to.node = NodeID(validated: "node.zzz")
            late.conversion = EdgeConversion(map: [[1], [0, 0, 1]])
            if muted { late.from = direct.from }
            documents.graph.edges.append(late)
            var processor = try OfflineAudioRoutingProcessor(
                project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
            )
            for _ in 0..<3 {
                var input = [Float](repeating: .nan, count: 32)
                input[0] = 1
                input[1] = .greatestFiniteMagnitude
                input[16] = -1
                input[17] = -.greatestFiniteMagnitude
                var output = [Float](repeating: -37, count: 96)
                var peaks = [Float](repeating: 99, count: 6)
                #expect(Fixtures.process(
                    &processor, frames: 2, input: input, output: &output, peaks: &peaks
                ) == .refused(.nonFiniteSum))
                for channel in 0..<6 {
                    #expect(output[channel * 16].bitPattern == Float.zero.bitPattern)
                    #expect(output[channel * 16 + 1].bitPattern == Float.zero.bitPattern)
                    #expect(output[(channel * 16 + 2)..<((channel + 1) * 16)].allSatisfy { $0 == -37 })
                }
                #expect(peaks.allSatisfy { $0.bitPattern == Float.zero.bitPattern })
                input[1] = 1
                input[17] = -1
                #expect(Fixtures.process(
                    &processor, frames: 2, input: input, output: &output, peaks: &peaks
                ) == .processed)
                let expected: [Float] = muted ? [1, -1, 0, 0, -1, 1] : [1, -1, 1, -1, -1, 1]
                #expect((0..<6).map { output[$0 * 16] } == expected)
                #expect(peaks == expected.map { abs($0) })
            }
        }
    }

    @Test func muteWithoutExternalOutputsStillStagesAndMaterializesAndRecovers() throws {
        for muted in [false, true] {
            var documents = Fixtures.muteDocuments(muted, inputMap: [[0], [1, 1]])
            documents.graph.nodes.removeAll { $0.kind == .roleOutput }
            documents.graph.edges.removeLast()
            var processor = try OfflineAudioRoutingProcessor(
                project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
            )
            var output: [Float] = []
            var peaks: [Float] = []
            var input = [Float](repeating: .nan, count: 32)
            #expect(Fixtures.process(
                &processor, frames: 0, input: input, output: &output, peaks: &peaks
            ) == .processed)
            for frames in [1, 16, 2, 16] {
                for bad in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
                    input = [Float](repeating: 1, count: 32)
                    input[16 + frames - 1] = bad
                    let refusal: AudioRoutingProcessRefusal = bad.isFinite ? .nonFiniteSum : .nonFiniteInput
                    #expect(Fixtures.process(
                        &processor, frames: frames, input: input, output: &output, peaks: &peaks
                    ) == .refused(refusal))
                    input[16 + frames - 1] = 1
                    #expect(Fixtures.process(
                        &processor, frames: frames, input: input, output: &output, peaks: &peaks
                    ) == .processed)
                }
            }
            documents.graph.nodes.removeAll { $0.kind == .roleInput }
            documents.graph.edges = []
            var disconnected = try OfflineAudioRoutingProcessor(
                project: documents.project, selectedGraph: documents.graph,
                limits: Fixtures.limits(inputs: 0, outputs: 0, terms: 0, scratch: 256, work: 128)
            )
            for frames in [0, 1, 16, 2, 16] {
                #expect(Fixtures.process(
                    &disconnected, frames: frames, input: [], output: &output, peaks: &peaks
                ) == .processed)
            }
        }
    }
}

extension RoutingBoundaryTests {
    @Test(arguments: [nil, false, true] as [Bool?])
    func invalidFramesAndExactCountFailuresTouchNothing(muted: Bool?) throws {
        let documents = muted.map { Fixtures.muteDocuments($0) } ?? Fixtures.documents()
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        let cases: [(frames: Int, counts: RoutingBufferCounts)] = [
            (-1, .init(inputs: 32, outputs: 32, peaks: 2)),
            (17, .init(inputs: 32, outputs: 32, peaks: 2)),
            (Int.max, .init(inputs: 32, outputs: 32, peaks: 2)),
            (Int.min, .init(inputs: 32, outputs: 32, peaks: 2)),
            (1, .init(inputs: 31, outputs: 32, peaks: 2)),
            (1, .init(inputs: 33, outputs: 32, peaks: 2)),
            (1, .init(inputs: 32, outputs: 31, peaks: 2)),
            (1, .init(inputs: 32, outputs: 33, peaks: 2)),
            (1, .init(inputs: 32, outputs: 32, peaks: 1)),
            (1, .init(inputs: 32, outputs: 32, peaks: 3)),
            (0, .init(inputs: 0, outputs: 32, peaks: 2)),
            (0, .init(inputs: 32, outputs: 0, peaks: 2)),
            (0, .init(inputs: 32, outputs: 32, peaks: 0))
        ]
        for item in cases {
            let input = [Float](repeating: .nan, count: item.counts.inputs)
            var output = [Float](repeating: -37, count: item.counts.outputs)
            var peaks = [Float](repeating: -41, count: item.counts.peaks)
            let error: AudioRoutingProcessRefusal = (0...16).contains(item.frames)
                ? .invalidBufferGeometry : .invalidFrames
            #expect(Fixtures.process(
                &processor, frames: item.frames, input: input, output: &output, peaks: &peaks
            ) == .refused(error))
            #expect(output.allSatisfy { $0 == -37 })
            #expect(peaks.allSatisfy { $0 == -41 })
            let inputIsNaN = input.allSatisfy(\.isNaN)
            #expect(inputIsNaN)
        }
        var output = [Float](repeating: -1, count: 32)
        var peaks: [Float] = [-1, -1]
        #expect(Fixtures.process(
            &processor, frames: 1, input: [Float](repeating: 3, count: 32), output: &output, peaks: &peaks
        ) == .processed)
        let expected: Float = muted == true ? 0 : 3
        #expect(output[0] == expected && output[16] == expected && peaks == [expected, expected])
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func zeroFramesSkipsNonfiniteAudioAndOnlyZerosPeaks(muted: Bool?) throws {
        let documents = muted.map { Fixtures.muteDocuments($0) } ?? Fixtures.documents()
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        let input = [Float](repeating: .nan, count: 32)
        var output = [Float](repeating: .nan, count: 32)
        let originalBits = output.map(\.bitPattern)
        var peaks: [Float] = [.infinity, .nan]
        #expect(Fixtures.process(&processor, frames: 0, input: input, output: &output, peaks: &peaks) == .processed)
        #expect(output.map(\.bitPattern) == originalBits)
        #expect(peaks == [0, 0])
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func fullAndPartialPairwiseOverlapIncludingPaddingTouchesNothing(muted: Bool?) throws {
        let documents = muted.map { Fixtures.muteDocuments($0) } ?? Fixtures.documents()
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        // All pointers refer to one live, correctly bound allocation. No forged
        // pointers, invalid lifetimes or misaligned typed-pointer fixtures.
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        storage.initialize(repeating: -73, count: 128)
        defer {
            storage.deinitialize(count: 128)
            storage.deallocate()
        }
        let cases: [(output: Int, peaks: Int)] = [
            (0, 96), (31, 96), (2, 96),
            (48, 0), (48, 31), (48, 2),
            (48, 48), (48, 79), (48, 50)
        ]
        for item in cases {
            for frames in [0, 1, 16] {
                let result = processor.process(
                    frames: frames,
                    input: UnsafeBufferPointer(start: storage, count: 32),
                    output: UnsafeMutableBufferPointer(start: storage.advanced(by: item.output), count: 32),
                    peaks: UnsafeMutableBufferPointer(start: storage.advanced(by: item.peaks), count: 2)
                )
                #expect(result == .refused(.overlappingStorage))
                #expect(UnsafeBufferPointer(start: storage, count: 128).allSatisfy { $0 == -73 })
            }
        }
        // Adjacent half-open slabs in the same allocation are valid, not overlaps.
        #expect(processor.process(
            frames: 1, input: UnsafeBufferPointer(start: storage, count: 32),
            output: UnsafeMutableBufferPointer(start: storage.advanced(by: 32), count: 32),
            peaks: UnsafeMutableBufferPointer(start: storage.advanced(by: 64), count: 2)
        ) == .processed)
        let expected: Float = muted == true ? 0 : -73
        #expect(storage[32] == expected && storage[48] == expected)
        #expect(storage[64] == abs(expected) && storage[65] == abs(expected))
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func activeNonfiniteEvenOnUnusedInputsSilencesAndRecovers(muted: Bool?) throws {
        var documents = muted.map { Fixtures.muteDocuments($0) } ?? Fixtures.documents()
        try Fixtures.appendEndpoint(to: &documents, input: true, suffix: "unused")
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        for bad in [Float.nan, .infinity, -.infinity] {
            for index in [0, 16, 32, 48] {
                var input = [Float](repeating: .nan, count: 64)
                for channel in 0..<4 {
                    input[channel * 16] = 3
                    input[channel * 16 + 1] = -2
                }
                input[index] = bad
                var output = [Float](repeating: .nan, count: 32)
                var peaks: [Float] = [19, 23]
                #expect(Fixtures.process(
                    &processor, frames: 2, input: input, output: &output, peaks: &peaks
                ) == .refused(.nonFiniteInput))
                expectSilenceWithNaNPadding(output, peaks: peaks)
                input[index] = 3
                #expect(Fixtures.process(
                    &processor, frames: 2, input: input, output: &output, peaks: &peaks
                ) == .processed)
                let expected: [Float] = muted == true ? [0, 0] : [3, -2]
                #expect(Array(output[0..<2]) == expected)
                #expect(Array(output[16..<18]) == expected)
                #expect(peaks == (muted == true ? [0, 0] : [3, 3]))
                let firstPaddingIsNaN = output[2..<16].allSatisfy(\.isNaN)
                let secondPaddingIsNaN = output[18..<32].allSatisfy(\.isNaN)
                #expect(firstPaddingIsNaN)
                #expect(secondPaddingIsNaN)
            }
        }
    }

    @Test func intermediateOverflowSilencesAllOutputsAndMetersBeforeRecovery() throws {
        let documents = Fixtures.documents(
            inputChannels: 3, map: [[2], [0, 1, 2]]
        )
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph, limits: Fixtures.limits()
        )
        for _ in 0..<5 {
            var input = [Float](repeating: .nan, count: 48)
            for frame in 0..<2 {
                input[frame] = .greatestFiniteMagnitude
                input[16 + frame] = .greatestFiniteMagnitude
                input[32 + frame] = -.greatestFiniteMagnitude
            }
            var output = [Float](repeating: .nan, count: 32)
            var peaks: [Float] = [99, 99]
            // First output finishes, and the second would be finite in wider
            // arithmetic. Its second Float32 addition must nevertheless refuse.
            #expect(Fixtures.process(
                &processor, frames: 2, input: input, output: &output, peaks: &peaks
            ) == .refused(.nonFiniteSum))
            expectSilenceWithNaNPadding(output, peaks: peaks)
            for channel in 0..<3 {
                input[channel * 16] = 1
                input[channel * 16 + 1] = -2
            }
            #expect(Fixtures.process(
                &processor, frames: 2, input: input, output: &output, peaks: &peaks
            ) == .processed)
            #expect(Array(output[0..<2]) == [1, -2])
            #expect(Array(output[16..<18]) == [3, -6])
            #expect(peaks == [2, 6])
            let firstPaddingIsNaN = output[2..<16].allSatisfy(\.isNaN)
            let secondPaddingIsNaN = output[18..<32].allSatisfy(\.isNaN)
            #expect(firstPaddingIsNaN)
            #expect(secondPaddingIsNaN)
        }
    }

    @Test func emptySlabsAreValidOnlyForAnEmptyLayout() throws {
        var documents = Fixtures.documents()
        documents.graph.nodes = []
        documents.graph.edges = []
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph,
            limits: Fixtures.limits(inputs: 0, outputs: 0, terms: 0, scratch: 4, work: 0)
        )
        for frames in [0, 1, 16] {
            #expect(processor.process(
                frames: frames, input: UnsafeBufferPointer(start: nil, count: 0),
                output: UnsafeMutableBufferPointer(start: nil, count: 0),
                peaks: UnsafeMutableBufferPointer(start: nil, count: 0)
            ) == .processed)
        }
    }

    private func expectSilenceWithNaNPadding(_ output: [Float], peaks: [Float]) {
        #expect(Array(output[0..<2]) == [0, 0])
        #expect(Array(output[16..<18]) == [0, 0])
        #expect(peaks == [0, 0])
        let firstPaddingIsNaN = output[2..<16].allSatisfy(\.isNaN)
        let secondPaddingIsNaN = output[18..<32].allSatisfy(\.isNaN)
        #expect(firstPaddingIsNaN)
        #expect(secondPaddingIsNaN)
    }
}
