//
//  WiringConnectionListTests.swift
//  FluxKlangTests
//
//  The compact Connections list (#101 WCL1): rows grouped by destination with the heading's channel or signal
//  text and presence suffix, the row text with its short conversion and feedback marker, the draft and will-remove
//  rows of a review, the empty state, the byte order of sections and rows, and the accessibility labels. The
//  refusals are in WiringConnectionListTests+Refusals.swift. The list is a pure value: nothing here reads a view,
//  a store, a device or a file.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct WiringConnectionListTests {
    @Test func wiringConnectionListHeadingsShowChannelsSignalAndPresenceSuffix() throws {
        let list = try WiringConnectionList.make(active: Fixture.graph(), review: nil, presence: Fixture.presence())
        #expect(list.sections.map(\.heading) == [
            "Cue (2ch) Unmapped", "Mains (2ch)", "Room Verb (2ch, control)", "Soft Synth (MIDI)",
            "Space (2ch) Lost/Muted", "Tape Echo (2ch) Missing"
        ])
        let cue = try #require(list.section(for: Fixture.node("cue")))
        let synth = try #require(list.section(for: Fixture.node("synth")))
        let echo = try #require(list.section(for: Fixture.node("echo")))
        let mains = try #require(list.section(for: Fixture.node("mains")))
        #expect(cue.title == "Cue")
        #expect(cue.signalText == "2ch")
        #expect(cue.stateSuffix == "Unmapped")
        #expect(synth.signalText == "MIDI")
        #expect(synth.stateSuffix == nil)
        #expect(echo.stateSuffix == "Missing")
        #expect(mains.stateSuffix == nil)
    }

    @Test func wiringConnectionListRowsShowRouteShortConversionAndFeedback() throws {
        let list = try WiringConnectionList.make(active: Fixture.graph(), review: nil, presence: Fixture.presence())
        #expect(list.sections.map { $0.rows.map(\.text) } == [
            [],
            ["Room Verb → Mains", "Vocal → Mains mono>both"],
            ["Keys → Room Verb", "Tape Echo → Room Verb"],
            ["Pads → Soft Synth"],
            ["Soft Synth → Space"],
            ["Keys → Tape Echo", "Room Verb → Tape Echo fb"]
        ])
        let mains = try #require(list.section(for: Fixture.node("mains")))
        try #require(mains.rows.count == 2)
        let vocal = mains.rows[1]
        #expect(vocal.edge == Fixture.edge("mic-mains"))
        #expect(vocal.sourceText == "Vocal")
        #expect(vocal.destinationText == "Mains")
        #expect(vocal.routeText == "Vocal → Mains")
        #expect(vocal.conversionText == "mono>both")
        #expect(vocal.conversionLabel == "Mono to both sides")
        #expect(vocal.feedbackText == nil)
        #expect(vocal.badge == .none)
        #expect(vocal.badge.text == nil)
        #expect(vocal.detailText == nil)
        let echo = try #require(list.section(for: Fixture.node("echo")))
        try #require(echo.rows.count == 2)
        #expect(echo.rows[1].feedbackText == "fb")
        #expect(echo.rows[1].conversionText == nil)
    }

    @Test func wiringConnectionListDraftAddedRowCarriesTheBadgeAndTheLongConversionLabel() throws {
        let active = Fixture.graph()
        let list = try WiringConnectionList.make(
            active: active, review: Fixture.review(active), presence: Fixture.presence()
        )
        let cue = try #require(list.section(for: Fixture.node("cue")))
        try #require(cue.rows.count == 1)
        let row = cue.rows[0]
        #expect(cue.heading == "Cue (2ch) Unmapped")
        #expect(cue.emptyText == nil)
        #expect(row.edge == Fixture.edge("mic-cue"))
        #expect(row.text == "Vocal → Cue")
        #expect(row.conversionText == "mono>both")
        #expect(row.badge == .draft)
        #expect(row.badge.text == "Draft")
        #expect(row.detailText == "Mono to both sides")
        #expect(!row.badge.isStruckThrough)
    }

    @Test func wiringConnectionListDraftRemovedRowIsStruckThroughWithWillRemove() throws {
        let active = Fixture.graph()
        let list = try WiringConnectionList.make(
            active: active, review: Fixture.review(active), presence: Fixture.presence()
        )
        let echo = try #require(list.section(for: Fixture.node("echo")))
        try #require(echo.rows.count == 2)
        let row = echo.rows[0]
        #expect(row.edge == Fixture.edge("keys-echo"))
        #expect(row.text == "Keys → Tape Echo")
        #expect(row.badge == .willRemove)
        #expect(row.badge.text == "Will remove")
        #expect(row.badge.isStruckThrough)
        #expect(row.detailText == nil)
        #expect(echo.rows[1].badge == .none)
    }

    @Test func wiringConnectionListDestinationWithoutConnectionsSaysNoConnections() throws {
        let list = try WiringConnectionList.make(active: Fixture.graph(), review: nil, presence: Fixture.presence())
        let cue = try #require(list.section(for: Fixture.node("cue")))
        let mains = try #require(list.section(for: Fixture.node("mains")))
        #expect(cue.rows.isEmpty)
        #expect(cue.emptyText == "No connections")
        #expect(mains.emptyText == nil)
    }

    @Test func wiringConnectionListGroupsEveryEdgeUnderItsDestinationOnly() throws {
        let graph = Fixture.graph()
        let list = try WiringConnectionList.make(active: graph, review: nil, presence: Fixture.presence())
        #expect(list.sections.map(\.node.rawValue) == [
            "nod.cue", "nod.mains", "nod.verb", "nod.synth", "nod.space", "nod.echo"
        ])
        let rows = list.sections.flatMap { section in section.rows.map { (section.node, $0.edge) } }
        try #require(rows.count == graph.edges.count)
        for (node, id) in rows {
            let edge = try #require(graph.edges.first { $0.id == id })
            #expect(edge.to.node == node)
        }
        #expect(list.section(for: Fixture.node("keys")) == nil)
        #expect(list.section(for: Fixture.node("ch7")) == nil)
    }

    @Test func wiringConnectionListOrdersSectionsAndRowsByUTF8Bytes() throws {
        let titles = ["Zed", "alpha", "\u{E9}cho", "e\u{301}cho", "", "Twin", "Twin"]
        let ids = ["n.zed", "n.alpha", "n.pre", "n.dec", "n.empty", "n.b", "n.a"]
        var graph = GraphDocument(id: GraphID(validated: "graph.order"))
        var presence: [NodeID: WiringNodePresence] = [:]
        for (title, raw) in zip(titles, ids) {
            let id = try NodeID(raw)
            graph.nodes.append(GraphNode(id: id, kind: .plugin, label: title, ports: [
                GraphPort(id: Fixture.port("in"), direction: .input, signal: .audio, channels: 2),
                GraphPort(id: Fixture.port("mod"), direction: .input, signal: .control),
                GraphPort(id: Fixture.port("out"), direction: .output, signal: .audio, channels: 2)
            ]))
            presence[id] = .ready
        }
        let sink = try NodeID("n.zed")
        for (source, raw) in [("n.pre", "e.2"), ("n.dec", "e.3"), ("n.a", "e.b"), ("n.a", "e.a"), ("n.alpha", "e.1")] {
            graph.edges.append(GraphEdge(
                id: try EdgeID(raw), from: PortAddress(node: try NodeID(source), port: Fixture.port("out")),
                to: PortAddress(node: sink, port: Fixture.port("in"))
            ))
        }
        let list = try WiringConnectionList.make(active: graph, review: nil, presence: presence)
        #expect(list.sections.map(\.node.rawValue) == ["n.a", "n.b", "n.zed", "n.alpha", "n.dec", "n.empty", "n.pre"])
        #expect(list.sections.map(\.title) == ["Twin", "Twin", "Zed", "alpha", "e\u{301}cho", "n.empty", "\u{E9}cho"])
        #expect(list.sections.allSatisfy { $0.signalText == "2ch, control" })
        let zed = try #require(list.section(for: sink))
        #expect(zed.rows.map(\.edge.rawValue) == ["e.a", "e.b", "e.1", "e.3", "e.2"])
    }

    @Test func wiringConnectionListAccessibilityLabelsSpeakEveryBadgeAndState() throws {
        let active = Fixture.graph()
        let list = try WiringConnectionList.make(
            active: active, review: Fixture.review(active), presence: Fixture.presence()
        )
        #expect(list.sections.map(\.accessibilityLabel) == [
            "Cue, 2 channels, Unmapped on this host, 1 connection.",
            "Mains, 2 channels, 2 connections.",
            "Room Verb, 2 channels, control, 2 connections.",
            "Soft Synth, MIDI, 1 connection.",
            "Space, 2 channels, Lost: outputs muted, 1 connection.",
            "Tape Echo, 2 channels, Missing plugin: branch silent, 2 connections."
        ])
        #expect(list.sections.flatMap { $0.rows.map(\.accessibilityLabel) } == [
            "Vocal to Cue, audio, mono to both sides, draft, not active.",
            "Room Verb to Mains, audio, 2 channels, active.",
            "Vocal to Mains, audio, mono to both sides, active.",
            "Keys to Room Verb, audio, 2 channels, active.",
            "Tape Echo to Room Verb, audio, 2 channels, active.",
            "Pads to Soft Synth, MIDI, active.",
            "Soft Synth to Space, audio, 2 channels, active.",
            "Keys to Tape Echo, audio, 2 channels, active, will remove.",
            "Room Verb to Tape Echo, audio, 2 channels, feedback, active."
        ])
        let empty = try WiringConnectionList.make(active: active, review: nil, presence: Fixture.presence())
        #expect(empty.sections.first?.accessibilityLabel == "Cue, 2 channels, Unmapped on this host, no connections.")
        #expect(WiringNodePresence.allCases.map(\.accessibilityText) == [
            nil, "Unmapped on this host", "Missing plugin: branch silent", "Lost: outputs muted"
        ])
        #expect(WiringConnectionBadge.allCases.map(\.accessibilityText) == [
            "active", "draft, not active", "active, will remove"
        ])
    }

    @Test func wiringConnectionListNamesOtherOffersAndCustomMaps() {
        let left = EdgeConversion(map: [[0], []])
        let sum = EdgeConversion(map: [[0, 1]])
        let custom = EdgeConversion(map: [[0], [0], [0]], label: "Edge label")
        #expect(WiringConnectionListText.conversion(left, sourceChannels: 1) == ("mono>left", "Left only"))
        #expect(WiringConnectionListText.conversion(sum, sourceChannels: 2) == ("both>mono", "Both sides summed"))
        #expect(WiringConnectionListText.conversion(custom, sourceChannels: 1) == ("map", "Custom channel map"))
        #expect(WiringConnectionListText.conversion(left, sourceChannels: nil) == ("map", "Custom channel map"))
    }

    @Test func wiringConnectionListReroutedEdgeIDListsTheOldRouteBeforeTheNewOne() throws {
        let active = Fixture.graph()
        let keys = GraphNode(id: Fixture.node("keys2"), kind: .roleInput, label: "Keys", ports: [
            GraphPort(id: Fixture.port("out"), direction: .output, signal: .audio, channels: 2)
        ])
        let rerouted = GraphEdge(id: Fixture.edge("keys-echo"), from: Fixture.out("keys2"), to: Fixture.input("echo"))
        let review = try Fixture.review(active, [.removeNode(Fixture.node("keys")), .addNode(keys), .connect(rerouted)])
        let list = try WiringConnectionList.make(active: active, review: review, presence: Fixture.presence())
        let echo = try #require(list.section(for: Fixture.node("echo")))
        let ids = [Fixture.edge("keys-echo"), Fixture.edge("keys-echo"), Fixture.edge("verb-echo-fb")]
        #expect(echo.rows.map(\.edge) == ids)
        #expect(echo.rows.map(\.badge) == [.willRemove, .draft, .none])
        #expect(echo.rows.map(\.text) == ["Keys → Tape Echo", "Keys → Tape Echo", "Room Verb → Tape Echo fb"])
    }

    @Test func wiringConnectionListListsADestinationThatOnlyTheDraftAdds() throws {
        let active = Fixture.graph()
        let monitor = GraphNode(id: Fixture.node("monitor"), kind: .roleOutput, label: "Monitor", ports: [
            GraphPort(id: Fixture.port("in"), direction: .input, signal: .audio, channels: 2)
        ])
        let review = try Fixture.review(active, [.addNode(monitor)])
        var presence = Fixture.presence()
        presence[monitor.id] = .unmapped
        let list = try WiringConnectionList.make(active: active, review: review, presence: presence)
        let section = try #require(list.section(for: monitor.id))
        #expect(section.heading == "Monitor (2ch) Unmapped")
        #expect(section.emptyText == "No connections")
    }

    @Test func wiringConnectionListListsAnEdgeIntoANodeWithoutInputs() throws {
        var graph = Fixture.graph()
        graph.edges.append(GraphEdge(id: Fixture.edge("mic-keys"), from: Fixture.out("mic"), to: Fixture.input("keys")))
        var presence = Fixture.presence()
        presence[Fixture.node("keys")] = .ready
        let list = try WiringConnectionList.make(active: graph, review: nil, presence: presence)
        let keys = try #require(list.section(for: Fixture.node("keys")))
        try #require(keys.rows.count == 1)
        #expect(keys.heading == "Keys (no inputs)")
        #expect(keys.rows[0].text == "Vocal → Keys")
        #expect(keys.rows[0].accessibilityLabel == "Vocal to Keys, audio, 1 channel, active.")
    }

    @Test func wiringTitleFallsBackToTheRawIDOnlyForAnEmptyLabel() {
        #expect(GraphNode(id: Fixture.node("blank"), kind: .plugin, label: "").wiringTitle == "nod.blank")
        #expect(GraphNode(id: Fixture.node("named"), kind: .plugin, label: "Echo").wiringTitle == "Echo")
        #expect(GraphNode(id: Fixture.node("space"), kind: .plugin, label: " ").wiringTitle == " ")
    }

    static func refusal(
        _ body: () throws(WiringConnectionListRefusal) -> WiringConnectionList
    ) -> WiringConnectionListRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }
}

extension WiringConnectionListTests {
    /// The phone-compact-routing.md example graph, with Space lost (as in wiring.md) to cover every suffix.
    enum Fixture {
        static func node(_ name: String) -> NodeID { id("nod.\(name)") }
        static func edge(_ name: String) -> EdgeID { id("edg.\(name)") }
        static func port(_ name: String) -> PortID { id(name) }

        /// A dynamic raw ID the fixtures know to be valid.
        static func id<Tag>(_ raw: String) -> ContractID<Tag> {
            guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("invalid fixture ID \(raw)") }
            return id
        }
        static func out(_ name: String) -> PortAddress { PortAddress(node: node(name), port: port("out")) }
        static func input(_ name: String) -> PortAddress { PortAddress(node: node(name), port: port("in")) }

        /// A node with at most one `in` and one `out` port; audio ports have 2 channels.
        static func spec(
            _ name: String, _ kind: NodeKind, _ label: String, input: PortSignal?, output: PortSignal?
        ) -> GraphNode {
            var ports: [GraphPort] = []
            for (id, direction, signal) in [("in", PortDirection.input, input), ("out", .output, output)] {
                guard let signal else { continue }
                ports.append(GraphPort(id: port(id), direction: direction, signal: signal, channels: channels(signal)))
            }
            return GraphNode(id: node(name), kind: kind, label: label, ports: ports)
        }

        static func graph() -> GraphDocument {
            let specs = [
                spec("keys", .roleInput, "Keys", input: nil, output: .audio),
                spec("mic", .roleInput, "Vocal", input: nil, output: .audio),
                spec("pads", .roleInput, "Pads", input: nil, output: .midi),
                spec("synth", .plugin, "Soft Synth", input: .midi, output: .audio),
                spec("verb", .plugin, "Room Verb", input: .audio, output: .audio),
                spec("echo", .plugin, "Tape Echo", input: .audio, output: .audio),
                spec("mains", .roleOutput, "Mains", input: .audio, output: nil),
                spec("space", .spatialBus, "Space", input: .audio, output: nil),
                spec("cue", .roleOutput, "Cue", input: .audio, output: nil),
                spec("ch7", .observedShortcut, "Console channel 7", input: nil, output: nil)
            ]
            var graph = GraphDocument(id: GraphID(validated: "graph.phone"), nodes: specs)
            if let mic = graph.nodes.firstIndex(where: { $0.id == node("mic") }) {
                graph.nodes[mic].ports[0].channels = 1
            }
            // examples/graph.json's `prt.verb.mod`: the heading lists every distinct input signal.
            if let verb = graph.nodes.firstIndex(where: { $0.id == node("verb") }) {
                graph.nodes[verb].ports.append(GraphPort(id: port("mod"), direction: .input, signal: .control))
            }
            let mono = EdgeConversion(map: [[0], [0]], label: "Mono to both sides")
            graph.edges = [
                GraphEdge(id: edge("keys-verb"), from: out("keys"), to: input("verb")),
                GraphEdge(id: edge("keys-echo"), from: out("keys"), to: input("echo")),
                GraphEdge(id: edge("echo-verb"), from: out("echo"), to: input("verb")),
                GraphEdge(id: edge("verb-echo-fb"), from: out("verb"), to: input("echo"),
                          feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)),
                GraphEdge(id: edge("verb-mains"), from: out("verb"), to: input("mains")),
                GraphEdge(id: edge("mic-mains"), from: out("mic"), to: input("mains"), conversion: mono),
                GraphEdge(id: edge("pads-synth"), from: out("pads"), to: input("synth")),
                GraphEdge(id: edge("synth-space"), from: out("synth"), to: input("space"))
            ]
            return graph
        }

        static func presence() -> [NodeID: WiringNodePresence] {
            [node("cue"): .unmapped, node("mains"): .ready, node("verb"): .ready, node("synth"): .ready,
             node("space"): .lost, node("echo"): .missing]
        }

        /// Adds Vocal → Cue with the picked "Mono to both sides" offer and removes Keys → Tape Echo.
        static func review(_ active: GraphDocument) throws -> WiringReviewDiff {
            let offers = try WiringConnectionOffers.conversions(sourceChannels: 1, destinationChannels: 2)
            let offer = try #require(offers.first)
            let added = GraphEdge(id: edge("mic-cue"), from: out("mic"), to: input("cue"), conversion: offer.conversion)
            return try review(active, [.connect(added), .disconnect(edge("keys-echo"))])
        }

        static func review(_ active: GraphDocument, _ edits: [GraphEdit]) throws -> WiringReviewDiff {
            let draft = DraftEdits(
                id: DraftID(validated: "dft.phone-cue"), graph: active.id, baseRevision: active.revision, edits: edits
            )
            return try WiringReviewDiff.make(active: active, draft: draft)
        }

        private static func channels(_ signal: PortSignal) -> Int? { signal == .audio ? 2 : nil }
    }
}
