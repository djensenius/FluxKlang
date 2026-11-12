//
//  WiringSourceListTests.swift
//  FluxKlangTests
//
//  The Add Connection "From" list (#101 WSRC1): outputs grouped by node, the observed shortcut listed as
//  "observed, not routable" and disabled, the next screen's `From:` text, the byte order of sections and rows,
//  the accessibility labels and the feed into the destination step. The refusals are in
//  WiringSourceListTests+Refusals.swift. The list is a pure value: nothing here reads a view, a store, a device
//  or a file.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("Wiring source list", .productionAccessAudit)
#else
@Suite("Wiring source list")
#endif
struct WiringSourceListTests {
    typealias Fixture = WiringSourceFixture

    @Test func sourceListShowsTheDocExampleGraphGroupedByNode() throws {
        let list = try WiringSourceList.make(in: Fixture.docGraph())
        #expect(list.sections.map(\.node.rawValue) == [
            "nod.keys", "nod.pads", "nod.verb", "nod.synth", "nod.echo", "nod.mic", "nod.ch7"
        ])
        #expect(list.sections.map(\.heading) == [
            "Keys (2ch)", "Pads (MIDI)", "Room Verb (2ch)", "Soft Synth (2ch)", "Tape Echo (2ch)", "Vocal (1ch)",
            "Console channel 7 (observed, not routable)"
        ])
        #expect(list.rows.map(\.fromText) == [
            "Keys (2ch audio)", "Pads (MIDI)", "Room Verb (2ch audio)", "Soft Synth (2ch audio)",
            "Tape Echo (2ch audio)", "Vocal (1ch audio)"
        ])
        #expect(list.rows.map(\.address) == [
            Fixture.address("keys", "out"), Fixture.address("pads", "out"), Fixture.address("verb", "out"),
            Fixture.address("synth", "out"), Fixture.address("echo", "out"), Fixture.address("mic", "out")
        ])
        #expect(list.sections.map(\.isEnabled) == [true, true, true, true, true, true, false])
        #expect(list.sections.map(\.stateText) == [nil, nil, nil, nil, nil, nil, "observed, not routable"])
        #expect(list.section(for: Fixture.node("mains")) == nil)
        #expect(list.section(for: Fixture.node("cue")) == nil)
        #expect(list.emptyText == nil)
    }

    @Test func sourceListNeverListsAnInputPort() throws {
        let rack = Fixture.node("rack", "Rack", ports: [
            Fixture.input("in"), Fixture.output("out"), Fixture.input("cv", .control)
        ])
        let sink = Fixture.node("sink", "Sink", ports: [Fixture.input("in"), Fixture.input("mod", .control)])
        let bare = Fixture.node("bare", "Bare", ports: [])
        let list = try WiringSourceList.make(in: Fixture.graph([rack, sink, bare]))
        #expect(list.sections.map(\.node.rawValue) == ["nod.rack"])
        #expect(list.rows.map(\.address) == [Fixture.address("rack", "out")])
        #expect(list.section(for: Fixture.node("sink")) == nil)
        #expect(list.section(for: Fixture.node("bare")) == nil)
        #expect(list.row(for: Fixture.address("rack", "in")) == nil)
    }

    @Test func sourceListOrdersASeveralOutputNodesRowsAndNamesThePort() throws {
        let rack = Fixture.node("rack", "Rack", ports: [
            Fixture.output("k", .clock, label: "4 clock"), Fixture.output("a", .audio, 2, label: "1 stereo"),
            Fixture.input("in"), Fixture.output("c", .control, label: "3 cc"),
            Fixture.output("m", .midi, label: "2 midi")
        ])
        let list = try WiringSourceList.make(in: Fixture.graph([rack]))
        let section = try #require(list.section(for: Fixture.node("rack")))
        #expect(section.rows.map(\.title) == ["1 stereo", "2 midi", "3 cc", "4 clock"])
        #expect(section.rows.map(\.address.port.rawValue) == ["a", "m", "c", "k"])
        #expect(section.rows.map(\.signalText) == ["2ch", "MIDI", "control", "clock"])
        #expect(section.signalText == "2ch, MIDI, control, clock")
        #expect(section.heading == "Rack (2ch, MIDI, control, clock)")
        #expect(section.rows.map(\.fromText) == [
            "Rack 1 stereo (2ch audio)", "Rack 2 midi (MIDI)", "Rack 3 cc (control)", "Rack 4 clock (clock)"
        ])
        #expect(list.rows == section.rows)
    }

    @Test func sourceListUsesLabelsVerbatimAndFallsBackToTheRawIDOnlyForAnEmptyOne() throws {
        let nodes = [
            Fixture.node("named", "Vocal", ports: [Fixture.output("out")]),
            Fixture.node("blank", "", ports: [Fixture.output("out")]),
            Fixture.node("space", " ", ports: [Fixture.output("out")])
        ]
        let list = try WiringSourceList.make(in: Fixture.graph(nodes))
        #expect(list.section(for: Fixture.node("named"))?.title == "Vocal")
        #expect(list.section(for: Fixture.node("blank"))?.title == "nod.blank")
        #expect(list.section(for: Fixture.node("space"))?.title == " ")
        #expect(list.section(for: Fixture.node("space"))?.heading == "  (audio)")
        #expect(list.section(for: Fixture.node("blank"))?.rows.map(\.fromText) == ["nod.blank (audio)"])
        let ports = Fixture.node("p", "P", ports: [
            Fixture.output("n"), Fixture.output("e", label: ""), Fixture.output("s", label: " "),
            Fixture.output("v", label: "Aux")
        ])
        let portList = try WiringSourceList.make(in: Fixture.graph([ports]))
        #expect(portList.row(for: Fixture.address("p", "n"))?.title == "n")
        #expect(portList.row(for: Fixture.address("p", "e"))?.title == "e")
        #expect(portList.row(for: Fixture.address("p", "s"))?.title == " ")
        #expect(portList.row(for: Fixture.address("p", "v"))?.title == "Aux")
        #expect(portList.rows.map(\.title) == [" ", "Aux", "e", "n"])
    }

    @Test func sourceListOrdersNodesByTitleBytesThenIDBytes() throws {
        // `é` and `e` + U+0301 are equal as Strings; by bytes `z` sorts between them.
        let labels = ["z", "alpha", "é", "Alpha", "A", "e\u{301}"]
        let out = [Fixture.output("out")]
        let nodes = labels.enumerated().map { Fixture.node("n\($0.offset)", $0.element, ports: out) }
        let list = try WiringSourceList.make(in: Fixture.graph(nodes))
        #expect(list.sections.map(\.title) == ["A", "Alpha", "alpha", "e\u{301}", "z", "é"])
        let tied = [
            Fixture.node("b", "Same", ports: out), Fixture.node("a", "Same", ports: out),
            Fixture.node("B", "Same", ports: out)
        ]
        let tiedList = try WiringSourceList.make(in: Fixture.graph(tied))
        #expect(tiedList.sections.map(\.node.rawValue) == ["nod.B", "nod.a", "nod.b"])
    }

    @Test func sourceListOrdersPortsByTitleBytesThenPortIDBytes() throws {
        let node = Fixture.node("p", "P", ports: [
            Fixture.output("z1", label: "b"), Fixture.output("a1", label: "é"), Fixture.output("m2", label: "Same"),
            Fixture.output("m1", label: "Same"), Fixture.output("q", label: "a"), Fixture.output("M", label: "Same")
        ])
        let list = try WiringSourceList.make(in: Fixture.graph([node]))
        #expect(list.rows.map(\.address.port.rawValue) == ["M", "m1", "m2", "q", "z1", "a1"])
    }

    @Test func sourceListIsTheSameFromEveryNodeAndPortOrder() throws {
        let ports = [Fixture.output("a", label: "Same"), Fixture.output("b", .midi, label: "Same"), Fixture.output("c")]
        let nodes = [
            Fixture.node("one", "One", ports: ports), Fixture.node("two", "Two", ports: [Fixture.output("out")]),
            Fixture.node("sc", "Console", kind: .observedShortcut, ports: [])
        ]
        let expected = try WiringSourceList.make(in: Fixture.graph(nodes))
        for order in Fixture.permutations(nodes) {
            let list = try WiringSourceList.make(in: Fixture.graph(order))
            #expect(list == expected)
        }
        for order in Fixture.permutations(ports) {
            var shuffled = nodes
            shuffled[0].ports = order
            let list = try WiringSourceList.make(in: Fixture.graph(shuffled))
            #expect(list == expected)
        }
        #expect(expected.sections.map(\.node.rawValue) == ["nod.one", "nod.two", "nod.sc"])
    }

    @Test func sourceListPutsShortcutsAfterRoutableNodesWhateverTheirTitles() throws {
        let nodes = [
            Fixture.node("s1", "AAA", kind: .observedShortcut, ports: []),
            Fixture.node("r1", "zzz", ports: [Fixture.output("out")]),
            Fixture.node("s2", "AAA", kind: .observedShortcut, ports: []),
            Fixture.node("r2", "Bbb", ports: [Fixture.output("out")])
        ]
        let list = try WiringSourceList.make(in: Fixture.graph(nodes))
        #expect(list.sections.map(\.node.rawValue) == ["nod.r2", "nod.r1", "nod.s1", "nod.s2"])
    }

    @Test func sourceListRowsFeedTheDestinationStep() throws {
        let graph = WiringPreviewFixture.graph
        let list = try WiringSourceList.make(in: graph)
        #expect(list.rows.map(\.address.node.rawValue) == ["nod.delay", "nod.echo", "nod.keys", "nod.mic", "nod.verb"])
        for row in list.rows {
            let destinations = try WiringDestinationList.make(from: row.address, in: graph)
            #expect(destinations.source == row.address)
        }
        #expect(list.rows.allSatisfy { $0.address.node.rawValue != "nod.ch7" })
        #expect(list.section(for: WiringPreviewFixture.id("nod.ch7"))?.rows.isEmpty == true)
    }

    @Test func sourceListShowsAnObservedShortcutDisabledWithoutRows() throws {
        let shortcut = Fixture.node("ch7", "Console channel 7", kind: .observedShortcut, ports: [])
        let declared = Fixture.node("ch8", "Console channel 8", kind: .observedShortcut, ports: [
            Fixture.output("out"), Fixture.input("in")
        ])
        let list = try WiringSourceList.make(in: Fixture.graph([declared, shortcut]))
        #expect(list.sections.map(\.node.rawValue) == ["nod.ch7", "nod.ch8"])
        for section in list.sections {
            #expect(section.rows.isEmpty)
            #expect(!section.isEnabled)
            #expect(section.stateText == "observed, not routable")
            #expect(section.signalText == nil)
        }
        let first = try #require(list.sections.first)
        #expect(first.heading == "Console channel 7 (observed, not routable)")
        #expect(first.accessibilityLabel == "Console channel 7, observed, not routable.")
        #expect(list.rows.isEmpty)
        #expect(list.row(for: Fixture.address("ch8", "out")) == nil)
    }

    @Test func sourceListPrintsEachSignalAndChannelCountAsDeclared() throws {
        struct Case {
            let port: GraphPort
            let signal: String
            let from: String
        }
        let cases = [
            Case(port: Fixture.output("out", .audio, 1), signal: "1ch", from: "1ch audio"),
            Case(port: Fixture.output("out", .audio, 2), signal: "2ch", from: "2ch audio"),
            Case(port: Fixture.output("out", .audio, 64), signal: "64ch", from: "64ch audio"),
            Case(port: Fixture.output("out", .audio), signal: "audio", from: "audio"),
            Case(port: Fixture.output("out", .midi), signal: "MIDI", from: "MIDI"),
            Case(port: Fixture.output("out", .control), signal: "control", from: "control"),
            Case(port: Fixture.output("out", .clock), signal: "clock", from: "clock"),
            Case(port: Fixture.output("out", .audio, 0), signal: "0ch", from: "0ch audio"),
            Case(port: Fixture.output("out", .audio, 65), signal: "65ch", from: "65ch audio")
        ]
        for item in cases {
            let list = try WiringSourceList.make(in: Fixture.graph([Fixture.node("n", "N", ports: [item.port])]))
            let row = try #require(list.rows.first)
            #expect(row.signalText == item.signal)
            #expect(row.fromText == "N (\(item.from))")
            #expect(list.sections.first?.signalText == item.signal)
        }
    }

    @Test func sourceListAccessibilityLabelsSpeakTheSignalAndCounts() throws {
        func pair(_ first: GraphPort, _ second: GraphPort) -> [GraphPort] { [first, second] }
        let list = try WiringSourceList.make(in: Fixture.graph([
            Fixture.node("one", "Vocal", ports: [Fixture.output("out", .audio, 1)]),
            Fixture.node("two", "Rack", ports: pair(
                Fixture.output("a", .audio, 2, label: "A"), Fixture.output("b", .midi, label: "B")
            )),
            Fixture.node("mix", "Mix", ports: pair(
                Fixture.output("a", .audio, 1, label: "A"), Fixture.output("b", .audio, 2, label: "B")
            )),
            Fixture.node("same", "Same", ports: pair(
                Fixture.output("a", .audio, 2, label: "A"), Fixture.output("b", .audio, 2, label: "B")
            )),
            Fixture.node("bare", "Bare", ports: [Fixture.output("out", .audio)]),
            Fixture.node("cc", "Cc", ports: [Fixture.output("out", .control)]),
            Fixture.node("clk", "Clk", ports: [Fixture.output("out", .clock)]),
            Fixture.node("sc", "Console channel 7", kind: .observedShortcut, ports: [])
        ]))
        func label(_ name: String) -> String? { list.section(for: Fixture.node(name))?.accessibilityLabel }
        #expect(label("one") == "Vocal, 1 channel, 1 output.")
        #expect(label("two") == "Rack, 2 channels, MIDI, 2 outputs.")
        #expect(label("mix") == "Mix, 1 channel, 2 channels, 2 outputs.")
        #expect(label("same") == "Same, 2 channels, 2 outputs.")
        #expect(label("bare") == "Bare, audio, 1 output.")
        #expect(label("cc") == "Cc, control, 1 output.")
        #expect(label("clk") == "Clk, clock, 1 output.")
        #expect(label("sc") == "Console channel 7, observed, not routable.")
        #expect(list.row(for: Fixture.address("one", "out"))?.accessibilityLabel == "Vocal, out, audio, 1 channel.")
        #expect(list.row(for: Fixture.address("two", "a"))?.accessibilityLabel == "Rack, A, audio, 2 channels.")
        #expect(list.row(for: Fixture.address("two", "b"))?.accessibilityLabel == "Rack, B, MIDI.")
        #expect(list.row(for: Fixture.address("bare", "out"))?.accessibilityLabel == "Bare, out, audio.")
        #expect(list.row(for: Fixture.address("cc", "out"))?.accessibilityLabel == "Cc, out, control.")
        #expect(list.row(for: Fixture.address("clk", "out"))?.accessibilityLabel == "Clk, out, clock.")
    }

    @Test func sourceListSaysNoOutputsOnlyWhenNoSectionHasARow() throws {
        let sink = Fixture.node("sink", "Sink", ports: [Fixture.input("in")])
        let shortcut = Fixture.node("ch7", "Console channel 7", kind: .observedShortcut, ports: [])
        let empty = try WiringSourceList.make(in: Fixture.graph([]))
        #expect(empty.sections.isEmpty)
        #expect(empty.emptyText == "No outputs")
        #expect(try WiringSourceList.make(in: Fixture.graph([sink])).emptyText == "No outputs")
        let onlyShortcuts = try WiringSourceList.make(in: Fixture.graph([sink, shortcut]))
        #expect(onlyShortcuts.emptyText == "No outputs")
        #expect(onlyShortcuts.sections.map(\.node.rawValue) == ["nod.ch7"])
        let source = Fixture.node("src", "Src", ports: [Fixture.output("out")])
        #expect(try WiringSourceList.make(in: Fixture.graph([sink, shortcut, source])).emptyText == nil)
    }

    @Test func sourceListReadsNoEdge() throws {
        let plain = Fixture.docGraph()
        var wired = plain
        wired.edges = Fixture.docEdges()
        var dangling = plain
        let keys = Fixture.address("keys", "out")
        let ghost = GraphEdge(id: Fixture.edge("ghost"), from: keys, to: Fixture.address("ghost", "in"))
        dangling.edges = [ghost]
        let expected = try WiringSourceList.make(in: plain)
        #expect(!wired.edges.isEmpty)
        #expect(try WiringSourceList.make(in: wired) == expected)
        #expect(try WiringSourceList.make(in: dangling) == expected)
    }

    @Test func sourceListFindsSectionsAndRowsByNodeAndPortID() throws {
        let list = try WiringSourceList.make(in: Fixture.docGraph())
        for section in list.sections {
            #expect(list.section(for: section.node) == section)
            #expect(section.id == section.node)
            for row in section.rows {
                #expect(list.row(for: row.address) == row)
                #expect(row.id == row.address)
            }
        }
        #expect(list.rows == list.sections.flatMap(\.rows))
        #expect(list.section(for: Fixture.node("nope")) == nil)
        #expect(list.row(for: Fixture.address("keys", "nope")) == nil)
        #expect(list.row(for: Fixture.address("verb", "in")) == nil)
        #expect(list.row(for: Fixture.address("nope", "out")) == nil)
        var extended = Fixture.address("keys", "out")
        extended.extensions = ["x": .bool(true)]
        #expect(list.row(for: extended)?.address == Fixture.address("keys", "out"))
    }

    @Test func sourceListIsDeterministicAndLeavesTheGraphUnchanged() throws {
        let graph = Fixture.docGraph()
        let copy = graph
        let first = try WiringSourceList.make(in: graph)
        let second = try WiringSourceList.make(in: graph)
        #expect(first == second)
        #expect(graph == copy)
    }

    @Test func sourceTextPinsEveryFixedText() throws {
        let port = Fixture.output("out", .audio, 1, label: "Out")
        #expect(WiringSourceText.observedNotRoutable == "observed, not routable")
        #expect(WiringSourceText.noOutputs == "No outputs")
        #expect(WiringSourceText.heading(title: "Mains", signal: "2ch") == "Mains (2ch)")
        let heading = WiringSourceText.shortcutHeading(title: "Console channel 7")
        #expect(heading == "Console channel 7 (observed, not routable)")
        #expect(WiringSourceText.fromText(node: "Vocal", port: port, showsPort: false) == "Vocal (1ch audio)")
        #expect(WiringSourceText.fromText(node: "Vocal", port: port, showsPort: true) == "Vocal Out (1ch audio)")
        #expect(WiringSourceText.rowLabel(node: "Vocal", port: port) == "Vocal, Out, audio, 1 channel.")
        let one = WiringSourceText.sectionLabel(title: "Vocal", signals: "1 channel", outputs: 1)
        #expect(one == "Vocal, 1 channel, 1 output.")
        #expect(WiringSourceText.sectionLabel(title: "Vocal", signals: "MIDI", outputs: 2) == "Vocal, MIDI, 2 outputs.")
        #expect(WiringSourceText.shortcutLabel(title: "Console") == "Console, observed, not routable.")
    }
}
