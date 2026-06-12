//
//  EnvironmentSpatialTests.swift
//  FluxKlangTests
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct EnvironmentSpatialTests {
    private let quad = SpeakerArray.standardQuad.speakers
    private let centre = CGPoint(x: 0.5, y: 0.5)

    // MARK: - SpatialRouting compilation

    @Test func monoSourceSendsToEverySpeakerBus() {
        let source = SpatialSource(name: "Mono", left: .channel(5), position: centre)
        let settings = SpatialRouting.settings(for: source, speakers: quad)

        // 4 speaker buses × (send-on + send-level).
        #expect(settings.count == 8)
        let onAddresses = settings.filter { $0.address.hasSuffix("/on") }.map(\.address)
        #expect(Set(onAddresses) == [
            "/ch/5/send/1/on", "/ch/5/send/2/on", "/ch/5/send/3/on", "/ch/5/send/4/on"
        ])
        #expect(settings.filter { $0.address.hasSuffix("/on") }.allSatisfy { $0.value == .int(1) })
    }

    @Test func centreOverSymmetricQuadIsAboutMinusSixDecibels() {
        let source = SpatialSource(name: "Mono", left: .channel(5), position: centre)
        let levels = SpatialRouting.settings(for: source, speakers: quad)
            .filter { $0.address.hasSuffix("/lvl") }
            .compactMap { $0.value.floatValue }
        #expect(levels.count == 4)
        for level in levels {
            #expect(abs(level + 6.02) < 0.1)
        }
    }

    @Test func stereoSourceDrivesBothChannels() {
        let source = SpatialSource(
            name: "Stereo", mode: .stereo,
            left: .channel(5), right: .channel(6),
            position: centre, width: 0.5
        )
        let settings = SpatialRouting.settings(for: source, speakers: quad)
        #expect(settings.count == 16)
        #expect(settings.contains { $0.address == "/ch/5/send/1/on" })
        #expect(settings.contains { $0.address == "/ch/6/send/4/on" })
    }

    @Test func noSpeakersYieldsNoSettings() {
        let source = SpatialSource(name: "Mono", left: .channel(5), position: centre)
        #expect(SpatialRouting.settings(for: source, speakers: []).isEmpty)
    }

    // MARK: - Voice → source

    @Test func sourceVoiceBuildsMonoSpatialSource() {
        let voice = EnvironmentVoice(
            id: "source:x", kind: .source, name: "Synth",
            sourceNames: ["Synth"], channels: [7], isStereo: false
        )
        let source = voice.spatialSource(position: centre, width: 0.5)
        #expect(source?.mode == .mono)
        #expect(source?.left == .channel(7))
        #expect(source?.right == nil)
    }

    @Test func stereoVoiceBuildsStereoSpatialSource() {
        let voice = EnvironmentVoice(
            id: "return:x", kind: .effectReturn, name: "Reverb",
            sourceNames: ["A", "B"], channels: [39, 40], isStereo: true
        )
        let source = voice.spatialSource(position: centre, width: 0.5)
        #expect(source?.mode == .stereo)
        #expect(source?.left == .channel(39))
        #expect(source?.right == .channel(40))
    }

    @Test func voiceWithoutChannelsHasNoSource() {
        let voice = EnvironmentVoice(
            id: "return:x", kind: .effectReturn, name: "Empty",
            sourceNames: [], channels: [], isStereo: false
        )
        #expect(voice.spatialSource(position: centre, width: 0.5) == nil)
    }

    // MARK: - Voice id helpers

    @Test func remapRewritesReturnIDsAndLeavesSourcesAlone() {
        let oldEffect = UUID()
        let newEffect = UUID()
        let equipment = UUID()
        let remap = [oldEffect: newEffect]
        #expect(EnvironmentVoice.remap(voiceID: "return:\(oldEffect.uuidString)", effects: remap)
            == "return:\(newEffect.uuidString)")
        #expect(EnvironmentVoice.remap(voiceID: "source:\(equipment.uuidString)", effects: remap)
            == "source:\(equipment.uuidString)")
        #expect(EnvironmentVoice.remap(voiceID: "return:\(UUID().uuidString)", effects: [:])
            .hasPrefix("return:"))
    }

    // MARK: - Environment placement persistence

    @Test func placementsSurviveACodableRoundTrip() throws {
        var environment = RoutingEnvironment(name: "Live")
        environment.placements["source:abc"] = VoicePlacement(position: CGPoint(x: 0.2, y: 0.8), width: 0.3)
        let data = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: data)
        #expect(decoded.placements["source:abc"]?.width == 0.3)
        #expect(decoded.placements["source:abc"]?.position == CGPoint(x: 0.2, y: 0.8))
    }

    @Test func graphSurvivesACodableRoundTrip() throws {
        var environment = RoutingEnvironment(name: "Live")
        let node = ChainNode(kind: .wingChannel(3), title: "Channel 3", position: CGPoint(x: 10, y: 20))
        environment.graph.addNode(node)
        let data = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: data)
        #expect(decoded.graph.nodes.count == 1)
        #expect(decoded.graph.node(node.id)?.title == "Channel 3")
        #expect(decoded.graph.node(node.id)?.position == CGPoint(x: 10, y: 20))
    }

    @Test func legacyEnvironmentWithoutPlacementsDecodes() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\"}"
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: Data(json.utf8))
        #expect(decoded.placements.isEmpty)
        #expect(decoded.effects.isEmpty)
        // Environments saved before the per-environment canvas decode with an
        // empty graph rather than failing.
        #expect(decoded.graph.nodes.isEmpty)
        #expect(decoded.graph.edges.isEmpty)
        #expect(decoded.name == "Old")
    }

    @Test func duplicatingRemapsReturnPlacementsAndKeepsSources() {
        let first = Effect(name: "Reverb")
        var second = Effect(name: "Delay")
        second.destinationEffectID = first.id
        var environment = RoutingEnvironment(name: "Song", effects: [first, second])
        let sourceKey = "source:\(UUID().uuidString)"
        environment.placements[sourceKey] = VoicePlacement(width: 0.1)
        environment.placements[EnvironmentVoice.returnID(first.id)] = VoicePlacement(width: 0.2)
        environment.placements[EnvironmentVoice.returnID(second.id)] = VoicePlacement(width: 0.3)

        let copy = environment.duplicated(named: "Song Copy")
        #expect(copy.placements.count == 3)
        #expect(copy.placements[sourceKey]?.width == 0.1)
        // The first/second placements follow their effects' new identities.
        #expect(copy.placements[EnvironmentVoice.returnID(copy.effects[0].id)]?.width == 0.2)
        #expect(copy.placements[EnvironmentVoice.returnID(copy.effects[1].id)]?.width == 0.3)
        // The original effect ids are gone.
        #expect(copy.placements[EnvironmentVoice.returnID(first.id)] == nil)
    }

    @Test func duplicatingCopiesTheCanvasGraph() {
        var environment = RoutingEnvironment(name: "Song")
        environment.graph.addNode(ChainNode(kind: .wingBus(2), title: "Bus 2", position: .zero))
        environment.graph.addNode(ChainNode(kind: .wingOutput(5), title: "Output 5", position: .zero))

        let copy = environment.duplicated(named: "Song Copy")
        #expect(copy.graph.nodes.count == 2)
        #expect(copy.graph.nodes.contains { $0.kind == .wingBus(2) })
        #expect(copy.graph.nodes.contains { $0.kind == .wingOutput(5) })
    }
}
