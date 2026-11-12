//
//  WorkspaceInspectorSelectionTests.swift
//  FluxKlangTests
//
//  The inspector's selection presentation as a pure value (#99 INS1): the empty prompt, single and multiple
//  selections, the draft-only and removed states, and the refusals and their order.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum WorkspaceInspectorFixture {
    static func node(_ raw: String) throws -> WorkspaceItemRef { .node(try NodeID(raw)) }
    static func edge(_ raw: String) throws -> WorkspaceItemRef { .edge(try EdgeID(raw)) }
    static func port(_ port: String, on node: String) throws -> WorkspaceItemRef {
        .port(node: try NodeID(node), port: try PortID(port))
    }

    static func revision(_ value: Int) throws -> ContractRevision { try ContractRevision(value) }

    static func make(
        _ selection: [WorkspaceSelectionEntry],
        draftOnly: Set<WorkspaceItemRef> = [],
        activeRevision: Int? = nil
    ) throws -> WorkspaceInspectorSelection {
        try WorkspaceInspectorSelection.make(
            selection: selection,
            draftOnly: draftOnly,
            activeRevision: try activeRevision.map { try revision($0) }
        )
    }

    static func nodes(_ count: Int) throws -> [WorkspaceSelectionEntry] {
        try (0..<count).map { .live(try node("nod.\($0)")) }
    }
}

#if os(macOS)
@Suite("Workspace inspector selection", .productionAccessAudit)
#else
@Suite("Workspace inspector selection")
#endif
struct WorkspaceInspectorSelectionTests {
    typealias Fixture = WorkspaceInspectorFixture

    @Test func anEmptySelectionShowsThePrompt() throws {
        let inspector = try Fixture.make([])
        #expect(inspector.content == .empty)
        #expect(inspector.rows.isEmpty)
        #expect(inspector.headline == "Select a node, edge, speaker or control")
        #expect(inspector.announcement == "Select a node, edge, speaker or control")
    }

    @Test func oneLiveNodeIsActive() throws {
        let item = try Fixture.node("nod.0")
        let inspector = try Fixture.make([.live(item)])
        let row = try #require(inspector.rows.first)
        #expect(inspector.rows.count == 1)
        #expect(inspector.content == .single(row))
        #expect(row.item == item)
        #expect(row.kindText == "Node")
        #expect(row.title == "Node nod.0")
        #expect(row.idText == "nod.0")
        #expect(row.state == .active)
        #expect(row.stateText == nil)
        #expect(row.accessibilityLabel == "Node nod.0")
        #expect(inspector.headline == "Node nod.0")
        #expect(inspector.announcement == "Node nod.0")
    }

    @Test func oneLiveEdgeIsActive() throws {
        let inspector = try Fixture.make([.live(try Fixture.edge("edg.7"))])
        let row = try #require(inspector.rows.first)
        #expect(inspector.content == .single(row))
        #expect(row.kindText == "Edge")
        #expect(row.title == "Edge edg.7")
        #expect(row.idText == "edg.7")
        #expect(row.state == .active)
        #expect(row.stateText == nil)
        #expect(row.accessibilityLabel == "Edge edg.7")
        #expect(inspector.headline == "Edge edg.7")
        #expect(inspector.announcement == "Edge edg.7")
    }

    @Test func aPortNamesItsNode() throws {
        let first = try Fixture.make([.live(try Fixture.port("out", on: "nod.0"))])
        let row = try #require(first.rows.first)
        #expect(row.kindText == "Port")
        #expect(row.title == "Port out on node nod.0")
        #expect(row.idText == "nod.0/out")
        #expect(row.accessibilityLabel == "Port out on node nod.0")
        #expect(first.headline == "Port out on node nod.0")

        let second = try Fixture.make([.live(try Fixture.port("out", on: "nod.1"))])
        let other = try #require(second.rows.first)
        #expect(other.title == "Port out on node nod.1")
        #expect(other.idText == "nod.1/out")
        #expect(other.title != row.title)
        #expect(other.idText != row.idText)
    }

    @Test func aNodeAnEdgeAndAPortSharingARawIdAreThreeItems() throws {
        let inspector = try Fixture.make([
            .live(try Fixture.node("same.0")),
            .live(try Fixture.edge("same.0")),
            .live(try Fixture.port("same.0", on: "same.0"))
        ])
        let rows = inspector.rows
        try #require(rows.count == 3)
        #expect(rows.map(\.title) == ["Node same.0", "Edge same.0", "Port same.0 on node same.0"])
        #expect(rows.map(\.idText) == ["same.0", "same.0", "same.0/same.0"])
        #expect(inspector.headline == "3 items selected")
    }

    @Test func aPortIsIdentifiedByItsNodeAndItsPortId() throws {
        let first = try Fixture.port("out", on: "nod.0")
        let second = try Fixture.port("out", on: "nod.1")
        let inspector = try Fixture.make([.live(first), .live(second)])
        let rows = inspector.rows
        try #require(rows.count == 2)
        #expect(inspector.content == .multiple(rows))
        #expect(rows.map(\.item) == [first, second])
        #expect(rows.map(\.idText) == ["nod.0/out", "nod.1/out"])
        #expect(rows.map(\.title) == ["Port out on node nod.0", "Port out on node nod.1"])
        #expect(throws: WorkspaceInspectorRefusal.duplicateSelectionItem(first)) {
            try Fixture.make([.live(first), .live(try Fixture.port("out", on: "nod.0"))])
        }
    }

    @Test func aDraftOnlyItemNamesTheActiveRevision() throws {
        let item = try Fixture.node("nod.0")
        let inspector = try Fixture.make([.live(item)], draftOnly: [item], activeRevision: 43)
        let row = try #require(inspector.rows.first)
        #expect(row.state == .draftOnly(activeRevision: try Fixture.revision(43)))
        #expect(row.stateText == "Not in active rev 43")
        #expect(row.accessibilityLabel == "Node nod.0, Not in active rev 43")
        #expect(inspector.headline == "Node nod.0")
        #expect(inspector.announcement == "Node nod.0, Not in active rev 43")
    }

    @Test func aDraftOnlyItemNeedsAnActiveRevision() throws {
        let item = try Fixture.node("nod.0")
        #expect(throws: WorkspaceInspectorRefusal.draftItemWithoutActiveRevision(item)) {
            try Fixture.make([.live(item)], draftOnly: [item], activeRevision: nil)
        }
        let accepted = try Fixture.make([.live(item)], draftOnly: [], activeRevision: nil)
        #expect(accepted.rows.first?.state == .active)
    }

    @Test func aRemovedEntryNamesItsOwnRevision() throws {
        let item = try Fixture.edge("edg.1")
        let inspector = try Fixture.make([.removed(item, in: try Fixture.revision(7))], activeRevision: 9)
        let row = try #require(inspector.rows.first)
        #expect(row.state == .removed(revision: try Fixture.revision(7)))
        #expect(row.stateText == "Removed in rev 7")
        #expect(row.accessibilityLabel == "Edge edg.1, Removed in rev 7")
        #expect(inspector.announcement == "Edge edg.1, Removed in rev 7")
    }

    @Test func removedWinsOverDraftOnlyAndIsNeverRefused() throws {
        let item = try Fixture.node("nod.0")
        let entry = WorkspaceSelectionEntry.removed(item, in: try Fixture.revision(7))
        let withRevision = try Fixture.make([entry], draftOnly: [item], activeRevision: 43)
        #expect(withRevision.rows.first?.state == .removed(revision: try Fixture.revision(7)))
        let without = try Fixture.make([entry], draftOnly: [item], activeRevision: nil)
        #expect(without.rows.first?.stateText == "Removed in rev 7")
    }

    @Test func draftOnlyMembersThatAreNotSelectedAreIgnored() throws {
        let selected = try Fixture.node("nod.0")
        let other = try Fixture.node("nod.1")
        let withRevision = try Fixture.make([.live(selected)], draftOnly: [other], activeRevision: 43)
        #expect(withRevision.rows.first?.state == .active)
        let without = try Fixture.make([.live(selected)], draftOnly: [other], activeRevision: nil)
        #expect(without.rows.first?.state == .active)
        let empty = try Fixture.make([], draftOnly: [other], activeRevision: nil)
        #expect(empty.content == .empty)
    }

    @Test func aMultipleSelectionKeepsSelectionOrder() throws {
        let zulu = try Fixture.node("nod.z")
        let draft = try Fixture.edge("edg.m")
        let gone = try Fixture.node("nod.a")
        let inspector = try Fixture.make(
            [.live(zulu), .live(draft), .removed(gone, in: try Fixture.revision(5))],
            draftOnly: [draft],
            activeRevision: 12
        )
        let rows = inspector.rows
        try #require(rows.count == 3)
        #expect(inspector.content == .multiple(rows))
        #expect(rows.map(\.item) == [zulu, draft, gone])
        #expect(rows.map(\.stateText) == [nil, "Not in active rev 12", "Removed in rev 5"])
        #expect(inspector.headline == "3 items selected")
        #expect(inspector.announcement == "3 items selected")
    }

    @Test func twoItemsAreAlreadyAMultipleSelection() throws {
        let first = try Fixture.node("nod.1")
        let second = try Fixture.node("nod.0")
        let inspector = try Fixture.make([.live(first), .live(second)])
        let rows = inspector.rows
        try #require(rows.count == 2)
        #expect(inspector.content == .multiple(rows))
        #expect(rows.map(\.item) == [first, second])
        #expect(inspector.headline == "2 items selected")
        #expect(inspector.announcement == "2 items selected")
    }

    @Test func theSelectionCapIsInclusive() throws {
        let cap = WorkspaceNavigationState.maxSelection
        let full = try Fixture.make(try Fixture.nodes(cap))
        #expect(full.rows.count == cap)
        #expect(full.headline == "256 items selected")
        #expect(throws: WorkspaceInspectorRefusal.selectionLimitExceeded(maximum: cap)) {
            try Fixture.make(try Fixture.nodes(cap + 1))
        }
    }

    @Test func aDuplicateIsRefusedAndTheChecksRunInOrder() throws {
        let item = try Fixture.node("nod.0")
        let other = try Fixture.node("nod.1")
        #expect(throws: WorkspaceInspectorRefusal.duplicateSelectionItem(item)) {
            try Fixture.make([.live(item), .live(other), .live(item)])
        }
        #expect(throws: WorkspaceInspectorRefusal.duplicateSelectionItem(item)) {
            try Fixture.make([.live(item), .removed(item, in: try Fixture.revision(3))])
        }
        #expect(throws: WorkspaceInspectorRefusal.duplicateSelectionItem(item)) {
            try Fixture.make([.removed(item, in: try Fixture.revision(3)), .live(item)])
        }

        let cap = WorkspaceNavigationState.maxSelection
        let overCapAndDuplicated = try Fixture.nodes(cap) + [.live(item)]
        #expect(throws: WorkspaceInspectorRefusal.selectionLimitExceeded(maximum: cap)) {
            try Fixture.make(overCapAndDuplicated)
        }

        let draft = try Fixture.edge("edg.0")
        #expect(throws: WorkspaceInspectorRefusal.duplicateSelectionItem(item)) {
            try Fixture.make([.live(draft), .live(item), .live(item)], draftOnly: [draft], activeRevision: nil)
        }
    }

    @Test func fixedTextsArePinned() throws {
        #expect(WorkspaceInspectorText.count(1) == "1 item selected")
        #expect(WorkspaceInspectorText.count(2) == "2 items selected")
        let node = try Fixture.node("nod.0")
        let zero = WorkspaceInspectorText.state(.removed(revision: try Fixture.revision(0)))
        #expect(zero == "Removed in rev 0")
        let largest = try Fixture.revision(ContractRevision.maximumValue)
        let largestText = WorkspaceInspectorText.state(.draftOnly(activeRevision: largest))
        #expect(largestText == "Not in active rev 9007199254740991")
        #expect(WorkspaceInspectorText.state(.active) == nil)
        #expect(WorkspaceInspectorText.accessibilityLabel(title: "T", stateText: nil) == "T")
        #expect(WorkspaceInspectorText.kind(node) == "Node")
    }
}
