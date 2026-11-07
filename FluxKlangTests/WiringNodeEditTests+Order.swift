//
//  WiringNodeEditTests+Order.swift
//  FluxKlangTests
//
//  Refusal order (#101 WP4). Every fixture here holds BOTH defects of an
//  adjacent pair, with different typed refusals, so the test fails if the
//  two checks swap. Remove has two order claims only: preview before
//  unknownNode, and tooManyEdits before the fold. On a valid graph an unknown
//  node has no attached edge, so unknownNode and tooManyEdits cannot both hold.
//  WiringDraftGraph never runs validate(), so an unvalidated active graph with
//  4,096 or more dangling edges would make both hold; the code returns
//  unknownNode then, and no test pins that.
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
    @Test func nodeAddOrderPreviewBeforeObservedShortcut() throws {
        let (stale, active) = try Nodes.stale()
        let shortcut = Fixture.node("nod.ch9", .observedShortcut, ports: [])
        #expect(Nodes.addRefusal(shortcut, to: stale, active: active) == (try Nodes.mismatch()))
        #expect(Nodes.addRefusal(shortcut, to: Nodes.draft()) == .observedShortcutNotRoutable(shortcut.id))
    }

    @Test func nodeAddOrderObservedShortcutBeforeAlreadyPresent() {
        let shortcut = Fixture.node("nod.keys", .observedShortcut, ports: [])
        #expect(Nodes.addRefusal(shortcut, to: Nodes.draft()) == .observedShortcutNotRoutable(Nodes.keys))
        #expect(Nodes.addRefusal(Nodes.node("nod.keys"), to: Nodes.draft()) == .nodeAlreadyPresent(Nodes.keys))
    }

    @Test func nodeAddOrderAlreadyPresentBeforePortLimit() {
        let both = Nodes.node("nod.keys", ports: Nodes.ports(257))
        #expect(Nodes.addRefusal(both, to: Nodes.draft()) == .nodeAlreadyPresent(Nodes.keys))
        let ports = Nodes.node("nod.fresh", ports: Nodes.ports(257))
        #expect(Nodes.addRefusal(ports, to: Nodes.draft()) == .portLimit(count: 257))
    }

    @Test func nodeAddOrderPortLimitBeforeDuplicatePort() {
        let ports = Nodes.ports(256)
        let both = Nodes.node("nod.both", ports: ports + [ports[0]])
        #expect(Nodes.addRefusal(both, to: Nodes.draft()) == .portLimit(count: 257))
        let duplicate = Nodes.node("nod.dup", ports: [ports[0], ports[0]])
        #expect(Nodes.addRefusal(duplicate, to: Nodes.draft()) == .duplicatePort(node: duplicate.id, port: ports[0].id))
    }

    @Test func nodeAddOrderDuplicatePortBeforeTooManyNodes() {
        let full = Nodes.large(nodes: 4_096, edges: 0)
        let ports = Nodes.ports(2)
        let both = Nodes.node("nod.both", ports: [ports[0], ports[0]])
        let expected = WiringNodeRefusal.duplicatePort(node: both.id, port: ports[0].id)
        #expect(Nodes.addRefusal(both, to: Nodes.draft(on: full), active: full) == expected)
        let fresh = Nodes.node("nod.fresh", ports: ports)
        #expect(Nodes.addRefusal(fresh, to: Nodes.draft(on: full), active: full) == .tooManyNodes)
    }

    @Test func nodeAddOrderTooManyNodesBeforeTooManyEdits() {
        let active = Nodes.large(nodes: 4_096, edges: 4_096)
        let draft = Nodes.disconnecting(4_096, in: active)
        let node = Nodes.node("nod.fresh", ports: [])
        #expect(Nodes.addRefusal(node, to: draft, active: active) == .tooManyNodes)
        let below = Nodes.large(nodes: 3, edges: 4_096)
        #expect(Nodes.addRefusal(node, to: Nodes.disconnecting(4_096, in: below), active: below) == .tooManyEdits)
    }

    @Test func nodeAddOrderTooManyEditsBeforeTheFold() throws {
        let active = Nodes.large(nodes: 3, edges: 4_096)
        let draft = Nodes.disconnecting(4_096, in: active)
        var nan = Nodes.node("nod.nan", ports: [])
        nan.position = GraphPoint(x: .nan, y: 0)
        #expect(Nodes.addRefusal(nan, to: draft, active: active) == .tooManyEdits)
        let short = Nodes.disconnecting(4_095, in: active)
        #expect(Nodes.addRefusal(nan, to: short, active: active) == .fold(.invalidPosition(nan.id)))
    }

    @Test func nodeRemoveOrderPreviewBeforeUnknownNode() throws {
        let (stale, active) = try Nodes.stale()
        let missing = Nodes.nodeID("nod.never")
        #expect(Nodes.removeRefusal(missing, from: stale, active: active) == (try Nodes.mismatch()))
        #expect(Nodes.removeRefusal(missing, from: Nodes.draft()) == .unknownNode(missing))
    }

    @Test func nodeRemoveOrderTooManyEditsBeforeTheFold() throws {
        let active = Nodes.large(nodes: 2, edges: 4_096)
        let hub = Nodes.nodeID("nod.a")
        #expect(Nodes.removeRefusal(hub, from: Nodes.draft(on: active), active: active) == .tooManyEdits)
        // The fold refuses the same 4,097-edit gesture too, with its own reason, so the composer's check decides.
        let gesture = Nodes.disconnects(active.edges.map(\.id.rawValue)) + [.removeNode(hub)]
        let limit = ProjectGraphLimitError.exceeded(path: "$.gesture", maximum: 4_096)
        #expect(throws: DraftHistoryRefusal.bounds(limit)) {
            try DraftEditFold.fold(gesture, onto: [], base: active)
        }
    }
}
