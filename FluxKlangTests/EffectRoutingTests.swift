//
//  EffectRoutingTests.swift
//  FluxKlangTests
//

import Testing
import Foundation
@testable import FluxKlang

@MainActor
struct EffectRoutingTests {
    private let stereoInstrument = Equipment(name: "Synth A", isStereo: true)   // channels 1, 2
    private let monoInstrument = Equipment(name: "Synth B", isStereo: false)    // channel 3

    private var assignments: [Equipment.ChannelAssignment] {
        Equipment.channelAssignments(from: [stereoInstrument, monoInstrument])
    }

    private func value(_ settings: [WingSetting], _ address: String) -> WingValue? {
        settings.first { $0.address == address }?.value
    }

    @Test func allocatesBusesAndReturnsTopDownInOrder() {
        let stereo = Effect(name: "A", isStereo: true)
        let mono = Effect(name: "B", isStereo: false)
        let allocations = EffectRouting.allocations(for: [stereo, mono])
        #expect(allocations[stereo.id]?.buses == [16, 15])
        #expect(allocations[stereo.id]?.returnChannels == [40, 39])
        // The mono effect claims the next bus/return below the stereo pair.
        #expect(allocations[mono.id]?.buses == [14])
        #expect(allocations[mono.id]?.returnChannels == [38])
    }

    @Test func stereoEffectSendsInstrumentChannelsToBusPairAtUnity() {
        let effect = Effect(
            name: "Reverb",
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [3, 4],
            sourceInstruments: [stereoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        let unity = EffectRouting.unitySendDecibels
        #expect(value(settings, WingAddress.sendOn(.channel, 1, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.sendLevel(.channel, 1, toBus: 16)) == .float(unity))
        #expect(value(settings, WingAddress.sendOn(.channel, 2, toBus: 15)) == .int(1))
        #expect(value(settings, WingAddress.sendLevel(.channel, 2, toBus: 15)) == .float(unity))
    }

    @Test func stereoEffectPatchesBusesOntoSendOutputs() {
        let effect = Effect(
            name: "Reverb",
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [3, 4],
            sourceInstruments: [stereoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        #expect(value(settings, WingAddress.outputSourceGroup(1)) == .string("BUS"))
        #expect(value(settings, WingAddress.outputSourceIndex(1)) == .int(16))
        #expect(value(settings, WingAddress.outputSourceGroup(2)) == .string("BUS"))
        #expect(value(settings, WingAddress.outputSourceIndex(2)) == .int(15))
    }

    @Test func stereoEffectPatchesReturnsAndAssignsThemToMain() {
        let effect = Effect(
            name: "Reverb",
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [3, 4],
            sourceInstruments: [stereoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        // Return inputs 3/4 are patched onto return channels 40/39 (top-down).
        #expect(value(settings, WingAddress.channelSourceGroup(40)) == .string("LCL"))
        #expect(value(settings, WingAddress.channelSourceIndex(40)) == .int(3))
        #expect(value(settings, WingAddress.channelSourceGroup(39)) == .string("LCL"))
        #expect(value(settings, WingAddress.channelSourceIndex(39)) == .int(4))
        #expect(value(settings, WingAddress.mainOn(.channel, 40, toMain: 1)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 39, toMain: 1)) == .int(1))
    }

    @Test func monoEffectSumsAllSourceChannelsIntoSingleBus() {
        let effect = Effect(
            name: "Delay",
            isStereo: false,
            sendOutputs: [1],
            returnInputs: [1],
            sourceInstruments: [stereoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        // Both channels of the stereo instrument feed the one bus.
        #expect(value(settings, WingAddress.sendOn(.channel, 1, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 2, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.outputSourceGroup(1)) == .string("BUS"))
        #expect(value(settings, WingAddress.outputSourceIndex(1)) == .int(16))
        #expect(value(settings, WingAddress.channelSourceGroup(40)) == .string("LCL"))
        #expect(value(settings, WingAddress.channelSourceIndex(40)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 40, toMain: 1)) == .int(1))
    }

    @Test func monoInstrumentFeedsBothLegsOfStereoEffect() {
        let effect = Effect(
            name: "Reverb",
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [3, 4],
            sourceInstruments: [monoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        // The mono instrument lives on channel 3; it is centred to both buses.
        #expect(value(settings, WingAddress.sendOn(.channel, 3, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 3, toBus: 15)) == .int(1))
    }

    @Test func instrumentsNotInRigAreSkipped() {
        let ghost = Effect(
            name: "Reverb",
            isStereo: true,
            sourceInstruments: [Equipment(name: "Unknown").id]
        )
        let settings = EffectRouting.settings(for: [ghost], assignments: assignments)
        // No instrument resolves to a channel, so no sends are produced, but the
        // bus→output and return patches still set up the effect's plumbing.
        #expect(!settings.contains { $0.address.contains("/send/") })
        #expect(value(settings, WingAddress.outputSourceGroup(1)) == .string("BUS"))
    }

    @Test func emptyEffectListProducesNoSettings() {
        #expect(EffectRouting.settings(for: [], assignments: assignments).isEmpty)
    }

    @Test func overCapacityStereoEffectIsSkippedRatherThanHalfAllocated() {
        // Eight stereo effects exhaust all 16 buses; a ninth can't fit a full
        // pair, so it gets an empty allocation and produces no routing — rather
        // than collapsing both legs onto a single shared bus.
        var effects = (0..<8).map { Effect(name: "FX \($0)", isStereo: true) }
        let overflow = Effect(name: "Overflow", isStereo: true, sourceInstruments: [stereoInstrument.id])
        effects.append(overflow)

        let allocations = EffectRouting.allocations(for: effects)
        for effect in effects.prefix(8) {
            #expect(allocations[effect.id]?.buses.count == 2)
        }
        #expect(allocations[overflow.id]?.buses.isEmpty == true)

        // The overflow effect is the only one with a source, so if it were
        // (incorrectly) routed there would be sends; being skipped, there are none.
        let settings = EffectRouting.settings(for: effects, assignments: assignments)
        #expect(!settings.contains { $0.address.contains("/send/") })
    }

    @Test func serialChainFeedsReturnIntoDownstreamEffectBusNotMain() {
        let downstream = Effect(name: "Atrium", isStereo: true, sendOutputs: [3, 4], returnInputs: [5, 6])
        let upstream = Effect(
            name: "Evil Pet",
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [7, 8],
            sourceInstruments: [stereoInstrument.id],
            destinationEffectID: downstream.id
        )
        let settings = EffectRouting.settings(for: [upstream, downstream], assignments: assignments)
        // upstream: buses 16/15, returns 40/39. downstream: buses 14/13, returns 38/37.
        // The upstream effect's returns feed the downstream effect's buses (serial),
        // so they must NOT also be assigned to the main.
        #expect(value(settings, WingAddress.sendOn(.channel, 40, toBus: 14)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 39, toBus: 13)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 40, toMain: 1)) == nil)
        #expect(value(settings, WingAddress.mainOn(.channel, 39, toMain: 1)) == nil)
        // Only the terminal (downstream) effect returns to the main.
        #expect(value(settings, WingAddress.mainOn(.channel, 38, toMain: 1)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 37, toMain: 1)) == .int(1))
    }

    @Test func parallelEffectsEachReturnToMainIndependently() {
        let reverb = Effect(name: "Reverb", isStereo: true, sourceInstruments: [stereoInstrument.id])
        let delay = Effect(
            name: "Delay",
            isStereo: false,
            sendOutputs: [3],
            returnInputs: [5],
            sourceInstruments: [stereoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [reverb, delay], assignments: assignments)
        // reverb: buses 16/15, returns 40/39. delay: bus 14, return 38.
        #expect(value(settings, WingAddress.mainOn(.channel, 40, toMain: 1)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 39, toMain: 1)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 38, toMain: 1)) == .int(1))
        // The instrument feeds both effects in parallel.
        #expect(value(settings, WingAddress.sendOn(.channel, 1, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 1, toBus: 14)) == .int(1))
    }

    @Test func cyclicDestinationsFallBackToMainWithoutLooping() {
        let aID = UUID()
        let bID = UUID()
        let effectA = Effect(
            id: aID, name: "A", isStereo: false, sendOutputs: [1], returnInputs: [1], destinationEffectID: bID
        )
        let effectB = Effect(
            id: bID, name: "B", isStereo: false, sendOutputs: [2], returnInputs: [2], destinationEffectID: aID
        )
        let settings = EffectRouting.settings(for: [effectA, effectB], assignments: assignments)
        // A: bus 16, return 40. B: bus 15, return 39. The A->B->A cycle is broken:
        // both returns fall back to the main and neither is sent into the other's bus.
        #expect(value(settings, WingAddress.mainOn(.channel, 40, toMain: 1)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 39, toMain: 1)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 40, toBus: 15)) == nil)
        #expect(value(settings, WingAddress.sendOn(.channel, 39, toBus: 16)) == nil)
    }

    @Test func sharedEffectSumsEveryFeedingInstrumentIntoItsBus() {
        let effect = Effect(
            name: "Reverb",
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [3, 4],
            sourceInstruments: [stereoInstrument.id, monoInstrument.id]
        )
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        // Both instruments feed the one effect: its return is a single shared voice.
        #expect(value(settings, WingAddress.sendOn(.channel, 1, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 2, toBus: 15)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 3, toBus: 16)) == .int(1))
        #expect(value(settings, WingAddress.sendOn(.channel, 3, toBus: 15)) == .int(1))
        #expect(value(settings, WingAddress.mainOn(.channel, 40, toMain: 1)) == .int(1))
    }

    // MARK: - Jack normalization

    @Test func togglingMonoTopJackToStereoKeepsLegsDistinct() {
        // Mono effect parked on the top output (8), then switched to stereo: the
        // second leg must not also resolve to 8 (which would patch output 8 twice
        // and lose a bus leg).
        var effect = Effect(name: "X", isStereo: false, sendOutputs: [8], returnInputs: [24])
        effect.isStereo = true
        let normalized = effect.normalizingJacks()
        #expect(normalized.sendOutputs.count == 2)
        #expect(normalized.sendOutputs[0] != normalized.sendOutputs[1])
        #expect(normalized.returnInputs[0] != normalized.returnInputs[1])
        #expect(normalized.sendOutputs.allSatisfy { Effect.outputRange.contains($0) })
        #expect(normalized.returnInputs.allSatisfy { Effect.inputRange.contains($0) })
    }

    @Test func duplicateStereoJacksAreSeparated() {
        let effect = Effect(name: "Y", isStereo: true, sendOutputs: [5, 5], returnInputs: [3, 3])
        let normalized = effect.normalizingJacks()
        #expect(normalized.sendOutputs[0] != normalized.sendOutputs[1])
        #expect(normalized.returnInputs[0] != normalized.returnInputs[1])
    }

    @Test func outOfRangeJacksAreClampedToValidSockets() {
        let mono = Effect(name: "Z", isStereo: false, sendOutputs: [99], returnInputs: [0]).normalizingJacks()
        #expect(mono.sendOutputs == [8])    // clamped to the top output
        #expect(mono.returnInputs == [1])   // clamped to the first input
    }

    @Test func distinctSendOutputsPatchTwoSeparateOutputs() {
        // A stereo effect whose legs were both set to 8 still patches two outputs.
        let effect = Effect(
            name: "Reverb", isStereo: true, sendOutputs: [8, 8], returnInputs: [3, 4],
            sourceInstruments: [stereoInstrument.id]
        ).normalizingJacks()
        let settings = EffectRouting.settings(for: [effect], assignments: assignments)
        let patchedOutputs = effect.sendOutputs
        #expect(Set(patchedOutputs).count == 2)
        for output in patchedOutputs {
            #expect(value(settings, WingAddress.outputSourceGroup(output)) == .string("BUS"))
        }
    }
}
