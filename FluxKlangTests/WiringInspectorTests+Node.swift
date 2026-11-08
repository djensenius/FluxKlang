//
//  WiringInspectorTests+Node.swift
//  FluxKlangTests
//
//  The facts of a selected node (#101 WIN1): empty and self-looping nodes, duplicate port IDs, channel counts as
//  declared, verbatim titles, feedback counts and the order of the attached edges.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

extension WiringInspectorTests {
    @Test func wiringInspectorDescribesANodeWithNoPortsAndNoEdgesByEmptyListsAndZeroCounts() throws {
        let lonely = Fixture.node("nod.lonely", ports: [], at: 9)
        let inspector = try Self.inspect(Self.node("nod.lonely"), on: Fixture.with([], nodes: [lonely]))
        #expect(inspector.ports.isEmpty)
        #expect(inspector.attachedEdges.isEmpty)
        #expect(inspector.problems.isEmpty)
        #expect(inspector.feedbackCount == 0)
        #expect(inspector.hasConversion == false)
        let label = "nod.lonely, plugin, active. 0 inputs, 0 outputs. 0 connections, 0 feedback. No problems."
        #expect(inspector.label == label)
    }

    @Test func wiringInspectorListsASelfLoopingEdgeOnceForItsNode() throws {
        let looping = Fixture.stereo("nod.loop", at: 9)
        let loop = Fixture.edge(
            "edg.loop", Fixture.address("nod.loop", "out"), Fixture.address("nod.loop", "in"),
            feedback: Fixture.feedback
        )
        let graph = Fixture.with([loop], nodes: [looping])
        let inspector = try Self.inspect(Self.node("nod.loop"), on: graph)
        #expect(inspector.attachedEdges == [Self.edgeID("edg.loop")])
        #expect(inspector.feedbackCount == 1)
        #expect(inspector.problems.isEmpty)
        let label = "nod.loop, plugin, active. 1 input, 1 output. 1 connection, 1 feedback. No problems."
        #expect(inspector.label == label)
    }

    @Test func wiringInspectorKeepsBothPortsOfARepeatedPortIDInDeclarationOrderAndReportsTheRepeat() throws {
        let ports = [Fixture.audio("in", .input, 2), Fixture.audio("in", .output, 4)]
        let node = Fixture.node("nod.dup", ports: ports, at: 9)
        let inspector = try Self.inspect(Self.node("nod.dup"), on: Fixture.with([], nodes: [node]))
        let expected = [
            WiringInspectorPort(id: Self.portID("in"), direction: .input, signal: .audio, channels: 2),
            WiringInspectorPort(id: Self.portID("in"), direction: .output, signal: .audio, channels: 4)
        ]
        #expect(inspector.ports == expected)
        #expect(inspector.problems.count == 1)
        let problem = try #require(inspector.problems.first)
        #expect(problem.stableID == "duplicatePort|nod.dup|in")
        #expect(problem.sentence == "Node nod.dup: duplicate port in.")
        let label = "nod.dup, plugin, active. 1 input, 1 output. 0 connections, 0 feedback. 1 problem."
        #expect(inspector.label == label)
    }

    @Test func wiringInspectorShowsChannelCountsAsDeclaredInDeclarationOrderForNilZeroOne64And65AndMinusOne() throws {
        let control = GraphPort(id: Self.portID("zz"), direction: .input, signal: .control)
        let ports = [
            control, Fixture.audio("mm", .input, 0), Fixture.audio("cc", .input, 1),
            Fixture.audio("bb", .input, 64), Fixture.audio("aa", .input, 65), Fixture.audio("yy", .input, -1)
        ]
        let node = Fixture.node("nod.chan", ports: ports, at: 9)
        let inspector = try Self.inspect(Self.node("nod.chan"), on: Fixture.with([], nodes: [node]))
        let shown = inspector.ports.map(\.channels)
        let expected: [Int?] = [nil, 0, 1, 64, 65, -1]
        #expect(shown == expected)
        let identifiers = inspector.ports.map(\.id.rawValue)
        #expect(identifiers == ["zz", "mm", "cc", "bb", "aa", "yy"])
        let stable = inspector.problems.map(\.stableID)
        let listed = [
            "invalidChannelCount|nod.chan|aa", "invalidChannelCount|nod.chan|mm", "invalidChannelCount|nod.chan|yy"
        ]
        #expect(stable == listed)
        let label = "nod.chan, plugin, active. 6 inputs, 0 outputs. 0 connections, 0 feedback. 3 problems."
        #expect(inspector.label == label)
    }

    @Test func wiringInspectorShowsANodeLabelVerbatimAndFallsBackToTheIDOnlyForAnEmptyLabel() throws {
        var spaced = Fixture.node("nod.spaced", ports: [], at: 9)
        spaced.label = " Rev\n erb "
        var blank = Fixture.node("nod.blank", ports: [], at: 9)
        blank.label = " "
        var empty = Fixture.node("nod.empty", ports: [], at: 9)
        empty.label = ""
        let graph = Fixture.with([], nodes: [spaced, blank, empty])
        let spacedInspector = try Self.inspect(Self.node("nod.spaced"), on: graph)
        #expect(spacedInspector.title == " Rev\n erb ")
        let blanked = try Self.inspect(Self.node("nod.blank"), on: graph)
        #expect(blanked.title == " ")
        #expect(blanked.label == " , plugin, active. 0 inputs, 0 outputs. 0 connections, 0 feedback. No problems.")
        let emptied = try Self.inspect(Self.node("nod.empty"), on: graph)
        #expect(emptied.title == "nod.empty")
        let emptyLabel = "nod.empty, plugin, active. 0 inputs, 0 outputs. 0 connections, 0 feedback. No problems."
        #expect(emptied.label == emptyLabel)
    }

    @Test func wiringInspectorCountsOnlyTheAttachedEdgesThatCarryFeedbackAndNotAConversion() throws {
        let delay = try Self.inspect(Self.node("nod.delay"))
        #expect(delay.attachedEdges.count == 2)
        #expect(delay.feedbackCount == 1)
        let mic = try Self.inspect(Self.node("nod.mic"))
        #expect(mic.attachedEdges == [Self.edgeID("edg.mic-verb")])
        #expect(mic.feedbackCount == 0)
        #expect(mic.hasConversion == false)
        let mains = try Self.inspect(Self.node("nod.mains"))
        #expect(mains.feedbackCount == 0)
    }

    @Test func wiringInspectorOrdersAttachedEdgesAscendingByRawIDBytesWhateverTheGraphOrder() throws {
        let inputs = (1...5).map { Fixture.audio("i\($0)", .input, 2) }
        let hub = Fixture.node("nod.hub", ports: inputs, at: 9)
        let names = ["edg.a", "edg.1", "edg.B", "edg..a", "edg.-b"]
        var wires: [GraphEdge] = []
        for (index, name) in names.enumerated() {
            let from = Fixture.address("nod.keys", "out")
            wires.append(Fixture.edge(name, from, Fixture.address("nod.hub", "i\(index + 1)")))
        }
        let inspector = try Self.inspect(Self.node("nod.hub"), on: Fixture.with(wires, nodes: [hub]))
        let sorted = ["edg.-b", "edg..a", "edg.1", "edg.B", "edg.a"].map { Self.edgeID($0) }
        #expect(inspector.attachedEdges == sorted)
        #expect(inspector.problems.isEmpty)
    }
}
