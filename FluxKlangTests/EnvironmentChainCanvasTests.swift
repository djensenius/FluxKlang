//
//  EnvironmentChainCanvasTests.swift
//  FluxKlangTests
//
//  Pure tests for authoring an environment's effects on the chain canvas: which
//  dropped wire means "add a source", "chain into another effect", or "return to
//  Main", how deleting wires and nodes folds back into `[Effect]`, and how the
//  derived nodes/edges/ports are built. No stores, no disk — value types only.
//

import CoreGraphics
import Testing
@testable import FluxKlang

struct EnvironmentChainCanvasTests {
    private let synth = Equipment(name: "Synth", outputs: ["Out L", "Out R"], isStereo: true)
    private let drums = Equipment(name: "Drums", outputs: ["Out L", "Out R"], isStereo: true)

    private func effects() -> (reverb: Effect, delay: Effect) {
        (Effect(name: "Reverb"), Effect(name: "Delay"))
    }

    private func extract(_ outcome: EnvironmentChainCanvas.ConnectOutcome) -> [Effect]? {
        if case .effects(let updated) = outcome { return updated }
        return nil
    }

    // MARK: - Connect

    @Test func wiringInstrumentIntoEffectAddsASource() {
        let (reverb, _) = effects()
        let outcome = EnvironmentChainCanvas.connect(
            from: .effectSource(synth.id), to: .effect(reverb.id), effects: [reverb]
        )
        let updated = extract(outcome)
        #expect(updated?.first?.sourceInstruments == [synth.id])
    }

    @Test func wiringEffectIntoEffectFormsASerialChain() {
        let (reverb, delay) = effects()
        let outcome = EnvironmentChainCanvas.connect(
            from: .effect(reverb.id), to: .effect(delay.id), effects: [reverb, delay]
        )
        let updated = extract(outcome)
        #expect(updated?.first(where: { $0.id == reverb.id })?.destinationEffectID == delay.id)
    }

    @Test func wiringEffectIntoMainReturnsItInParallel() {
        var (reverb, delay) = effects()
        reverb.destinationEffectID = delay.id
        let outcome = EnvironmentChainCanvas.connect(
            from: .effect(reverb.id), to: .effectMain, effects: [reverb, delay]
        )
        let updated = extract(outcome)
        #expect(updated?.first(where: { $0.id == reverb.id })?.destinationEffectID == nil)
    }

    @Test func chainingAnEffectToItselfIsRejected() {
        let (reverb, _) = effects()
        let outcome = EnvironmentChainCanvas.connect(
            from: .effect(reverb.id), to: .effect(reverb.id), effects: [reverb]
        )
        #expect(outcome == .rejected)
    }

    @Test func chainingThatWouldFormACycleIsRejected() {
        var (reverb, delay) = effects()
        delay.destinationEffectID = reverb.id
        // reverb → delay would close the loop delay → reverb → delay.
        let outcome = EnvironmentChainCanvas.connect(
            from: .effect(reverb.id), to: .effect(delay.id), effects: [reverb, delay]
        )
        #expect(outcome == .rejected)
    }

    @Test func freeFormWiringIsLeftToThePatchbay() {
        let outcome = EnvironmentChainCanvas.connect(
            from: .wingChannel(1), to: .wingBus(1), effects: []
        )
        #expect(outcome == .notEffectEdge)
    }

    @Test func crossingTheEffectOverlayWithFreeFormIsRejected() {
        let (reverb, _) = effects()
        // Raw gear node into an effect, and an effect source into a raw channel.
        #expect(EnvironmentChainCanvas.connect(
            from: .equipment(synth.id), to: .effect(reverb.id), effects: [reverb]
        ) == .rejected)
        #expect(EnvironmentChainCanvas.connect(
            from: .effectSource(synth.id), to: .wingChannel(1), effects: [reverb]
        ) == .rejected)
    }

    @Test func wiringIntoAnInstrumentOrSourceToMainIsRejected() {
        let (reverb, _) = effects()
        #expect(EnvironmentChainCanvas.connect(
            from: .effect(reverb.id), to: .effectSource(synth.id), effects: [reverb]
        ) == .rejected)
        #expect(EnvironmentChainCanvas.connect(
            from: .effectSource(synth.id), to: .effectMain, effects: [reverb]
        ) == .rejected)
    }

    // MARK: - Disconnect

    @Test func deletingASourceWireDropsThatSource() {
        var (reverb, _) = effects()
        reverb.sourceInstruments = [synth.id, drums.id]
        let updated = EnvironmentChainCanvas.disconnect(
            .source(instrument: synth.id, effect: reverb.id), effects: [reverb]
        )
        #expect(updated.first?.sourceInstruments == [drums.id])
    }

    @Test func deletingAChainWireReturnsTheEffectToMain() {
        var (reverb, delay) = effects()
        reverb.destinationEffectID = delay.id
        let updated = EnvironmentChainCanvas.disconnect(
            .chain(from: reverb.id, to: delay.id), effects: [reverb, delay]
        )
        #expect(updated.first(where: { $0.id == reverb.id })?.destinationEffectID == nil)
    }

    @Test func theReturnToMainWireIsNotDeletable() {
        let (reverb, _) = effects()
        let updated = EnvironmentChainCanvas.disconnect(.toMain(effect: reverb.id), effects: [reverb])
        #expect(updated == [reverb])
    }

    // MARK: - Remove node

    @Test func removingAnEffectDropsItAndAnyChainPointingAtIt() {
        var (reverb, delay) = effects()
        delay.destinationEffectID = reverb.id
        let updated = EnvironmentChainCanvas.removeNode(.effect(reverb.id), effects: [reverb, delay])
        #expect(updated.count == 1)
        #expect(updated.first?.id == delay.id)
        #expect(updated.first?.destinationEffectID == nil)
    }

    @Test func removingAnInstrumentDropsItFromEveryEffect() {
        var (reverb, delay) = effects()
        reverb.sourceInstruments = [synth.id]
        delay.sourceInstruments = [synth.id, drums.id]
        let updated = EnvironmentChainCanvas.removeNode(.effectSource(synth.id), effects: [reverb, delay])
        #expect(updated.allSatisfy { !$0.sourceInstruments.contains(synth.id) })
        #expect(updated.first(where: { $0.id == delay.id })?.sourceInstruments == [drums.id])
    }

    @Test func removingMainDoesNothing() {
        let (reverb, delay) = effects()
        let updated = EnvironmentChainCanvas.removeNode(.effectMain, effects: [reverb, delay])
        #expect(updated == [reverb, delay])
    }

    // MARK: - Derived nodes

    @Test func nodesIncludeEachEffectItsSourcesAndOneMain() {
        var (reverb, delay) = effects()
        reverb.sourceInstruments = [synth.id]
        let nodes = EnvironmentChainCanvas.nodes(
            effects: [reverb, delay], layout: [:], equipment: [synth, drums]
        )
        let mains = nodes.filter { if case .effectMain = $0.kind { return true } else { return false } }
        let effectNodes = nodes.filter { if case .effect = $0.kind { return true } else { return false } }
        let sourceNodes = nodes.filter { if case .effectSource = $0.kind { return true } else { return false } }
        #expect(mains.count == 1)
        #expect(effectNodes.count == 2)
        #expect(sourceNodes.count == 1)
    }

    @Test func noMainNodeWhenThereAreNoEffects() {
        let nodes = EnvironmentChainCanvas.nodes(effects: [], layout: [:], equipment: [synth])
        #expect(nodes.isEmpty)
    }

    @Test func aSourceDroppedViaLayoutShowsEvenWhenUnwired() {
        let layout = [EnvironmentChainCanvas.sourceKey(synth.id): CGPoint(x: 10, y: 20)]
        let nodes = EnvironmentChainCanvas.nodes(effects: [], layout: layout, equipment: [synth])
        #expect(nodes.count == 1)
        #expect(nodes.first?.position == CGPoint(x: 10, y: 20))
        if case .effectSource(let id) = nodes.first?.kind {
            #expect(id == synth.id)
        } else {
            Issue.record("expected an effect-source node")
        }
    }

    // MARK: - Derived edges

    @Test func edgesWireSourcesInAndReturnsToMain() {
        var (reverb, _) = effects()
        reverb.sourceInstruments = [synth.id]
        let edges = EnvironmentChainCanvas.edges(effects: [reverb], layout: [:])
        #expect(edges.contains { $0.kind == .source(instrument: synth.id, effect: reverb.id) && $0.isDeletable })
        #expect(edges.contains { $0.kind == .toMain(effect: reverb.id) && !$0.isDeletable })
    }

    @Test func aChainedEffectWiresToItsTargetNotMain() {
        var (reverb, delay) = effects()
        reverb.destinationEffectID = delay.id
        let edges = EnvironmentChainCanvas.edges(effects: [reverb, delay], layout: [:])
        #expect(edges.contains { $0.kind == .chain(from: reverb.id, to: delay.id) })
        #expect(!edges.contains { $0.kind == .toMain(effect: reverb.id) })
        #expect(edges.contains { $0.kind == .toMain(effect: delay.id) })
    }

    // MARK: - Allocation-aware ports

    @Test func effectPortsShowItsBusAndReturnChannels() {
        let (reverb, _) = effects()
        let allocations = EffectRouting.allocations(for: [reverb])
        let allocation = allocations[reverb.id]
        let ports = EnvironmentChainCanvas.ports(
            for: .effect(reverb.id), effects: [reverb], allocations: allocations, assignments: []
        )
        let buses = (allocation?.buses ?? []).map(String.init).joined(separator: "/")
        let returns = (allocation?.returnChannels ?? []).map(String.init).joined(separator: "/")
        #expect(ports.inputs == ["Bus \(buses)"])
        #expect(ports.outputs == ["Rtn \(returns)"])
    }

    @Test func instrumentSourcePortsShowItsWingChannels() {
        let assignment = Equipment.ChannelAssignment(equipment: synth, leftChannel: 3, rightChannel: 4)
        let ports = EnvironmentChainCanvas.ports(
            for: .effectSource(synth.id), effects: [], allocations: [:], assignments: [assignment]
        )
        #expect(ports.outputs == ["Ch 3/4"])
        #expect(ports.inputs.isEmpty)
    }

    // MARK: - Duplication

    @Test func duplicatingAnEnvironmentRemapsEffectLayoutKeys() {
        var (reverb, _) = effects()
        reverb.sourceInstruments = [synth.id]
        let environment = RoutingEnvironment(
            name: "A",
            effects: [reverb],
            effectLayout: [
                EnvironmentChainCanvas.effectKey(reverb.id): CGPoint(x: 1, y: 2),
                EnvironmentChainCanvas.sourceKey(synth.id): CGPoint(x: 3, y: 4),
                EnvironmentChainCanvas.mainKey: CGPoint(x: 5, y: 6)
            ]
        )
        let copy = environment.duplicated(named: "B")
        let newEffectID = copy.effects[0].id
        #expect(newEffectID != reverb.id)
        // The effect-keyed entry follows the new id; source and Main keys persist.
        #expect(copy.effectLayout[EnvironmentChainCanvas.effectKey(newEffectID)] == CGPoint(x: 1, y: 2))
        #expect(copy.effectLayout[EnvironmentChainCanvas.effectKey(reverb.id)] == nil)
        #expect(copy.effectLayout[EnvironmentChainCanvas.sourceKey(synth.id)] == CGPoint(x: 3, y: 4))
        #expect(copy.effectLayout[EnvironmentChainCanvas.mainKey] == CGPoint(x: 5, y: 6))
    }
}
