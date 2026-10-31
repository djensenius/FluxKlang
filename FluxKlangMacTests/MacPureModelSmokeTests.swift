//
//  MacPureModelSmokeTests.swift
//  FluxKlangMacTests
//
//  Native macOS smoke coverage for platform-neutral Shared models compiled
//  into the FluxKlangMac module. FluxKlangMac.app is the test host, so hosted
//  execution stays gated by #60 (startup isolation #51); build-for-testing only.
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlangMac

struct MacPureModelSmokeTests {
    @Test func faderMathKeepsUnityAndClampsOutOfRangeInputs() {
        #expect(FaderMath.position(fromDecibels: 0) == FaderMath.unityPosition)
        #expect(FaderMath.decibels(fromPosition: FaderMath.unityPosition) == 0)
        #expect(FaderMath.position(fromDecibels: 100) == 1)
        #expect(FaderMath.decibels(fromPosition: -1) == FaderMath.minimumDecibels)
    }

    @Test func spatialPannerGainsStayConstantPower() {
        let quad = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)
        ]
        let gains = SpatialPanner.gains(source: CGPoint(x: 0.2, y: 0.8), speakers: quad)
        let power = gains.reduce(0) { $0 + $1 * $1 }

        #expect(gains.count == quad.count)
        #expect(abs(power - 1) < 0.0001)
        #expect(SpatialPanner.decibels(forGain: 0) == SpatialPanner.silenceFloor)
    }

    @Test func studioGraphIgnoresDuplicateAndBackwardWires() {
        let synth = StudioNode(kind: .instrument(UUID()), title: "Synth")
        let endpoint = StudioNode(kind: .endpoint(UUID()), title: "Main")
        var graph = StudioGraph(nodes: [synth, endpoint])

        graph.connect(from: output(synth), to: input(endpoint))
        graph.connect(from: output(synth), to: input(endpoint))
        graph.connect(from: input(endpoint), to: output(synth))

        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.from.nodeID == synth.id)
        #expect(graph.edges.first?.to.nodeID == endpoint.id)
    }

    @Test func studioGraphRoundTripsThroughJSON() throws {
        let synth = StudioNode(kind: .instrument(UUID()), title: "Synth", position: CGPoint(x: 10, y: 20))
        let endpoint = StudioNode(kind: .endpoint(UUID()), title: "Main")
        var graph = StudioGraph(nodes: [synth, endpoint])
        graph.connect(from: output(synth), to: input(endpoint))

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(StudioGraph.self, from: data)

        #expect(decoded == graph)
    }

    @MainActor
    @Test func sharedTestSupportPollingCompletes() async throws {
        var polls = 0
        try await waitUntil(timeout: .milliseconds(500)) {
            polls += 1
            return polls >= 3
        }
        #expect(polls >= 3)
    }

    private func output(_ node: StudioNode) -> StudioPortRef {
        StudioPortRef(nodeID: node.id, side: .output, port: 0)
    }

    private func input(_ node: StudioNode) -> StudioPortRef {
        StudioPortRef(nodeID: node.id, side: .input, port: 0)
    }
}
