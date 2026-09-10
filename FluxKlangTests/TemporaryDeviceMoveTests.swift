//
//  TemporaryDeviceMoveTests.swift
//  FluxKlangTests
//

import Foundation
import Testing
@testable import FluxKlang

struct TemporaryDeviceMoveTests {
    private final class MemoryCloudStore: CloudKeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
        func setData(_ data: Data, forKey key: String) { lock.withLock { storage[key] = data } }
        @discardableResult func synchronize() -> Bool { true }
    }

    @Test func monoSuggestionUsesFirstCompatibleFreeConnector() throws {
        let synth = Equipment(name: "Mono", outputs: ["Out"])
        let other = Equipment(name: "Other", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: other.id, outputPort: 0)
        ])

        let suggestion = try TemporaryMoveAllocator.suggestion(
            for: synth.id,
            home: home,
            equipment: [synth, other],
            existingMoves: []
        )

        #expect(suggestion.inputConnectors == [3])
        #expect(suggestion.outputConnectors.isEmpty)
    }

    @Test func stereoSuggestionPrioritizesContiguousLeftRightPair() throws {
        let stereo = Equipment(name: "Stereo", outputs: ["L", "R"], isStereo: true)
        let occupied = Equipment(name: "Occupied", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: stereo.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: stereo.id, outputPort: 1),
            StudioInputConnection(connector: 3, equipmentID: occupied.id, outputPort: 0),
            StudioInputConnection(connector: 6, equipmentID: occupied.id, outputPort: 0)
        ])

        let suggestion = try TemporaryMoveAllocator.suggestion(
            for: stereo.id,
            home: home,
            equipment: [stereo, occupied],
            existingMoves: []
        )

        #expect(suggestion.inputConnectors == [4, 5])
        let move = try TemporaryMoveAllocator.makeMove(
            equipmentID: stereo.id,
            inputConnectors: suggestion.inputConnectors,
            outputConnectors: [],
            home: home,
            equipment: [stereo, occupied],
            existingMoves: []
        )
        #expect(move.connections.inputs.map(\.outputPort) == [0, 1])
        #expect(move.connections.inputs.map(\.connector) == [4, 5])
    }

    @Test func simultaneousMovesShareOneConflictAllocator() throws {
        let first = Equipment(name: "First", outputs: ["Out"])
        let second = Equipment(name: "Second", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: first.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: second.id, outputPort: 0)
        ])
        let firstMove = try TemporaryMoveAllocator.makeMove(
            equipmentID: first.id,
            inputConnectors: [3],
            outputConnectors: [],
            home: home,
            equipment: [first, second],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))
        let secondMove = try TemporaryMoveAllocator.makeMove(
            equipmentID: second.id,
            inputConnectors: [4],
            outputConnectors: [],
            home: home,
            equipment: [first, second],
            existingMoves: [firstMove]
        ).activating(with: TemporaryMoveVerification(state: .verified))
        let connections = GlobalStudioConnections(home: home, temporaryMoves: [firstMove, secondMove])

        #expect(connections.effectiveHome.inputs.map(\.connector).sorted() == [3, 4])
    }

    @Test func conflictRejectionCoversHomeAndActiveMoves() throws {
        let first = Equipment(name: "First", outputs: ["Out"])
        let second = Equipment(name: "Second", outputs: ["Out"])
        let third = Equipment(name: "Third", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: first.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: second.id, outputPort: 0),
            StudioInputConnection(connector: 5, equipmentID: third.id, outputPort: 0)
        ])
        let active = try TemporaryMoveAllocator.makeMove(
            equipmentID: first.id,
            inputConnectors: [4],
            outputConnectors: [],
            home: home,
            equipment: [first, second, third],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))

        #expect(throws: TemporaryMoveConflict.inputConnectorInUse(5)) {
            try TemporaryMoveAllocator.makeMove(
                equipmentID: second.id,
                inputConnectors: [5],
                outputConnectors: [],
                home: home,
                equipment: [first, second, third],
                existingMoves: [active]
            )
        }

        #expect(throws: TemporaryMoveConflict.inputConnectorInUse(4)) {
            try TemporaryMoveAllocator.makeMove(
                equipmentID: second.id,
                inputConnectors: [4],
                outputConnectors: [],
                home: home,
                equipment: [first, second, third],
                existingMoves: [active]
            )
        }
    }

    @Test func plannedMovesReserveConnectorsBeforeEitherMoveIsActive() throws {
        let first = Equipment(name: "First", outputs: ["Out"])
        let second = Equipment(name: "Second", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: first.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: second.id, outputPort: 0)
        ])
        let planned = try TemporaryMoveAllocator.makeMove(
            equipmentID: first.id,
            inputConnectors: [3],
            outputConnectors: [],
            home: home,
            equipment: [first, second],
            existingMoves: []
        )

        #expect(throws: TemporaryMoveConflict.inputConnectorInUse(3)) {
            try TemporaryMoveAllocator.makeMove(
                equipmentID: second.id,
                inputConnectors: [3],
                outputConnectors: [],
                home: home,
                equipment: [first, second],
                existingMoves: [planned]
            )
        }
    }

    @Test func effectiveOverlayPreservesHomeAssignments() throws {
        let effect = Equipment(name: "Effect", inputs: ["L", "R"], outputs: ["L", "R"], isStereo: true)
        let home = StudioHomeConnections(
            inputs: [
                StudioInputConnection(connector: 1, equipmentID: effect.id, outputPort: 0),
                StudioInputConnection(connector: 2, equipmentID: effect.id, outputPort: 1)
            ],
            outputs: [
                StudioOutputConnection(connector: 1, equipmentID: effect.id, inputPort: 0),
                StudioOutputConnection(connector: 2, equipmentID: effect.id, inputPort: 1)
            ]
        )
        let move = try TemporaryMoveAllocator.makeMove(
            equipmentID: effect.id,
            inputConnectors: [7, 8],
            outputConnectors: [3, 4],
            home: home,
            equipment: [effect],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))
        let connections = GlobalStudioConnections(home: home, temporaryMoves: [move])

        #expect(connections.home == home)
        #expect(connections.effectiveHome.inputs.map(\.connector) == [7, 8])
        #expect(connections.effectiveHome.outputs.map(\.connector) == [3, 4])
    }

    @MainActor
    @Test func activeMovePersistsThroughGlobalCloudStoreReload() async throws {
        let cloud = MemoryCloudStore()
        let fileStore = JSONFileStore(cloud: cloud)
        let fileName = "temporary-moves-\(UUID().uuidString).json"
        let synth = Equipment(name: "Synth", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0)
        ])
        let move = try TemporaryMoveAllocator.makeMove(
            equipmentID: synth.id,
            inputConnectors: [3],
            outputConnectors: [],
            home: home,
            equipment: [synth],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))
        let first = StudioConnectionsStore(fileStore: fileStore, fileName: fileName)
        await first.load(equipment: [synth], environments: [], activeID: nil)
        try await first.replaceHome(home, equipment: [synth])
        try await first.activateTemporaryMove(move, equipment: [synth])

        let reloaded = StudioConnectionsStore(fileStore: fileStore, fileName: fileName)
        await reloaded.load(equipment: [synth], environments: [], activeID: nil)

        #expect(reloaded.connections.home == home)
        #expect(reloaded.connections.temporaryMoves == [move])
        #expect(reloaded.connections.effectiveHome.inputs.map(\.connector) == [3])
    }

    @MainActor
    @Test func homeEditCannotTakeConnectorReservedByActiveMove() async throws {
        let first = Equipment(name: "First", outputs: ["Out"])
        let second = Equipment(name: "Second", outputs: ["Out"])
        let store = StudioConnectionsStore(
            fileStore: JSONFileStore(cloud: MemoryCloudStore()),
            fileName: "temporary-home-edit-\(UUID().uuidString).json"
        )
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: first.id, outputPort: 0),
            StudioInputConnection(connector: 2, equipmentID: second.id, outputPort: 0)
        ])
        await store.load(equipment: [first, second], environments: [], activeID: nil)
        try await store.replaceHome(home, equipment: [first, second])
        let move = try TemporaryMoveAllocator.makeMove(
            equipmentID: first.id,
            inputConnectors: [3],
            outputConnectors: [],
            home: home,
            equipment: [first, second],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))
        try await store.activateTemporaryMove(move, equipment: [first, second])

        await #expect(throws: StudioConnectionAssignmentError.self) {
            try await store.setInput(
                StudioInputConnection(connector: 3, equipmentID: second.id, outputPort: 0),
                connector: 3,
                equipment: [first, second]
            )
        }
        #expect(store.connections.home == home)
    }

    @Test func reconnectMismatchBecomesDrift() {
        let expected = [WingSetting(address: "/expected", value: .int(4))]
        let prior = TemporaryMoveVerification(state: .verified, expectedCount: 1, confirmedCount: 1)

        let verification = TemporaryMoveVerifier.verify(
            expected: expected,
            confirmedValues: ["/expected": .int(7)],
            previous: prior
        )

        #expect(verification.state == .driftDetected)
        #expect(verification.confirmedCount == 0)
    }

    @Test func initialMismatchIsFailedVerification() {
        let verification = TemporaryMoveVerifier.verify(
            expected: [WingSetting(address: "/expected", value: .string("LC"))],
            confirmedValues: ["/expected": .string("AUX")]
        )

        #expect(verification.state == .failed)
        #expect(verification.expectedCount == 1)
    }

    @Test func verifiedReturnRestoresHomeAndRemovesOnlyOverride() throws {
        let synth = Equipment(name: "Synth", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0)
        ])
        let move = try TemporaryMoveAllocator.makeMove(
            equipmentID: synth.id,
            inputConnectors: [3],
            outputConnectors: [],
            home: home,
            equipment: [synth],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))
        let connections = GlobalStudioConnections(home: home, temporaryMoves: [move])
        let restored = connections.effectiveHome(removing: move.id)

        #expect(restored == home)
        #expect(connections.home == home)
        #expect(connections.effectiveHome != home)
    }

    @Test func readyToReturnTargetsHomeWhileKeepingRecoveryRecord() throws {
        let synth = Equipment(name: "Synth", outputs: ["Out"])
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0)
        ])
        let active = try TemporaryMoveAllocator.makeMove(
            equipmentID: synth.id,
            inputConnectors: [3],
            outputConnectors: [],
            home: home,
            equipment: [synth],
            existingMoves: []
        ).activating(with: TemporaryMoveVerification(state: .verified))
        let returning = active.preparingReturn()
        let connections = GlobalStudioConnections(home: home, temporaryMoves: [returning])

        #expect(connections.effectiveHome == home)
        #expect(connections.move(for: synth.id) == returning)
    }

    @Test func routingTransitionClearsAbandonedOutputAndChannelNodes() {
        let previous = WingOutputSource(group: .bus, index: 4).settings(forOutput: 1)
            + WingSource(group: .local, index: 1).settings(forChannel: 9)
        let candidate = WingOutputSource(group: .bus, index: 4).settings(forOutput: 3)
        let impact = TemporaryMoveRoutingImpact.transition(
            from: previous,
            to: candidate,
            previousInputConnectors: [1],
            previousOutputConnectors: [1],
            desiredInputConnectors: [],
            desiredOutputConnectors: [3]
        )
        let expected = Dictionary(
            impact.expectedConfirmations.map { ($0.address, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )

        #expect(expected[WingAddress.outputSourceGroup(1)] == .string(WingOutputSourceGroup.off.rawValue))
        #expect(expected[WingAddress.outputSourceIndex(1)] == .int(0))
        #expect(expected[WingAddress.channelSourceGroup(9)] == .string(WingSourceGroup.off.rawValue))
        #expect(expected[WingAddress.channelSourceIndex(9)] == .int(0))
    }
}
