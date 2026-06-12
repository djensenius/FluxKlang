//
//  EffectRoutingTests.swift
//  FluxKlangTests
//

import Testing
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
}
