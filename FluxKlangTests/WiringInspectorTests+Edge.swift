//
//  WiringInspectorTests+Edge.swift
//  FluxKlangTests
//
//  The facts of a selected edge (#101 WIN1): the state of each end (missing node, not routable, missing port,
//  connected), a repeated port ID, titles of the ends and the conversion and feedback flags.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

extension WiringInspectorTests {
    @Test func wiringInspectorReportsAnObservedShortcutEndAsNotRoutableEvenThoughItHasNoPortEither() throws {
        let shortcut = try Self.inspect(Self.node("nod.ch7"))
        #expect(shortcut.ports.isEmpty)
        let wire = Self.wire("edg.ch7-verb", from: ("nod.ch7", "out"), to: ("nod.verb", "in"))
        let inspector = try Self.inspect(Self.edge("edg.ch7-verb"), [.connect(wire)])
        let ends = [
            WiringInspectorEnd(
                node: Self.nodeID("nod.ch7"), port: Self.portID("out"), title: "nod.ch7", state: .notRoutable
            ),
            WiringInspectorEnd(
                node: Self.nodeID("nod.verb"), port: Self.portID("in"), title: "nod.verb",
                state: .connected(direction: .input, signal: .audio, channels: 2)
            )
        ]
        #expect(inspector.ends == ends)
        #expect(inspector.label == "nod.ch7 to nod.verb, draft, not active. 1 problem.")
    }

    @Test func wiringInspectorReportsAPortTheRoutableNodeDoesNotDeclareAsMissingPort() throws {
        let wire = Self.wire("edg.keys-nope", from: ("nod.keys", "nope"), to: ("nod.verb", "in"))
        let inspector = try Self.inspect(Self.edge("edg.keys-nope"), [.connect(wire)])
        let missing = WiringInspectorEnd(
            node: Self.nodeID("nod.keys"), port: Self.portID("nope"), title: "nod.keys", state: .missingPort
        )
        #expect(inspector.ends.first == missing)
        #expect(inspector.ends.count == 2)
        let problem = try #require(inspector.problems.first)
        #expect(problem.stableID == "missingPort|edg.keys-nope|nod.keys/nope")
        #expect(problem.sentence == "Wire edg.keys-nope: missing port nod.keys/nope.")
    }

    @Test func wiringInspectorReportsTheDirectionAndSignalOfEachEndOfAWireTheContractRejects() throws {
        let wire = Self.wire("edg.back", from: ("nod.verb", "mod"), to: ("nod.keys", "out"))
        let inspector = try Self.inspect(Self.edge("edg.back"), [.connect(wire)])
        let ends = [
            WiringInspectorEnd(
                node: Self.nodeID("nod.verb"), port: Self.portID("mod"), title: "nod.verb",
                state: .connected(direction: .input, signal: .control, channels: nil)
            ),
            WiringInspectorEnd(
                node: Self.nodeID("nod.keys"), port: Self.portID("out"), title: "nod.keys",
                state: .connected(direction: .output, signal: .audio, channels: 2)
            )
        ]
        #expect(inspector.ends == ends)
        #expect(inspector.problems.map(\.code) == ["wrongDirection"])
    }

    @Test func wiringInspectorResolvesARepeatedPortIDOfAnEndToItsFirstDeclaration() throws {
        let ports = [Fixture.audio("x", .input, 2), Fixture.audio("x", .output, 4)]
        let node = Fixture.node("nod.dup", ports: ports, at: 9)
        let wire = Self.wire("edg.keys-dup", from: ("nod.keys", "out"), to: ("nod.dup", "x"))
        let inspector = try Self.inspect(Self.edge("edg.keys-dup"), on: Fixture.with([wire], nodes: [node]))
        let last = try #require(inspector.ends.last)
        #expect(last.state == .connected(direction: .input, signal: .audio, channels: 2))
    }

    @Test func wiringInspectorShowsTheNodeLabelOfEachEndAndTheRawIDForAnEmptyLabel() throws {
        var graph = Fixture.graph
        graph.nodes[0].label = "Keys"
        graph.nodes[3].label = ""
        let inspector = try Self.inspect(Self.edge("edg.keys-verb"), on: graph)
        let titles = inspector.ends.map(\.title)
        #expect(titles == ["Keys", "nod.verb"])
        #expect(inspector.label == "Keys to nod.verb, active. No problems.")
    }

    @Test func wiringInspectorReportsTheConversionAndFeedbackFlagsOfAnEdgeAndNoNodeFacts() throws {
        let converted = try Self.inspect(Self.edge("edg.mic-verb"))
        #expect(converted.hasConversion)
        #expect(converted.feedbackCount == 0)
        let feedback = try Self.inspect(Self.edge("edg.delay-verb-fb"))
        #expect(feedback.hasConversion == false)
        #expect(feedback.feedbackCount == 1)
        let plain = try Self.inspect(Self.edge("edg.keys-verb"))
        #expect(plain.hasConversion == false)
        #expect(plain.feedbackCount == 0)
        #expect(plain.kind == nil)
        #expect(plain.ports.isEmpty)
        #expect(plain.attachedEdges.isEmpty)
        #expect(plain.title == "edg.keys-verb")
    }
}
