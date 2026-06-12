//
//  EnvironmentVoicesTests.swift
//  FluxKlangTests
//

import Testing
import Foundation
@testable import FluxKlang

@MainActor
struct EnvironmentVoicesTests {
    private let moog = Equipment(name: "Moog", isStereo: true)   // channels 1, 2
    private let juno = Equipment(name: "Juno", isStereo: true)   // channels 3, 4
    private let micro = Equipment(name: "Micro", isStereo: false) // channel 5

    private var assignments: [Equipment.ChannelAssignment] {
        Equipment.channelAssignments(from: [moog, juno, micro])
    }

    private func voices(_ effects: [Effect]) -> [EnvironmentVoice] {
        EnvironmentVoices.voices(for: RoutingEnvironment(name: "Test", effects: effects), assignments: assignments)
    }

    private func returns(_ voices: [EnvironmentVoice]) -> [EnvironmentVoice] {
        voices.filter { $0.kind == .effectReturn }
    }

    private func sources(_ voices: [EnvironmentVoice]) -> [EnvironmentVoice] {
        voices.filter { $0.kind == .source }
    }

    @Test func sharedEffectSumsItsSourcesIntoOneVoice() {
        let reverb = Effect(name: "Reverb", isStereo: true, sourceInstruments: [moog.id, juno.id])
        let result = voices([reverb])

        // Two dry sources plus one shared return.
        #expect(sources(result).map(\.name) == ["Moog", "Juno"])
        let wet = returns(result)
        #expect(wet.count == 1)
        #expect(wet[0].name == "Reverb")
        #expect(wet[0].isShared)
        #expect(wet[0].sourceNames == ["Juno", "Moog"])
        #expect(wet[0].channels == [40, 39])
    }

    @Test func parallelEffectsStayAsSeparateVoices() {
        let reverb = Effect(name: "Reverb", isStereo: true, sourceInstruments: [moog.id])
        let delay = Effect(name: "Delay", isStereo: true, sourceInstruments: [juno.id])
        let wet = returns(voices([reverb, delay]))

        #expect(wet.count == 2)
        #expect(wet.allSatisfy { !$0.isShared })
        #expect(wet.first { $0.name == "Reverb" }?.sourceNames == ["Moog"])
        #expect(wet.first { $0.name == "Delay" }?.sourceNames == ["Juno"])
    }

    @Test func serialChainFoldsUpstreamSourcesIntoFinalReturn() {
        let delay = Effect(name: "Delay", isStereo: true, sourceInstruments: [juno.id])
        let reverb = Effect(name: "Reverb", isStereo: true, sourceInstruments: [moog.id], destinationEffectID: delay.id)
        let wet = returns(voices([reverb, delay]))

        // Reverb folds into Delay, so only Delay's return is a voice, carrying both.
        #expect(wet.count == 1)
        #expect(wet[0].name == "Delay")
        #expect(wet[0].sourceNames == ["Juno", "Moog"])
        #expect(wet[0].channels == [38, 37])
    }

    @Test func cyclicChainBreaksToTwoIndependentReturns() {
        var reverb = Effect(name: "Reverb", isStereo: true, sourceInstruments: [moog.id])
        var delay = Effect(name: "Delay", isStereo: true, sourceInstruments: [juno.id])
        reverb.destinationEffectID = delay.id
        delay.destinationEffectID = reverb.id
        let wet = returns(voices([reverb, delay]))

        #expect(wet.count == 2)
        #expect(wet.allSatisfy { !$0.isShared })
        #expect(wet.first { $0.name == "Reverb" }?.sourceNames == ["Moog"])
        #expect(wet.first { $0.name == "Delay" }?.sourceNames == ["Juno"])
    }

    @Test func dryVoicesOnlyCoverInstrumentsInPlay() {
        // Only Moog feeds the effect; Juno and Micro are idle in this environment.
        let reverb = Effect(name: "Reverb", isStereo: true, sourceInstruments: [moog.id])
        let dry = sources(voices([reverb]))

        #expect(dry.map(\.name) == ["Moog"])
        #expect(dry[0].channels == [1, 2])
        #expect(dry[0].isStereo)
    }

    @Test func monoSourceAndReturnUseSingleChannels() {
        let delay = Effect(name: "Delay", isStereo: false, sourceInstruments: [micro.id])
        let result = voices([delay])

        let dry = sources(result)
        #expect(dry.map(\.name) == ["Micro"])
        #expect(dry[0].channels == [5])
        #expect(!dry[0].isStereo)

        let wet = returns(result)
        #expect(wet.count == 1)
        #expect(!wet[0].isStereo)
        #expect(wet[0].channels == [40])
    }

    @Test func emptyEnvironmentHasNoVoices() {
        #expect(voices([]).isEmpty)
    }
}
