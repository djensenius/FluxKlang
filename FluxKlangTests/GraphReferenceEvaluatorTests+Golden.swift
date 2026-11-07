import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    private static let frames = 4

    private static func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0 + 1) }
    }

    /// Runs oracle and evaluator, asserts they agree, and returns the evaluator output or its block fault.
    private static func parity(
        _ documents: Documents, input: [Float], sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Result<[Float], ReferenceBlockFault> {
        let expected = try oracle(documents, frames: frames, input: input)
        let actual = try reference(documents, frames: frames, input: input)
        switch (expected.result, actual) {
        case (.processed, .success(let output)):
            #expect(bits(output) == bits(expected.output), sourceLocation: sourceLocation)
            return .success(output)
        case (.refused(let refusal), .failure(.blockFailed(let block, let fault))):
            #expect(block == 0, sourceLocation: sourceLocation)
            #expect(processorRefusal(for: fault) == refusal, sourceLocation: sourceLocation)
            return .failure(fault)
        case (.processed, .failure), (.refused, .success), (.refused, .failure):
            Issue.record("evaluator and offline processor disagree", sourceLocation: sourceLocation)
            return .failure(.blockCounterOverflow)
        }
    }

    private static func output(_ documents: Documents, _ input: [Float]) throws -> [Float] {
        switch try parity(documents, input: input) {
        case .success(let values): return values
        case .failure(let fault):
            Issue.record("unexpected fault \(fault)")
            return []
        }
    }

    @Test("GC3 identity and mapped direct edges match the offline processor and the literals")
    func referenceEvaluatorMatchesProcessorOnDirectMaps() throws {
        let eight = Self.ramp(8)
        #expect(try Self.output(AudioRoutingTestFixtures.documents(), eight) == eight)
        let one = AudioRoutingTestFixtures.documents(inputChannels: 1, outputChannels: 1, map: [[0]])
        #expect(try Self.output(one, [1, 2, 3, 4]) == [1, 2, 3, 4])
        let reversed = AudioRoutingTestFixtures.documents(map: [[1], [0]])
        #expect(try Self.output(reversed, eight) == [5, 6, 7, 8, 1, 2, 3, 4])
        let duplicate = AudioRoutingTestFixtures.documents(inputChannels: 1, outputChannels: 2, map: [[0], [0]])
        #expect(try Self.output(duplicate, [1, 2, 3, 4]) == [1, 2, 3, 4, 1, 2, 3, 4])
        let fanIn = AudioRoutingTestFixtures.documents(inputChannels: 2, outputChannels: 1, map: [[0, 1]])
        #expect(try Self.output(fanIn, eight) == [6, 8, 10, 12])
        let widen = AudioRoutingTestFixtures.documents(inputChannels: 2, outputChannels: 3, map: [[0], [1], [0, 1]])
        #expect(try Self.output(widen, eight) == [1, 2, 3, 4, 5, 6, 7, 8, 6, 8, 10, 12])
        let narrow = AudioRoutingTestFixtures.documents(inputChannels: 3, outputChannels: 2, map: [[0, 1], [2]])
        #expect(try Self.output(narrow, Self.ramp(12)) == [6, 8, 10, 12, 9, 10, 11, 12])
    }

    @Test("GC3 mute nodes of width one and sixty-four match the processor")
    func referenceEvaluatorMatchesProcessorOnMute() throws {
        for width in [1, 64] {
            let input = Self.ramp(width * 4).map { $0 - 3 }
            let muted = AudioRoutingTestFixtures.muteDocuments(true, channels: width)
            let silence = try Self.output(muted, input)
            #expect(Self.bits(silence) == [UInt32](repeating: 0, count: width * 4))
            let open = AudioRoutingTestFixtures.muteDocuments(false, channels: width)
            #expect(try Self.output(open, input) == input)
        }
    }

    @Test("GC3 maps on both sides of a mute sum in term order and match the processor")
    func referenceEvaluatorMatchesProcessorOnMapsAroundMute() throws {
        var input: [Float] = []
        for value: Float in [16_777_216, -16_777_216, 1] {
            input += [Float](repeating: value, count: 4)
        }
        let open = AudioRoutingTestFixtures.muteDocuments(
            false, channels: 1, inputChannels: 3, outputChannels: 2, inputMap: [[0, 2, 1]], outputMap: [[0], [0]]
        )
        #expect(try Self.output(open, input) == [0, 0, 0, 0, 0, 0, 0, 0])
        let natural = AudioRoutingTestFixtures.muteDocuments(
            false, channels: 1, inputChannels: 3, outputChannels: 2, inputMap: [[0, 1, 2]], outputMap: [[0], [0]]
        )
        #expect(try Self.output(natural, input) == [1, 1, 1, 1, 1, 1, 1, 1])
        let closed = AudioRoutingTestFixtures.muteDocuments(
            true, channels: 1, inputChannels: 3, outputChannels: 2, inputMap: [[0, 1, 2]], outputMap: [[0], [0]]
        )
        #expect(Self.bits(try Self.output(closed, input)) == [UInt32](repeating: 0, count: 8))
    }

    @Test("GC3 an extra disconnected output endpoint stays silent and matches the processor")
    func referenceEvaluatorMatchesProcessorOnDisconnectedOutput() throws {
        var documents = AudioRoutingTestFixtures.documents()
        try AudioRoutingTestFixtures.appendEndpoint(to: &documents, input: false, suffix: "spare", channels: 1)
        let output = try Self.output(documents, Self.ramp(8))
        #expect(output.count == 12)
        #expect(output.prefix(8).elementsEqual(Self.ramp(8)))
        #expect(Self.bits(Array(output.suffix(4))) == [0, 0, 0, 0])
    }

    @Test("GC3 non-finite input and non-finite sums are refused alike by both implementations")
    func referenceEvaluatorMatchesProcessorOnRefusals() throws {
        let direct = AudioRoutingTestFixtures.documents()
        var input = Self.ramp(8)
        input[6] = .nan
        let nonFinite = try Self.parity(direct, input: input)
        #expect(nonFinite == .failure(.nonFiniteInput(channel: 1, frame: 2)))
        let fanIn = AudioRoutingTestFixtures.documents(inputChannels: 2, outputChannels: 1, map: [[0, 1]])
        let big: Float = 3e38
        let overflow = try Self.parity(fanIn, input: [1, 1, big, 1, 1, 1, big, 1])
        let node = NodeID(validated: "node.output")
        #expect(overflow == .failure(.nonFiniteSum(node: node, channel: 0, frame: 2)))
        let muted = AudioRoutingTestFixtures.muteDocuments(
            true, channels: 1, inputChannels: 2, outputChannels: 1, inputMap: [[0, 1]]
        )
        let mutedOverflow = try Self.parity(muted, input: [1, 1, big, 1, 1, 1, big, 1])
        #expect(mutedOverflow == .failure(.nonFiniteSum(node: NodeID(validated: "node.mute"), channel: 0, frame: 2)))
    }
}
