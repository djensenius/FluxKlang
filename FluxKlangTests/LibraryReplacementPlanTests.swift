//
//  LibraryReplacementPlanTests.swift
//  FluxKlangTests
//
//  The Library "Replace with..." plan (#101 REP1): the edges kept and dropped, the reason and text of each drop,
//  the match rule (port ID, direction, signal and channels, never a title or a position), the graph edits that
//  carry the plan out, the byte order of the edges, the picker's compatibility rule and the fixed texts. The
//  refusals and the never-bypass proof are in LibraryReplacementPlanTests+Refusals.swift. The plan is a pure
//  value: nothing here reads a view, a store, a device or a file.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("Library replacement plan", .productionAccessAudit)
#else
@Suite("Library replacement plan")
#endif
struct LibraryReplacementPlanTests {
    @Test func theSameLayoutKeepsEveryEdgeThatTouchesTheNode() throws {
        let plan = try Fixture.plan(Fixture.spring())
        #expect(plan.replacedNode == Fixture.node("echo"))
        #expect(plan.keptEdges.map(\.rewritten.id.rawValue) == ["edg.echo-mains", "edg.echo-verb", "edg.keys-echo"])
        #expect(plan.droppedEdges.isEmpty)
        #expect(plan.reviewLines == ["Replace nod.echo with Spring Reverb: keeps 3 edges, drops 0."])
    }

    @Test func aKeptEdgeKeepsItsIDConversionAndExtensionsAndMovesOnlyTheOldEnd() throws {
        let plan = try Fixture.plan(Fixture.spring())
        let edges = Fixture.edges()
        try #require(plan.keptEdges.count == 3)
        let mains = plan.keptEdges[0]
        #expect(mains.original == edges[2])
        #expect(mains.rewritten.id == Fixture.edge("echo-mains"))
        #expect(mains.rewritten.from == Fixture.address("spring", "out"))
        #expect(mains.rewritten.to == Fixture.address("mains", "in"))
        #expect(mains.rewritten.conversion == EdgeConversion(map: [[0], [1]]))
        let verb = plan.keptEdges[1]
        #expect(verb.rewritten.from == Fixture.address("spring", "out"))
        #expect(verb.rewritten.to == Fixture.address("verb", "in"))
        #expect(verb.rewritten.extensions == ["note": .string("keep")])
        let keys = plan.keptEdges[2]
        #expect(keys.rewritten.from == Fixture.address("keys", "out"))
        #expect(keys.rewritten.to == Fixture.address("spring", "in"))
    }

    @Test func anEdgeNotTouchingTheNodeIsNeitherKeptNorDropped() throws {
        let plan = try Fixture.plan(Fixture.layout(ports: []))
        #expect(plan.keptEdges.isEmpty)
        #expect(plan.droppedEdges.map(\.edge.id.rawValue) == ["edg.echo-mains", "edg.echo-verb", "edg.keys-echo"])
        #expect(plan.graphEdits.count == 2)
        #expect(!plan.reviewLines.contains { $0.contains("edg.pads-verb") })
    }

    @Test func aMissingPortDropsItsEdgesWithTheFixedText() throws {
        let plan = try Fixture.plan(Fixture.layout(ports: [Fixture.lport("in", .input)]))
        #expect(plan.keptEdges.map(\.rewritten.id.rawValue) == ["edg.keys-echo"])
        #expect(plan.droppedEdges.map(\.edge.id.rawValue) == ["edg.echo-mains", "edg.echo-verb"])
        #expect(plan.droppedEdges.map(\.reason) == [.portMissing, .portMissing])
        #expect(plan.droppedEdges.map(\.text) == [
            "The replacement has no port out.", "The replacement has no port out."
        ])
        #expect(plan.droppedEdges.first?.edge == Fixture.edges()[2])
        #expect(plan.reviewLines == [
            "Replace nod.echo with Spring Reverb: keeps 1 edge, drops 2.",
            "Drops edg.echo-mains (nod.echo/out to nod.mains/in): The replacement has no port out.",
            "Drops edg.echo-verb (nod.echo/out to nod.verb/in): The replacement has no port out."
        ])
    }

    @Test func aChangedDirectionDropsTheEdge() throws {
        let layout = Fixture.layout(ports: [Fixture.lport("in", .output), Fixture.lport("out", .input)])
        let plan = try Fixture.plan(layout)
        #expect(plan.keptEdges.isEmpty)
        #expect(plan.droppedEdges.map(\.edge.id.rawValue) == ["edg.echo-mains", "edg.echo-verb", "edg.keys-echo"])
        #expect(plan.droppedEdges.map(\.reason) == Array(repeating: .directionChanged, count: 3))
        #expect(plan.droppedEdges.map(\.text) == [
            "Port out is an input on the replacement.", "Port out is an input on the replacement.",
            "Port in is an output on the replacement."
        ])
    }

    @Test func aChangedSignalDropsTheEdge() throws {
        let layout = Fixture.layout(ports: [Fixture.lport("in", .input), Fixture.lport("out", .output, .control, nil)])
        let plan = try Fixture.plan(layout)
        #expect(plan.keptEdges.map(\.rewritten.id.rawValue) == ["edg.keys-echo"])
        #expect(plan.droppedEdges.map(\.reason) == [.signalChanged, .signalChanged])
        #expect(plan.droppedEdges.map(\.text) == [
            "Port out carries control on the replacement, not audio.",
            "Port out carries control on the replacement, not audio."
        ])
    }

    @Test func aChangedChannelCountDropsTheEdge() throws {
        let cases: [(channels: Int?, text: String)] = [
            (1, "Port out has 1 channel on the replacement, not 2."),
            (4, "Port out has 4 channels on the replacement, not 2."),
            (nil, "Port out has no channel count on the replacement, not 2.")
        ]
        for item in cases {
            let layout = Fixture.layout(ports: [
                Fixture.lport("in", .input), Fixture.lport("out", .output, .audio, item.channels)
            ])
            let plan = try Fixture.plan(layout)
            #expect(plan.keptEdges.map(\.rewritten.id.rawValue) == ["edg.keys-echo"])
            #expect(plan.droppedEdges.map(\.reason) == [.channelsChanged, .channelsChanged])
            #expect(plan.droppedEdges.map(\.text) == [item.text, item.text])
        }
    }

    @Test func anUnsetOldChannelCountIsReadAsNoChannelCount() throws {
        let echo = Fixture.echo(ports: [Fixture.gport("in", .input), Fixture.gport("out", .output, .audio, nil)])
        let plan = try Fixture.plan(Fixture.spring(), in: Fixture.graph(nodes: [echo] + Fixture.nodes().dropFirst()))
        #expect(plan.droppedEdges.map(\.text) == [
            "Port out has 2 channels on the replacement, not no channel count.",
            "Port out has 2 channels on the replacement, not no channel count."
        ])
    }

    @Test func theFirstFailingCheckIsTheReasonGiven() throws {
        let directionAndSignal = Fixture.layout(ports: [
            Fixture.lport("in", .input), Fixture.lport("out", .input, .midi, nil)
        ])
        let first = try Fixture.plan(directionAndSignal)
        #expect(first.droppedEdges.map(\.reason) == [.directionChanged, .directionChanged])
        let signalAndChannels = Fixture.layout(ports: [
            Fixture.lport("in", .input), Fixture.lport("out", .output, .clock, nil)
        ])
        let second = try Fixture.plan(signalAndChannels)
        #expect(second.droppedEdges.map(\.reason) == [.signalChanged, .signalChanged])
        let missing = try Fixture.plan(Fixture.layout(ports: []))
        #expect(missing.droppedEdges.map(\.reason) == Array(repeating: .portMissing, count: 3))
    }

    @Test func aTitleOrAPositionNeverMakesAMatch() throws {
        let echo = Fixture.echo(
            ports: [Fixture.gport("in", .input), Fixture.gport("out", .output)], position: GraphPoint(x: 500, y: 500)
        )
        let graph = Fixture.graph(nodes: [echo] + Fixture.nodes().dropFirst())
        let relabelled = Fixture.layout("lay.other", "Something Else", ports: [
            Fixture.lport("in", .input, label: "Tape Echo In"), Fixture.lport("out", .output, label: "Tape Echo Out")
        ])
        let plan = try Fixture.plan(relabelled, in: graph)
        #expect(plan.keptEdges.count == 3)
        #expect(plan.replacementNode.label == "Something Else")
        #expect(plan.replacementNode.position == GraphPoint(x: 500, y: 500))
        #expect(plan.ports.map(\.label) == ["Tape Echo In", "Tape Echo Out"])
        let renamed = Fixture.layout(ports: [
            Fixture.lport("wet", .output, label: "out"), Fixture.lport("dry", .input, label: "in")
        ])
        #expect(try Fixture.plan(renamed).keptEdges.isEmpty)
    }

    @Test func aPortOnlyInTheReplacementIsListedButNeverWired() throws {
        let layout = Fixture.layout(ports: Fixture.stereoPorts() + [Fixture.lport("mod2", .input, .control, nil)])
        let plan = try Fixture.plan(layout)
        #expect(plan.ports.map(\.id.rawValue) == ["in", "out", "mod2"])
        #expect(plan.keptEdges.count == 3)
        for edit in plan.graphEdits {
            guard case .connect(let edge) = edit else { continue }
            #expect(edge.from.port != Fixture.port("mod2") && edge.to.port != Fixture.port("mod2"))
        }
    }

    @Test func aSelfLoopIsKeptOnlyWhenBothEndsMatch() throws {
        let loop = Fixture.wire("loop", from: ("echo", "out"), to: ("echo", "in"))
        let graph = Fixture.graph(edges: [loop])
        let kept = try Fixture.plan(Fixture.spring(), in: graph)
        try #require(kept.keptEdges.count == 1)
        #expect(kept.keptEdges[0].rewritten.from == Fixture.address("spring", "out"))
        #expect(kept.keptEdges[0].rewritten.to == Fixture.address("spring", "in"))
        let noIn = try Fixture.plan(Fixture.layout(ports: [Fixture.lport("out", .output)]), in: graph)
        #expect(noIn.keptEdges.isEmpty)
        #expect(noIn.droppedEdges.map(\.text) == ["The replacement has no port in."])
        let both = Fixture.layout(ports: [Fixture.lport("out", .output, .audio, 1), Fixture.lport("in", .output)])
        let first = try Fixture.plan(both, in: graph)
        #expect(first.droppedEdges.map(\.reason) == [.channelsChanged])
    }

    @Test func theEditsRemoveTheNodeAddTheReplacementAndConnectTheKeptEdges() throws {
        let graph = Fixture.graph()
        let plan = try Fixture.plan(Fixture.spring())
        try #require(plan.graphEdits.count == 5)
        #expect(plan.graphEdits[0] == .removeNode(Fixture.node("echo")))
        #expect(plan.graphEdits[1] == .addNode(plan.replacementNode))
        let connected = plan.graphEdits.dropFirst(2).compactMap { edit -> String? in
            guard case .connect(let edge) = edit else { return nil }
            return edge.id.rawValue
        }
        #expect(connected == ["edg.echo-mains", "edg.echo-verb", "edg.keys-echo"])
        try GraphEdit.validateBatch(plan.graphEdits)
        let applied = try graph.applying(plan.graphEdits)
        #expect(applied.node(Fixture.node("echo")) == nil)
        #expect(applied.edges.map(\.id.rawValue).sorted() == [
            "edg.echo-mains", "edg.echo-verb", "edg.keys-echo", "edg.pads-verb"
        ])
        let spring = try #require(applied.node(Fixture.node("spring")))
        #expect(spring.kind == .plugin)
        #expect(spring.label == "Spring Reverb")
        #expect(spring.position == GraphPoint(x: 10, y: 20))
        #expect(spring.ports == Fixture.stereoGraphPorts())
        #expect(spring.requiredCapabilities.isEmpty && spring.advisoryCapabilities.isEmpty)
    }

    @Test func planningIsDeterministicAndLeavesTheGraphAlone() throws {
        let graph = Fixture.graph()
        let plan = try Fixture.plan(Fixture.spring(), in: graph)
        #expect(try Fixture.plan(Fixture.spring(), in: graph) == plan)
        #expect(graph == Fixture.graph())
        let orders = Fixture.permutations(Fixture.edges())
        try #require(orders.count == 24)
        for order in orders {
            #expect(try Fixture.plan(Fixture.spring(), in: Fixture.graph(edges: order)) == plan)
        }
    }

    @Test func edgesAreOrderedByUTF8BytesOfTheirIDs() throws {
        let names = ["b", "B", "a", "9", "-"]
        let edges = names.map { Fixture.wire($0, from: ("keys", "out"), to: ("echo", "in")) }
        let plan = try Fixture.plan(Fixture.spring(), in: Fixture.graph(edges: edges))
        #expect(plan.keptEdges.map(\.rewritten.id.rawValue) == ["edg.-", "edg.9", "edg.B", "edg.a", "edg.b"])
        let none = try Fixture.plan(Fixture.layout(ports: []), in: Fixture.graph(edges: edges))
        #expect(none.droppedEdges.map(\.edge.id.rawValue) == ["edg.-", "edg.9", "edg.B", "edg.a", "edg.b"])
    }

    @Test func aLayoutIsCompatibleWhenAnEdgeIsKeptOrNoEdgeTouchesTheNode() throws {
        let node = Fixture.node("echo"), id = Fixture.node("spring"), graph = Fixture.graph()
        let aux = Fixture.layout(ports: [Fixture.lport("aux", .output, .control, nil)])
        let inOnly = Fixture.layout(ports: [Fixture.lport("in", .input)])
        #expect(try LibraryReplacementPlan.isCompatible(Fixture.spring(), replacing: node, as: id, in: graph))
        #expect(try LibraryReplacementPlan.isCompatible(inOnly, replacing: node, as: id, in: graph))
        #expect(try !LibraryReplacementPlan.isCompatible(aux, replacing: node, as: id, in: graph))
        let edgeless = Fixture.graph(edges: [])
        #expect(try LibraryReplacementPlan.isCompatible(aux, replacing: node, as: id, in: edgeless))
        let empty = Fixture.layout(ports: [])
        #expect(try LibraryReplacementPlan.isCompatible(empty, replacing: node, as: id, in: edgeless))
    }

    @Test func compatibleLayoutsAreOfferedInKeyByteOrder() throws {
        let aux = [Fixture.lport("aux", .output, .control, nil)]
        let layouts = [
            Fixture.layout("lay.b", "B", ports: Fixture.stereoPorts()),
            Fixture.layout("lay.x", "X", ports: aux),
            Fixture.layout("lay.a", "A", ports: [Fixture.lport("in", .input)]),
            Fixture.layout("lay.B", "Capital", ports: Fixture.stereoPorts())
        ]
        let offered = try LibraryReplacementPlan.compatibleLayouts(
            layouts, replacing: Fixture.node("echo"), as: Fixture.node("spring"), in: Fixture.graph()
        )
        #expect(offered.map(\.key) == ["lay.B", "lay.a", "lay.b"])
        #expect(offered.map(\.name) == ["Capital", "A", "B"])
    }

    @Test func layoutKeysAreOrderedByBytesAndEqualKeysKeepTheirOrder() throws {
        let precomposed = Fixture.layout("lay.\u{00E9}", "Pre", ports: Fixture.stereoPorts())
        let decomposed = Fixture.layout("lay.e\u{0301}", "Dec", ports: Fixture.stereoPorts())
        let first = Fixture.layout("lay.same", "First", ports: Fixture.stereoPorts())
        let second = Fixture.layout("lay.same", "Second", ports: Fixture.stereoPorts())
        func offered(_ input: [LibraryReplacementLayout]) throws -> [String] {
            try LibraryReplacementPlan.compatibleLayouts(
                input, replacing: Fixture.node("echo"), as: Fixture.node("spring"), in: Fixture.graph()
            ).map(\.name)
        }
        #expect(try offered([precomposed, decomposed]) == ["Dec", "Pre"])
        #expect(try offered([decomposed, precomposed]) == ["Dec", "Pre"])
        #expect(try offered([first, second]) == ["First", "Second"])
        #expect(try offered([second, first]) == ["Second", "First"])
    }

    @Test func anEdgeOnAPortTheNodeNeverDeclaredIsDroppedAsMissing() throws {
        let fromGhost = Fixture.wire("ghost-from", from: ("echo", "ghost"), to: ("verb", "in"))
        let toGhost = Fixture.wire("ghost-to", from: ("keys", "out"), to: ("echo", "ghost"))
        let plan = try Fixture.plan(Fixture.spring(), in: Fixture.graph(edges: [toGhost, fromGhost]))
        #expect(plan.keptEdges.isEmpty)
        #expect(plan.droppedEdges.map(\.edge.id.rawValue) == ["edg.ghost-from", "edg.ghost-to"])
        #expect(plan.droppedEdges.map(\.reason) == [.portMissing, .portMissing])
        #expect(plan.droppedEdges.map(\.text) == [
            "The replacement has no port ghost.", "The replacement has no port ghost."
        ])
    }

    @Test func theFixedTextsAreExact() {
        let node = Fixture.node("echo")
        #expect(LibraryReplacementText.summary(replacing: node, name: "Spring Reverb", kept: 2, dropped: 1)
            == "Replace nod.echo with Spring Reverb: keeps 2 edges, drops 1.")
        #expect(LibraryReplacementText.summary(replacing: node, name: "Spring Reverb", kept: 1, dropped: 2)
            == "Replace nod.echo with Spring Reverb: keeps 1 edge, drops 2.")
        #expect(LibraryReplacementText.summary(replacing: node, name: "X", kept: 0, dropped: 0)
            == "Replace nod.echo with X: keeps 0 edges, drops 0.")
        let drop = LibraryReplacementDrop(edge: Fixture.edges()[1], reason: .portMissing, text: "Some text.")
        #expect(LibraryReplacementText.dropLine(drop)
            == "Drops edg.echo-verb (nod.echo/out to nod.verb/in): Some text.")
        let out = Fixture.port("out")
        #expect(LibraryReplacementText.portMissing(out) == "The replacement has no port out.")
        #expect(LibraryReplacementText.directionChanged(out, now: .input) == "Port out is an input on the replacement.")
        #expect(LibraryReplacementText.directionChanged(out, now: .output)
            == "Port out is an output on the replacement.")
        #expect(LibraryReplacementText.signalChanged(out, now: .midi, was: .audio)
            == "Port out carries midi on the replacement, not audio.")
        #expect(LibraryReplacementText.channelsChanged(out, now: 1, was: 2)
            == "Port out has 1 channel on the replacement, not 2.")
        #expect(LibraryReplacementText.channelsChanged(out, now: 0, was: 2)
            == "Port out has 0 channels on the replacement, not 2.")
        #expect(LibraryReplacementDropReason.allCases == [
            .portMissing, .directionChanged, .signalChanged, .channelsChanged
        ])
    }
}
