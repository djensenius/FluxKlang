//
//  GraphEditContractTests.swift
//  FluxKlangTests
//
//  Normalized structural edit payloads, candidate-graph application, and the
//  op-for-op match between a draft-edit command and the draft it names
//  (carried forward from the #98/#133 example checker).
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixture = GraphContractTests

extension GraphContractTests {
    struct Edits {
        static let micToCue = GraphEdit.connect(Fixture.edge(
            "edg.mic-cue", Fixture.address("nod.mic", "out"), Fixture.address("nod.cue", "in"),
            conversion: EdgeConversion(map: [[0], [0]], label: "Mono to both sides")
        ))
        static let verb2 = GraphNode(id: NodeID(validated: "nod.verb2"), kind: .plugin, label: "Room Verb 2")
        static let phoneCue = DraftEdits(
            id: DraftID(validated: "dft.phone-cue"), graph: GraphID(validated: "gph.main"),
            baseRevision: (try? ContractRevision(43)) ?? .initial, edits: [micToCue]
        )
        static let restructure = DraftEdits(
            id: DraftID(validated: "dft.restructure"), graph: GraphID(validated: "gph.main"),
            baseRevision: (try? ContractRevision(43)) ?? .initial,
            edits: [.disconnect(EdgeID(validated: "edg.keys-echo")), .addNode(verb2),
                    .removeNode(NodeID(validated: "nod.echo"))]
        )

        static func edit(_ json: String) throws -> GraphEdit {
            try ContractCoding.decode(GraphEdit.self, from: Data(json.utf8))
        }

        @Test func payloadsAreNormalizedAndRoundTrip() throws {
            let spelled = try Self.edit(#"{"edge":{"to":{"port":"in","node":"nod.cue"},"id":"edg.mic-cue","#
                + #""from":{"node":"nod.mic","port":"out"},"conversion":{"label":"Mono to both sides","#
                + #""map":[[0.0],[0]],"kind":"channelMap"}},"op":"connect"}"#)
            #expect(spelled == Self.micToCue)
            for edit in Self.restructure.edits + [Self.micToCue, .moveNode(NodeID(validated: "nod.mic"), to: nil)] {
                let data = try ContractCoding.makeEncoder().encode(edit)
                #expect(try ContractCoding.decode(GraphEdit.self, from: data) == edit)
            }
            #expect(try Self.edit(#"{"op":"removeNode","node":"nod.echo"}"#) == Self.restructure.edits[2])
        }

        @Test(arguments: [
            #"{"op":"disconnect","edge":"edg.keys-echo","node":"nod.keys"}"#,
            #"{"op":"removeNode","node":"nod.echo","cascade":false}"#,
            #"{"op":"rewire","edge":"edg.keys-echo"}"#,
            #"{"op":"disconnect"}"#
        ])
        func rejectsStrayMembersAndUnknownOps(json: String) {
            #expect(throws: DecodingError.self) { try Self.edit(json) }
        }

        @Test(arguments: [
            GraphEdit.disconnect(EdgeID(validated: "edg.keys-verb")),
            .disconnect(EdgeID(validated: "edg.mic-cue")),
            .addNode(Edits.verb2),
            .removeNode(NodeID(validated: "nod.verb")),
            .moveNode(NodeID(validated: "nod.mic"), to: GraphPoint(x: 1, y: 2)),
            .connect(Fixture.edge("edg.mic-cue", Fixture.address("nod.mic", "out"), Fixture.address("nod.cue", "in"),
                                  conversion: EdgeConversion(map: [[0], [0]])))
        ])
        func commandEditsMustEqualAnOpOfTheNamedDraft(edit: GraphEdit) {
            let command = DraftEditCommand(draft: Self.phoneCue.id, edits: [edit])
            #expect(throws: DraftEditError.editNotInDraft(Self.phoneCue.id, index: 0)) {
                try command.validate(against: [Self.phoneCue, Self.restructure])
            }
        }

        @Test func matchingCommandsNameTheirDraft() throws {
            let drafts = [Self.phoneCue, Self.restructure]
            let cue = DraftEditCommand(draft: Self.phoneCue.id, edits: [Self.micToCue])
            #expect(try cue.validate(against: drafts) == Self.phoneCue)
            let restructure = DraftEditCommand(draft: Self.restructure.id, edits: Self.restructure.edits.reversed())
            #expect(try restructure.validate(against: drafts) == Self.restructure)
            // A connect sent against a draft that only disconnects, adds and removes.
            #expect(throws: DraftEditError.editNotInDraft(Self.restructure.id, index: 1)) {
                try DraftEditCommand(draft: Self.restructure.id, edits: [Self.restructure.edits[0], Self.micToCue])
                    .validate(against: drafts)
            }
            let missing = DraftID(validated: "dft.missing")
            #expect(throws: DraftEditError.unknownDraft(missing)) {
                try DraftEditCommand(draft: missing, edits: [Self.micToCue]).validate(against: drafts)
            }
            #expect(throws: DraftEditError.emptyCommand) {
                try DraftEditCommand(draft: Self.phoneCue.id, edits: []).validate(against: drafts)
            }
        }

        @Test func candidateGraphsApplyEditsAndStillValidate() throws {
            let graph = Fixture.sampleGraph()
            let cue = try graph.applying(Self.phoneCue.edits)
            #expect(cue.validationErrors().isEmpty)
            #expect(cue.revision == graph.revision)

            let restructured = try graph.applying(Self.restructure.edits)
            #expect(restructured.node(NodeID(validated: "nod.echo")) == nil)
            let echo = NodeID(validated: "nod.echo")
            #expect(!restructured.edges.contains { $0.to.node == echo || $0.from.node == echo })
            #expect(restructured.validationErrors().isEmpty)

            // Connecting to a node a draft removed leaves a dangling reference.
            #expect(throws: GraphEditError.contradictoryNode(NodeID(validated: "nod.cue"))) {
                try graph.applying([.removeNode(NodeID(validated: "nod.cue")), Self.micToCue])
            }
            #expect(throws: GraphEditError.missingEdge(EdgeID(validated: "edg.ghost"))) {
                try graph.applying([.disconnect(EdgeID(validated: "edg.ghost"))])
            }
            #expect(throws: GraphEditError.nodeExists(NodeID(validated: "nod.mic"))) {
                try graph.applying([.addNode(GraphNode(id: NodeID(validated: "nod.mic"), kind: .plugin, label: "Dup"))])
            }
        }

        @Test func contradictoryDraftEditsRejectRegardlessOfOrder() {
            let graph = Fixture.sampleGraph()
            let remove = GraphEdit.removeNode(NodeID(validated: "nod.cue"))
            for edits in [[Self.micToCue, remove], [remove, Self.micToCue]] {
                #expect(throws: GraphEditError.self) { try graph.applying(edits) }
            }
            let disconnect = GraphEdit.disconnect(EdgeID(validated: "edg.mic-cue"))
            #expect(throws: GraphEditError.self) { try graph.applying([Self.micToCue, disconnect]) }
            let repeated = DraftEditCommand(draft: Self.phoneCue.id, edits: [Self.micToCue, Self.micToCue])
            #expect(throws: DraftEditError.self) { try repeated.validate(against: [Self.phoneCue]) }
        }
    }
}
