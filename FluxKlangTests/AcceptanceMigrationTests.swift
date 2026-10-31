import Foundation
import Testing
@testable import FluxKlang

struct AcceptanceMigrationTests {
    @Test @MainActor func emptyEquipmentAcceptanceSeedUsesKnownSource() throws {
        let emptySource = try AcceptanceLaunchConfiguration.acceptanceSource(in: [])
        let unrelated = Equipment(name: "Other", outputs: ["Out"])
        let missingSource = try AcceptanceLaunchConfiguration.acceptanceSource(in: [unrelated])

        #expect(emptySource.name == "OP-1 Field")
        #expect(emptySource.outputs == ["Out L", "Out R"])
        #expect(missingSource.id == emptySource.id)
    }

    @Test func legacyGlobalConnectionsDefaultMissingMovesAndIssues() throws {
        let equipmentID = UUID()
        let json = """
        {
          "home": {
            "inputs": [{
              "connector": 4,
              "equipmentID": "\(equipmentID.uuidString)",
              "outputPort": 0
            }],
            "outputs": []
          }
        }
        """

        let decoded = try JSONDecoder().decode(GlobalStudioConnections.self, from: Data(json.utf8))

        #expect(decoded.home.inputs.map(\.connector) == [4])
        #expect(decoded.temporaryMoves.isEmpty)
        #expect(decoded.migrationIssues.isEmpty)
        let roundTripped = try JSONDecoder().decode(
            GlobalStudioConnections.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTripped.home.inputs[0].id == decoded.home.inputs[0].id)
    }

    @Test func legacyEnvironmentDuplicatesWithFreshSerialChainAndPlacements() throws {
        let environmentID = UUID()
        let hallID = UUID()
        let echoID = UUID()
        let synthID = UUID()
        let json = """
        {
          "id": "\(environmentID.uuidString)",
          "name": "Legacy Song",
          "effects": [
            {"id": "\(hallID.uuidString)", "name": "Hall", "sourceInstruments": ["\(synthID.uuidString)"]},
            {"id": "\(echoID.uuidString)", "name": "Echo", "destinationEffectID": "\(hallID.uuidString)"}
          ],
          "placements": {
            "return:\(hallID.uuidString)": {"position": [0.2, 0.8], "width": 0.3},
            "source:\(synthID.uuidString)": {"position": [0.5, 0.5], "width": 0.5}
          }
        }
        """

        let legacy = try JSONDecoder().decode(RoutingEnvironment.self, from: Data(json.utf8))
        let copy = legacy.duplicated(named: "Legacy Song Copy")
        let encoded = try #require(String(bytes: JSONEncoder().encode(copy), encoding: .utf8))

        #expect(copy.effects.map(\.name) == ["Hall", "Echo"])
        #expect(copy.effects[1].destinationEffectID == copy.effects[0].id)
        #expect(copy.effects[0].sourceInstruments == [synthID])
        #expect(copy.placements[EnvironmentVoice.returnID(copy.effects[0].id)]?.width == 0.3)
        #expect(copy.placements[EnvironmentVoice.sourceID(synthID)]?.width == 0.5)
        for originalID in [environmentID, hallID, echoID] {
            #expect(!encoded.contains(originalID.uuidString))
        }
    }

    @Test func legacyTemporaryMoveDefaultsToTrackedSafeState() throws {
        let moveID = UUID()
        let equipmentID = UUID()
        let json = """
        {
          "id": "\(moveID.uuidString)",
          "equipmentID": "\(equipmentID.uuidString)",
          "location": " Stage ",
          "connections": {"inputs": [], "outputs": []}
        }
        """

        let decoded = try JSONDecoder().decode(TemporaryDeviceMove.self, from: Data(json.utf8))

        #expect(decoded.lifecycle == .active)
        #expect(decoded.verification.state == .notVerified)
        #expect(decoded.location == "Stage")
        #expect(decoded.activatedAt == nil)
    }

    @Test func legacyPendingDraftDefaultsNewReviewMetadata() throws {
        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(sourceInstrumentIDs: []),
            equipment: [],
            effects: [],
            connections: GlobalStudioConnections(),
            currentGraph: StudioGraph()
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))
        var object = try #require(encoded as? [String: Any])
        object.removeValue(forKey: "cableInstructions")
        object.removeValue(forKey: "logicalRoutingSummary")
        object.removeValue(forKey: "validation")

        let decoded = try JSONDecoder().decode(
            StudioPatchDraft.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.id == draft.id)
        #expect(decoded.cableInstructions.isEmpty)
        #expect(decoded.logicalRoutingSummary.isEmpty)
        #expect(decoded.validation.isEmpty)
    }

    @Test func legacyConversationAndMessagesDefaultNewFields() throws {
        let conversationID = UUID()
        let messageID = UUID()
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let json = """
        {
          "id": "\(conversationID.uuidString)",
          "title": "Legacy",
          "createdAt": \(date.timeIntervalSince1970),
          "messages": [{
            "id": "\(messageID.uuidString)",
            "role": "assistant",
            "text": "Saved reply",
            "createdAt": \(date.timeIntervalSince1970)
          }]
        }
        """

        let decoded = try decoder.decode(AssistantConversation.self, from: Data(json.utf8))

        #expect(decoded.modifiedAt == date)
        #expect(decoded.summary.isEmpty)
        #expect(decoded.messages[0].state == .complete)
        #expect(decoded.messages[0].cards.isEmpty)
    }
}
