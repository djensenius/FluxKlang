import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginHostNegotiationTests {
    @Test("negotiation capabilities accept frames 1 and 16384 and refuse 0 and 16385")
    func negotiationCapabilitiesFrameBoundaries() throws {
        #expect(try Self.makeCaps(frames: 1).maximumFramesToRender == 1)
        #expect(try Self.makeCaps(frames: 16_384).maximumFramesToRender == 16_384)
        for bad in [0, 16_385, Int.max] {
            #expect(throws: RenderSpecFault.invalidMaximumFrames(bad)) { try Self.makeCaps(frames: bad) }
        }
    }

    @Test("negotiation capabilities rates accept the range ends and refuse the offending value")
    func negotiationCapabilitiesRateBoundaries() throws {
        let ends = try Self.makeCaps(minRate: 8_000, maxRate: 384_000)
        #expect(ends.minimumSampleRateHz == 8_000)
        #expect(ends.maximumSampleRateHz == 384_000)
        #expect(try Self.makeCaps(minRate: 48_000, maxRate: 48_000).maximumSampleRateHz == 48_000)
        #expect(throws: RenderSpecFault.invalidSampleRate(7_999)) { try Self.makeCaps(minRate: 7_999) }
        #expect(throws: RenderSpecFault.invalidSampleRate(384_001)) { try Self.makeCaps(minRate: 384_001) }
        #expect(throws: RenderSpecFault.invalidSampleRate(384_001)) { try Self.makeCaps(maxRate: 384_001) }
        #expect(throws: RenderSpecFault.invalidSampleRate(7_999)) { try Self.makeCaps(maxRate: 7_999) }
    }

    @Test("negotiation capabilities refuse a minimum above the maximum and report the minimum")
    func negotiationCapabilitiesRateOrdering() throws {
        #expect(throws: RenderSpecFault.invalidSampleRate(48_001)) {
            try Self.makeCaps(minRate: 48_001, maxRate: 48_000)
        }
        // The minimum is range-checked before the maximum, and the range checks run before the ordering check.
        #expect(throws: RenderSpecFault.invalidSampleRate(7_999)) { try Self.makeCaps(minRate: 7_999, maxRate: 7_000) }
        #expect(throws: RenderSpecFault.invalidSampleRate(400_000)) {
            try Self.makeCaps(minRate: 400_000, maxRate: 500_000)
        }
    }

    @Test("negotiation capabilities refuse empty and duplicated formats")
    func negotiationCapabilitiesFormatList() throws {
        #expect(throws: RenderSpecFault.noSupportedFormat) { try Self.makeCaps(formats: []) }
        #expect(throws: RenderSpecFault.noSupportedFormat) { try Self.makeCaps(formats: [.float32, .float32]) }
        #expect(throws: RenderSpecFault.noSupportedFormat) {
            try Self.makeCaps(formats: [.float64, .float32, .float64])
        }
        #expect(try Self.makeCaps(formats: [.float64]).formats == [.float64])
    }

    @Test("negotiation capabilities store formats in declaration order and permutations compare equal")
    func negotiationCapabilitiesFormatsAreSorted() throws {
        let forward = try Self.makeCaps(formats: [.float32, .float64])
        let reversed = try Self.makeCaps(formats: [.float64, .float32])
        #expect(forward.formats == [.float32, .float64])
        #expect(reversed.formats == [.float32, .float64])
        #expect(forward == reversed)
        #expect(forward.hashValue == reversed.hashValue)
    }

    @Test("negotiation success records the proposal, generation and exact scratch bytes")
    func negotiationSuccessRecordsTheOutcome() throws {
        let proposal = try Self.makeSpec(
            frames: 512, format: .float32, inputs: Self.buses([2]), outputs: Self.buses([2]))
        let generation = try Self.makeGeneration(3, 5, 7)
        let result = try Self.negotiated(proposal, generation: generation)
        #expect(result.spec == proposal)
        #expect(result.generation == generation)
        #expect(result.requiredScratchBytes == 8_192)
    }

    @Test("negotiation frames equal to the plugin maximum pass and one more is refused")
    func negotiationFramesBoundary() throws {
        let capabilities = try Self.makeCaps(frames: 512)
        let layout = try Self.makeLayout()
        let accepted = try RenderResourceNegotiator.negotiate(
            Self.makeSpec(frames: 512), layout: layout, capabilities: capabilities, generation: .initial)
        #expect(accepted.spec.maximumFrames == 512)
        #expect(throws: NegotiationRefusal.framesExceedPlugin(requested: 513, supported: 512)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(frames: 513), layout: layout, capabilities: capabilities, generation: .initial)
        }
        #expect(throws: NegotiationRefusal.framesExceedPlugin(requested: 16_384, supported: 512)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(frames: 16_384), layout: layout, capabilities: capabilities, generation: .initial)
        }
    }

    @Test("negotiation refuses a format the plugin does not list")
    func negotiationUnsupportedFormat() throws {
        let capabilities = try Self.makeCaps(formats: [.float32])
        #expect(throws: NegotiationRefusal.formatUnsupported(.float64)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(format: .float64), layout: Self.makeLayout(), capabilities: capabilities,
                generation: .initial)
        }
        let float64Only = try Self.makeCaps(formats: [.float64])
        #expect(throws: NegotiationRefusal.formatUnsupported(.float32)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(format: .float32), layout: Self.makeLayout(), capabilities: float64Only,
                generation: .initial)
        }
    }

    @Test("negotiation sample rate at the plugin minimum and maximum passes, one outside is refused")
    func negotiationSampleRateBoundaries() throws {
        let capabilities = try Self.makeCaps(minRate: 44_100, maxRate: 96_000)
        let layout = try Self.makeLayout()
        for rate in [44_100, 48_000, 96_000] {
            let result = try RenderResourceNegotiator.negotiate(
                Self.makeSpec(rate: rate), layout: layout, capabilities: capabilities, generation: .initial)
            #expect(result.spec.sampleRateHz == rate)
        }
        for rate in [44_099, 96_001] {
            #expect(throws: NegotiationRefusal.sampleRateUnsupported(rateHz: rate)) {
                try RenderResourceNegotiator.negotiate(
                    Self.makeSpec(rate: rate), layout: layout, capabilities: capabilities, generation: .initial)
            }
        }
    }

    @Test("negotiation bus counts one fewer or one more than the layout are refused per direction")
    func negotiationBusCounts() throws {
        let layout = try Self.makeLayout(inputs: [2, 2], outputs: [2, 2])
        let caps = try Self.makeCaps()
        let two = try Self.buses([2, 2])
        for (inputs, outputs) in [([2], [2, 2]), ([2, 2, 2], [2, 2])] {
            let refusal = NegotiationRefusal.busCountMismatch(.input, requested: inputs.count, reported: 2)
            #expect(throws: refusal) {
                try RenderResourceNegotiator.negotiate(
                    Self.makeSpec(inputs: try Self.buses(inputs), outputs: try Self.buses(outputs)),
                    layout: layout, capabilities: caps, generation: .initial)
            }
        }
        for outputs in [[2], [2, 2, 2]] {
            let refusal = NegotiationRefusal.busCountMismatch(.output, requested: outputs.count, reported: 2)
            #expect(throws: refusal) {
                try RenderResourceNegotiator.negotiate(
                    Self.makeSpec(inputs: two, outputs: try Self.buses(outputs)),
                    layout: layout, capabilities: caps, generation: .initial)
            }
        }
        #expect(try RenderResourceNegotiator.negotiate(
            Self.makeSpec(inputs: two, outputs: two), layout: layout, capabilities: caps, generation: .initial)
            .spec.inputs.count == 2)
    }

    @Test("negotiation channel mismatch is reported at bus 0 and at the last bus index")
    func negotiationChannelMismatchIndices() throws {
        let layout = try Self.makeLayout(inputs: [1, 2, 6], outputs: [2, 4, 8])
        let caps = try Self.makeCaps()
        let first = NegotiationRefusal.channelMismatch(.input, bus: 0, requested: 2, reported: 1)
        #expect(throws: first) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([2, 2, 6]), outputs: try Self.buses([2, 4, 8])),
                layout: layout, capabilities: caps, generation: .initial)
        }
        let lastInput = NegotiationRefusal.channelMismatch(.input, bus: 2, requested: 5, reported: 6)
        #expect(throws: lastInput) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([1, 2, 5]), outputs: try Self.buses([2, 4, 8])),
                layout: layout, capabilities: caps, generation: .initial)
        }
        let lastOutput = NegotiationRefusal.channelMismatch(.output, bus: 2, requested: 7, reported: 8)
        #expect(throws: lastOutput) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([1, 2, 6]), outputs: try Self.buses([2, 4, 7])),
                layout: layout, capabilities: caps, generation: .initial)
        }
        let firstOutput = NegotiationRefusal.channelMismatch(.output, bus: 0, requested: 1, reported: 2)
        #expect(throws: firstOutput) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([1, 2, 6]), outputs: try Self.buses([1, 4, 8])),
                layout: layout, capabilities: caps, generation: .initial)
        }
    }

    @Test("negotiation disabled buses keep the reported channel count and a wrong count is still refused")
    func negotiationDisabledBusesAreStillChannelChecked() throws {
        let layout = try Self.makeLayout(inputs: [2, 4], outputs: [2, 6])
        let caps = try Self.makeCaps()
        let accepted = try RenderResourceNegotiator.negotiate(
            Self.makeSpec(inputs: Self.buses([2, 4], disabled: [1]), outputs: Self.buses([2, 6], disabled: [1])),
            layout: layout, capabilities: caps, generation: .initial)
        #expect(accepted.spec.enabledInputCount == 1)
        #expect(accepted.spec.enabledOutputCount == 1)
        let refusal = NegotiationRefusal.channelMismatch(.input, bus: 1, requested: 3, reported: 4)
        #expect(throws: refusal) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([2, 3], disabled: [1]), outputs: try Self.buses([2, 6])),
                layout: layout, capabilities: caps, generation: .initial)
        }
        let output = NegotiationRefusal.channelMismatch(.output, bus: 1, requested: 5, reported: 6)
        #expect(throws: output) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([2, 4]), outputs: try Self.buses([2, 5], disabled: [1])),
                layout: layout, capabilities: caps, generation: .initial)
        }
    }

    @Test("negotiation refuses an added bus and ignores the MIDI flags of the layout")
    func negotiationAddedBusAndMIDIFlags() throws {
        let caps = try Self.makeCaps()
        #expect(throws: NegotiationRefusal.busCountMismatch(.output, requested: 2, reported: 1)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(outputs: try Self.buses([2, 2])), layout: Self.makeLayout(), capabilities: caps,
                generation: .initial)
        }
        let withMIDI = try RenderResourceNegotiator.negotiate(
            Self.makeSpec(), layout: Self.makeLayout(midi: true), capabilities: caps, generation: .initial)
        let withoutMIDI = try RenderResourceNegotiator.negotiate(
            Self.makeSpec(), layout: Self.makeLayout(midi: false), capabilities: caps, generation: .initial)
        #expect(withMIDI == withoutMIDI)
    }

    @Test("negotiation precedence: format beats sample rate")
    func negotiationPrecedenceFormatBeatsRate() throws {
        let caps = try Self.makeCaps(minRate: 44_100, maxRate: 48_000, formats: [.float64])
        #expect(throws: NegotiationRefusal.formatUnsupported(.float32)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(rate: 96_000, format: .float32), layout: Self.makeLayout(), capabilities: caps,
                generation: .initial)
        }
    }

    @Test("negotiation precedence: sample rate beats frames")
    func negotiationPrecedenceRateBeatsFrames() throws {
        let caps = try Self.makeCaps(frames: 512, minRate: 44_100, maxRate: 48_000)
        #expect(throws: NegotiationRefusal.sampleRateUnsupported(rateHz: 96_000)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(rate: 96_000, frames: 513), layout: Self.makeLayout(), capabilities: caps,
                generation: .initial)
        }
    }

    @Test("negotiation precedence: frames beat the input bus count")
    func negotiationPrecedenceFramesBeatBusCount() throws {
        let caps = try Self.makeCaps(frames: 512)
        #expect(throws: NegotiationRefusal.framesExceedPlugin(requested: 513, supported: 512)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(frames: 513, inputs: try Self.buses([2, 2])), layout: Self.makeLayout(),
                capabilities: caps, generation: .initial)
        }
    }

    @Test("negotiation precedence: the input bus count beats the output bus count")
    func negotiationPrecedenceInputCountBeatsOutputCount() throws {
        #expect(throws: NegotiationRefusal.busCountMismatch(.input, requested: 2, reported: 1)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([2, 2]), outputs: try Self.buses([2, 2, 2])),
                layout: Self.makeLayout(), capabilities: Self.makeCaps(), generation: .initial)
        }
    }

    @Test("negotiation precedence: bus counts beat channel counts")
    func negotiationPrecedenceBusCountsBeatChannels() throws {
        #expect(throws: NegotiationRefusal.busCountMismatch(.output, requested: 2, reported: 1)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([3]), outputs: try Self.buses([2, 2])),
                layout: Self.makeLayout(), capabilities: Self.makeCaps(), generation: .initial)
        }
    }

    @Test("negotiation precedence: input channels beat output channels")
    func negotiationPrecedenceInputChannelsBeatOutputChannels() throws {
        #expect(throws: NegotiationRefusal.channelMismatch(.input, bus: 0, requested: 3, reported: 2)) {
            try RenderResourceNegotiator.negotiate(
                Self.makeSpec(inputs: try Self.buses([3]), outputs: try Self.buses([4])),
                layout: Self.makeLayout(), capabilities: Self.makeCaps(), generation: .initial)
        }
    }

    @Test("negotiation permutations of the reported formats give equal capabilities and equal results")
    func negotiationFormatPermutationsAreDeterministic() throws {
        let orders: [[RenderSampleFormat]] = [[.float32, .float64], [.float64, .float32]]
        var results: [NegotiatedRender] = []
        var capabilitiesSeen: [HostedRenderCapabilities] = []
        for order in orders {
            let caps = try Self.makeCaps(formats: order)
            capabilitiesSeen.append(caps)
            results.append(try RenderResourceNegotiator.negotiate(
                Self.makeSpec(format: .float64), layout: Self.makeLayout(), capabilities: caps,
                generation: .initial))
        }
        #expect(capabilitiesSeen.first == capabilitiesSeen.last)
        #expect(results.first == results.last)
        let again = try Self.negotiated(Self.makeSpec(format: .float64))
        #expect(try #require(results.first) == again)
    }

    @Test("negotiation refusals leave every input and an earlier result unchanged")
    func negotiationRefusalLeavesEverythingUnchanged() throws {
        let earlier = try Self.negotiated()
        let earlierCopy = earlier
        let proposal = try Self.makeSpec(frames: 2_048)
        let layout = try Self.makeLayout()
        let caps = try Self.makeCaps(frames: 1_024)
        let generation = try Self.makeGeneration(4, 4, 4)
        let proposalBefore = proposal
        let layoutBefore = layout
        let capsBefore = caps
        let generationBefore = generation
        #expect(throws: NegotiationRefusal.framesExceedPlugin(requested: 2_048, supported: 1_024)) {
            try RenderResourceNegotiator.negotiate(proposal, layout: layout, capabilities: caps, generation: generation)
        }
        #expect(proposalBefore == proposal)
        #expect(layoutBefore == layout)
        #expect(capsBefore == caps)
        #expect(generationBefore == generation)
        #expect(earlier == earlierCopy)
    }
}
