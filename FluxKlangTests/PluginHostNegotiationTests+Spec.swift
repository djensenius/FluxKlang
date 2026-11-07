import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginHostNegotiationTests {
    @Test("spec sample formats have exact cases, raw values and byte widths")
    func specSampleFormatCasesRawValuesAndByteWidths() {
        #expect(RenderSampleFormat.allCases == [.float32, .float64])
        #expect(RenderSampleFormat.allCases.map(\.rawValue) == ["float32", "float64"])
        #expect(RenderSampleFormat.allCases.map(\.bytesPerSample) == [4, 8])
    }

    @Test("spec bus channels accept 1 and 64 and refuse 0, 65 and -1")
    func specBusChannelsAcceptOneAndSixtyFourAndRefuseOutsideTheRange() throws {
        #expect(try RenderBusSpec(channels: 1).channels == 1)
        #expect(try RenderBusSpec(channels: 64).channels == 64)
        for bad in [0, 65, -1, Int.max, Int.min] {
            #expect(throws: RenderSpecFault.invalidChannelCount(bad)) { try RenderBusSpec(channels: bad) }
        }
        #expect(try RenderBusSpec(channels: 2).isEnabled)
        #expect(try !RenderBusSpec(channels: 2, isEnabled: false).isEnabled)
    }

    @Test("spec maximum frames accept 1 and 16384 and refuse 0 and 16385")
    func specMaximumFramesBoundaries() throws {
        #expect(try Self.makeSpec(frames: 1).maximumFrames == 1)
        #expect(try Self.makeSpec(frames: 16_384).maximumFrames == 16_384)
        for bad in [0, 16_385, -1] {
            #expect(throws: RenderSpecFault.invalidMaximumFrames(bad)) { try Self.makeSpec(frames: bad) }
        }
    }

    @Test("spec sample rate accepts 8000 and 384000 and refuses 7999 and 384001")
    func specSampleRateBoundaries() throws {
        #expect(try Self.makeSpec(rate: 8_000).sampleRateHz == 8_000)
        #expect(try Self.makeSpec(rate: 384_000).sampleRateHz == 384_000)
        #expect(try Self.makeSpec(rate: 44_100).sampleRateHz == 44_100)
        for bad in [7_999, 384_001, 0, -48_000] {
            #expect(throws: RenderSpecFault.invalidSampleRate(bad)) { try Self.makeSpec(rate: bad) }
        }
    }

    @Test("spec bus counts accept 64 and refuse 65 per direction and report the count")
    func specBusCountBoundaries() throws {
        let sixtyFour = try Self.buses(Array(repeating: 1, count: 64))
        let sixtyFive = try Self.buses(Array(repeating: 1, count: 65))
        #expect(try Self.makeSpec(frames: 64, inputs: sixtyFour, outputs: sixtyFour).inputs.count == 64)
        #expect(try Self.makeSpec(frames: 64, inputs: sixtyFour, outputs: sixtyFour).outputs.count == 64)
        #expect(throws: RenderSpecFault.tooManyBuses(.input, count: 65)) {
            try Self.makeSpec(inputs: sixtyFive, outputs: sixtyFour)
        }
        #expect(throws: RenderSpecFault.tooManyBuses(.output, count: 65)) {
            try Self.makeSpec(inputs: sixtyFour, outputs: sixtyFive)
        }
    }

    @Test("spec needs an enabled output bus but not an enabled input bus")
    func specNeedsAnEnabledOutputButNoInput() throws {
        #expect(throws: RenderSpecFault.noEnabledOutput) { try Self.makeSpec(outputs: []) }
        #expect(throws: RenderSpecFault.noEnabledOutput) {
            try Self.makeSpec(outputs: try Self.buses([2, 2], disabled: [0, 1]))
        }
        let instrument = try Self.makeSpec(inputs: [], outputs: try Self.buses([2, 2], disabled: [0]))
        #expect(instrument.inputs.isEmpty)
        #expect(instrument.enabledOutputCount == 1)
        let muted = try Self.makeSpec(inputs: try Self.buses([2], disabled: [0]))
        #expect(muted.enabledInputCount == 0)
    }

    @Test("spec scratch bytes follow the formula for three hand computed specs")
    func specScratchBytesFollowTheFormula() throws {
        let first = try Self.makeSpec(
            frames: 512, format: .float32, inputs: Self.buses([2]), outputs: Self.buses([2, 2]))
        #expect(first.requiredScratchBytes == 12_288)
        let second = try Self.makeSpec(
            frames: 1_024, format: .float64, inputs: Self.buses([2, 4]), outputs: Self.buses([6]))
        #expect(second.requiredScratchBytes == 98_304)
        let third = try Self.makeSpec(frames: 16_384, format: .float32, inputs: [], outputs: Self.buses([1]))
        #expect(third.requiredScratchBytes == 65_536)
        let layout = try Self.makeLayout(inputs: [2], outputs: [2, 2])
        let recorded = try RenderResourceNegotiator.negotiate(
            first, layout: layout, capabilities: Self.makeCaps(), generation: .initial)
        #expect(recorded.requiredScratchBytes == 12_288)
    }

    @Test("spec disabled buses contribute no scratch and enabled counts ignore them")
    func specDisabledBusesContributeNoScratch() throws {
        let spec = try Self.makeSpec(
            frames: 512, format: .float32,
            inputs: Self.buses([2, 4], disabled: [1]), outputs: Self.buses([2, 6], disabled: [1]))
        #expect(spec.requiredScratchBytes == 8_192)
        #expect(spec.enabledInputCount == 1)
        #expect(spec.enabledOutputCount == 1)
        let inputOnlyDisabled = try Self.makeSpec(
            frames: 512, inputs: Self.buses([4], disabled: [0]), outputs: Self.buses([2]))
        #expect(inputOnlyDisabled.requiredScratchBytes == 4_096)
    }

    @Test("spec scratch accepts the exact fit and refuses the next larger configuration")
    func specScratchExactFitAndNextLargerConfiguration() throws {
        let fourStereo = try Self.buses([64, 64, 64, 64])
        let exact = try Self.makeSpec(frames: 16_384, format: .float32, inputs: [], outputs: fourStereo)
        #expect(exact.requiredScratchBytes == 16_777_216)
        #expect(throws: RenderSpecFault.scratchTooLarge(requiredBytes: 16_842_752)) {
            try Self.makeSpec(frames: 16_384, format: .float32, inputs: try Self.buses([1]), outputs: fourStereo)
        }
        let fits = try Self.makeSpec(frames: 16_384, format: .float64, inputs: [], outputs: Self.buses([64, 64]))
        #expect(fits.requiredScratchBytes == 16_777_216)
        #expect(throws: RenderSpecFault.scratchTooLarge(requiredBytes: 25_165_824)) {
            try Self.makeSpec(frames: 16_384, format: .float64, inputs: [], outputs: try Self.buses([64, 64, 64]))
        }
    }

    @Test("spec worst case of 64 plus 64 buses of 64 channels is refused as too large")
    func specWorstCaseScratchIsRefused() throws {
        let full = try Self.buses(Array(repeating: 64, count: 64))
        #expect(throws: RenderSpecFault.scratchTooLarge(requiredBytes: 1_073_741_824)) {
            try Self.makeSpec(frames: 16_384, format: .float64, inputs: full, outputs: full)
        }
    }

    @Test("spec Int.max frames and rate are refused without trapping")
    func specIntMaxFramesAndRateAreRefused() throws {
        #expect(throws: RenderSpecFault.invalidMaximumFrames(Int.max)) { try Self.makeSpec(frames: Int.max) }
        #expect(throws: RenderSpecFault.invalidMaximumFrames(Int.min)) { try Self.makeSpec(frames: Int.min) }
        #expect(throws: RenderSpecFault.invalidSampleRate(Int.max)) { try Self.makeSpec(rate: Int.max) }
        #expect(throws: RenderSpecFault.invalidSampleRate(Int.min)) { try Self.makeSpec(rate: Int.min) }
    }

    @Test("spec precedence: invalid frames beat an invalid rate")
    func specPrecedenceFramesBeatRate() throws {
        #expect(throws: RenderSpecFault.invalidMaximumFrames(0)) { try Self.makeSpec(rate: 0, frames: 0) }
    }

    @Test("spec precedence: an invalid rate beats too many buses")
    func specPrecedenceRateBeatsBusCount() throws {
        let sixtyFive = try Self.buses(Array(repeating: 1, count: 65))
        #expect(throws: RenderSpecFault.invalidSampleRate(7_999)) {
            try Self.makeSpec(rate: 7_999, inputs: sixtyFive, outputs: sixtyFive)
        }
    }

    @Test("spec precedence: too many input buses beat too many output buses")
    func specPrecedenceInputsBeatOutputs() throws {
        let sixtyFive = try Self.buses(Array(repeating: 1, count: 65))
        let sixtySix = try Self.buses(Array(repeating: 1, count: 66))
        #expect(throws: RenderSpecFault.tooManyBuses(.input, count: 65)) {
            try Self.makeSpec(inputs: sixtyFive, outputs: sixtySix)
        }
        #expect(throws: RenderSpecFault.tooManyBuses(.output, count: 66)) {
            try Self.makeSpec(inputs: try Self.buses([2]), outputs: sixtySix)
        }
    }

    @Test("spec precedence: too many buses beat a missing enabled output")
    func specPrecedenceBusCountBeatsNoEnabledOutput() throws {
        let sixtyFiveDisabled = try Self.buses(Array(repeating: 1, count: 65), disabled: Array(0..<65))
        #expect(throws: RenderSpecFault.tooManyBuses(.output, count: 65)) {
            try Self.makeSpec(outputs: sixtyFiveDisabled)
        }
        let sixtyFiveInputs = try Self.buses(Array(repeating: 1, count: 65))
        #expect(throws: RenderSpecFault.tooManyBuses(.input, count: 65)) {
            try Self.makeSpec(inputs: sixtyFiveInputs, outputs: [])
        }
    }

    @Test("spec precedence: a missing enabled output beats an oversized scratch requirement")
    func specPrecedenceNoEnabledOutputBeatsScratch() throws {
        let heavy = try Self.buses(Array(repeating: 64, count: 64))
        let silent = try Self.buses([2], disabled: [0])
        #expect(throws: RenderSpecFault.noEnabledOutput) {
            try Self.makeSpec(frames: 16_384, format: .float64, inputs: heavy, outputs: silent)
        }
    }

    @Test("spec refusals leave the supplied bus arrays unchanged and valid specs equal")
    func specRefusalLeavesInputsUnchanged() throws {
        let inputs = try Self.buses([2, 4])
        let outputs = try Self.buses([2], disabled: [0])
        let inputsBefore = inputs
        let outputsBefore = outputs
        #expect(throws: RenderSpecFault.noEnabledOutput) { try Self.makeSpec(inputs: inputs, outputs: outputs) }
        #expect(inputs == inputsBefore)
        #expect(outputs == outputsBefore)
        #expect(try Self.makeSpec() == Self.makeSpec())
        #expect(try Self.makeSpec(frames: 256) != Self.makeSpec(frames: 512))
    }
}
