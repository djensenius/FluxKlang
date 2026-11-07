//
//  WiringNodeEditTests+Add.swift
//  FluxKlangTests
//
//  Adding a node (#101 WP4): the folded `addNode`, each refusal singly, N and
//  N+1 at the port, node and edit bounds, and the ID reuse rule.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Nodes = WiringNodeEditTests

extension WiringNodeEditTests {
    @Test func nodeAddFoldsExactlyOneAddNodeAfterTheExistingEdits() throws {
        let existing = GraphEdit.moveNode(Nodes.keys, to: GraphPoint(x: 5, y: 6))
        let draft = Nodes.draft([existing])
        let node = Nodes.node("nod.new")
        let result = try WiringNodeComposer.add(node, to: draft, active: Fixture.graph)
        #expect(result.edits == [existing, .addNode(node)])
        #expect(result.id == draft.id)
        #expect(result.graph == draft.graph)
        #expect(result.baseRevision == draft.baseRevision)
        let graph = try Fixture.graph.applying(result.edits)
        #expect(graph.nodes.map(\.id.rawValue).last == "nod.new")
        #expect(graph.nodes.count == Fixture.graph.nodes.count + 1)
    }

    @Test func nodeAddToAnEmptyActiveGraphWorks() throws {
        let active = GraphDocument(id: Fixture.graphID)
        let node = Nodes.node("nod.first", ports: [])
        let result = try WiringNodeComposer.add(node, to: Nodes.draft(on: active), active: active)
        #expect(result.edits == [.addNode(node)])
    }

    @Test func nodeAddNeverTouchesTheActiveGraphOrTheDraftInput() throws {
        let draft = Nodes.draft()
        let active = Fixture.graph
        _ = try WiringNodeComposer.add(Nodes.node("nod.new"), to: draft, active: active)
        #expect(draft == Nodes.draft())
        #expect(active == Fixture.graph)
    }

    @Test func nodeAddRefusesAnObservedShortcutAndLeavesTheDraftAsItWas() {
        let shortcut = Fixture.node("nod.ch9", .observedShortcut, ports: [])
        let draft = Nodes.draft([.moveNode(Nodes.keys, to: nil)])
        #expect(Nodes.addRefusal(shortcut, to: draft) == .observedShortcutNotRoutable(shortcut.id))
    }

    @Test func nodeAddRefusesEveryNonRoutableKindButAcceptsEveryRoutableKind() throws {
        for kind in NodeKind.allCases {
            let node = Fixture.node("nod.kind", kind, ports: [])
            let refusal = Nodes.addRefusal(node, to: Nodes.draft())
            #expect((refusal == .observedShortcutNotRoutable(node.id)) == !kind.isRoutable, "\(kind)")
            if kind.isRoutable { #expect(refusal == nil, "\(kind)") }
        }
    }

    @Test func nodeAddRefusesAnIDThatIsAnActiveNode() {
        let again = Nodes.node("nod.keys")
        #expect(Nodes.addRefusal(again, to: Nodes.draft()) == .nodeAlreadyPresent(Nodes.keys))
    }

    @Test func nodeAddRefusesAnIDTheDraftAlreadyAdded() throws {
        let first = Nodes.node("nod.new")
        let draft = try WiringNodeComposer.add(first, to: Nodes.draft(), active: Fixture.graph)
        let second = Nodes.node("nod.new", label: "other")
        #expect(Nodes.addRefusal(second, to: draft) == .nodeAlreadyPresent(first.id))
        #expect(Nodes.addRefusal(first, to: draft) == .nodeAlreadyPresent(first.id))
    }

    @Test func nodeAddRefusesADifferentNodeUnderADraftRemovedActiveID() throws {
        let draft = Nodes.draft([.removeNode(Nodes.shortcut)])
        let other = Fixture.node("nod.ch7", ports: [])
        #expect(other != Fixture.graph.node(Nodes.shortcut))
        #expect(Nodes.addRefusal(other, to: draft) == .nodeAlreadyPresent(Nodes.shortcut))
    }

    @Test func nodeAddOfTheEqualDraftRemovedActiveNodeIsRefusedByTheFoldNotCancelled() throws {
        let echo = Nodes.nodeID("nod.echo")
        let draft = try WiringNodeComposer.remove(node: echo, from: Nodes.draft(), active: Fixture.graph)
        let original = try #require(Fixture.graph.node(echo))
        // The sheet asks for a cancel; DraftEditFold refuses `nodeIDReuse`, and it is not ours to change.
        #expect(Nodes.addRefusal(original, to: draft) == .fold(.nodeIDReuse(echo)))
        var renamed = original
        renamed.label = "renamed"
        #expect(Nodes.addRefusal(renamed, to: draft) == .nodeAlreadyPresent(echo))
    }

    @Test func nodeAddAcceptsAShortcutLookalikeThatIsRoutable() throws {
        let node = Fixture.node("nod.ch8", .plugin, ports: [])
        let result = try WiringNodeComposer.add(node, to: Nodes.draft(), active: Fixture.graph)
        #expect(result.edits == [.addNode(node)])
    }

    @Test func nodeAddAcceptsTwoHundredFiftySixPortsRefusesTwoHundredFiftySevenAndAcceptsNone() throws {
        let full = Nodes.node("nod.full", ports: Nodes.ports(256))
        let result = try WiringNodeComposer.add(full, to: Nodes.draft(), active: Fixture.graph)
        #expect(result.edits == [.addNode(full)])
        let over = Nodes.node("nod.over", ports: Nodes.ports(257))
        #expect(Nodes.addRefusal(over, to: Nodes.draft()) == .portLimit(count: 257))
        let bare = Nodes.node("nod.bare", ports: [])
        #expect(try WiringNodeComposer.add(bare, to: Nodes.draft(), active: Fixture.graph).edits == [.addNode(bare)])
    }

    @Test func nodeAddRefusesAPortIDDeclaredTwiceNamingTheFirstRepeat() {
        let ports = ["a", "b", "b", "a"].map { Fixture.audio($0, .output, 1) }
        let node = Nodes.node("nod.dup", ports: ports)
        let expected = WiringNodeRefusal.duplicatePort(node: node.id, port: PortID(validated: "b"))
        #expect(Nodes.addRefusal(node, to: Nodes.draft()) == expected)
        let mixed = [Fixture.audio("x", .output, 1), Fixture.audio("x", .input, 1)]
        let reused = Nodes.node("nod.dir", ports: mixed)
        let reusedExpected = WiringNodeRefusal.duplicatePort(node: reused.id, port: PortID(validated: "x"))
        #expect(Nodes.addRefusal(reused, to: Nodes.draft()) == reusedExpected)
    }

    @Test func nodeAddAcceptsTheNodeThatMakesFourThousandNinetySixAndRefusesTheNext() throws {
        let below = Nodes.large(nodes: 4_095, edges: 0)
        let node = Nodes.node("nod.last", ports: [])
        let result = try WiringNodeComposer.add(node, to: Nodes.draft(on: below), active: below)
        #expect(result.edits == [.addNode(node)])
        let full = Nodes.large(nodes: 4_096, edges: 0)
        #expect(Nodes.addRefusal(node, to: Nodes.draft(on: full), active: full) == .tooManyNodes)
    }

    @Test func nodeAddCountsTheDraftsOwnAdditionsAgainstTheNodeBound() throws {
        let below = Nodes.large(nodes: 4_094, edges: 0)
        let first = Nodes.node("nod.first", ports: [])
        let draft = try WiringNodeComposer.add(first, to: Nodes.draft(on: below), active: below)
        let second = Nodes.node("nod.second", ports: [])
        let again = try WiringNodeComposer.add(second, to: draft, active: below)
        #expect(again.edits == [.addNode(first), .addNode(second)])
        let third = Nodes.node("nod.third", ports: [])
        #expect(Nodes.addRefusal(third, to: again, active: below) == .tooManyNodes)
    }

    @Test func nodeAddAcceptsTheEditThatMakesFourThousandNinetySixAndRefusesTheNext() throws {
        let active = Nodes.large(nodes: 3, edges: 4_096)
        let node = Nodes.node("nod.last", ports: [])
        let below = Nodes.disconnecting(4_095, in: active)
        let result = try WiringNodeComposer.add(node, to: below, active: active)
        #expect(result.edits.count == 4_096)
        #expect(result.edits.last == .addNode(node))
        let full = Nodes.disconnecting(4_096, in: active)
        #expect(Nodes.addRefusal(node, to: full, active: active) == .tooManyEdits)
    }

    @Test func nodeAddRefusesWhatTheFoldRefusesWithTheFoldsOwnTypedReason() {
        var nan = Nodes.node("nod.nan")
        nan.position = GraphPoint(x: .nan, y: 0)
        #expect(Nodes.addRefusal(nan, to: Nodes.draft()) == .fold(.invalidPosition(nan.id)))
        var gain = Nodes.node("nod.gain")
        gain.linearGain = .infinity
        #expect(Nodes.addRefusal(gain, to: Nodes.draft()) == .fold(.nonFiniteNodeValue(gain.id)))
    }

    @Test func nodeAddAcceptsTheCapabilityBoundAndRefusesOneOver() throws {
        let capability: CapabilityID = Fixture.id("cap.x")
        var node = Nodes.node("nod.caps")
        node.requiredCapabilities = Array(repeating: capability, count: 1_024)
        let result = try WiringNodeComposer.add(node, to: Nodes.draft(), active: Fixture.graph)
        #expect(result.edits == [.addNode(node)])
        node.advisoryCapabilities = [capability]
        let limit = ProjectGraphLimitError.exceeded(path: "$.nodes[nod.caps].capabilities", maximum: 1_024)
        #expect(Nodes.addRefusal(node, to: Nodes.draft()) == .fold(.bounds(limit)))
    }

    @Test func nodeAddCarriesAThreeByteScalarLabelByteForByte() throws {
        let label = String(repeating: "\u{20AC}", count: 2_000) + "e\u{301}\u{200B}"
        let node = Nodes.node("nod.label", label: label)
        let result = try WiringNodeComposer.add(node, to: Nodes.draft(), active: Fixture.graph)
        guard case .addNode(let added)? = result.edits.first else {
            Issue.record("no addNode")
            return
        }
        #expect(Array(added.label.utf8) == Array(label.utf8))
        #expect(added.label.utf8.count == 6_000 + 3 + 3)
        #expect(added == node)
    }

    @Test func nodeAddRefusesAStaleDraftWithTheDraftAndActiveRevisions() throws {
        let (stale, active) = try Nodes.stale()
        let mismatch = try Nodes.mismatch()
        #expect(Nodes.addRefusal(Nodes.node("nod.new"), to: stale, active: active) == mismatch)
        var other = Nodes.draft()
        other.graph = GraphID(validated: "gph.other")
        let expected = WiringNodeRefusal.preview(.draftGraphMismatch(draft: other.graph, active: Fixture.graphID))
        #expect(Nodes.addRefusal(Nodes.node("nod.new"), to: other) == expected)
    }

    @Test func nodeAddRefusesADraftThatDoesNotApplyBeforeAnyNodeCheck() {
        let broken = Nodes.draft([.disconnect(Nodes.edgeID("edg.never"))])
        let expected = WiringNodeRefusal.preview(.draftDoesNotApply(.missingEdge(Nodes.edgeID("edg.never"))))
        #expect(Nodes.addRefusal(Nodes.node("nod.new"), to: broken) == expected)
    }
}
