//
//  TemporaryDeviceMove.swift
//  FluxKlang
//
//  Persistent physical-equipment overrides layered over immutable Home wiring.
//

import Foundation

enum TemporaryMoveLifecycle: String, Codable, Hashable, Sendable {
    case planned
    case readyToApply
    case active
    case readyToReturn

    var isEffective: Bool {
        self == .readyToApply || self == .active
    }

    var isTracked: Bool {
        self != .planned
    }
}

enum TemporaryMoveVerificationState: String, Codable, Hashable, Sendable {
    case notVerified
    case verified
    case partiallyVerified
    case failed
    case driftDetected

    var label: String {
        switch self {
        case .notVerified: "Not verified"
        case .verified: "Verified"
        case .partiallyVerified: "Partially verified"
        case .failed: "Verification failed"
        case .driftDetected: "Reconnect drift detected"
        }
    }
}

struct TemporaryMoveVerification: Codable, Hashable, Sendable {
    var state: TemporaryMoveVerificationState
    var checkedAt: Date?
    var expectedCount: Int
    var confirmedCount: Int
    var details: String

    init(
        state: TemporaryMoveVerificationState = .notVerified,
        checkedAt: Date? = nil,
        expectedCount: Int = 0,
        confirmedCount: Int = 0,
        details: String = "Routing has not been checked against confirmed console replies."
    ) {
        self.state = state
        self.checkedAt = checkedAt
        self.expectedCount = expectedCount
        self.confirmedCount = confirmedCount
        self.details = details
    }
}

struct TemporaryDeviceMove: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var equipmentID: Equipment.ID
    var location: String?
    var note: String?
    var connections: StudioHomeConnections
    var lifecycle: TemporaryMoveLifecycle
    var verification: TemporaryMoveVerification
    var activatedAt: Date?

    init(
        id: UUID = UUID(),
        equipmentID: Equipment.ID,
        location: String? = nil,
        note: String? = nil,
        connections: StudioHomeConnections,
        lifecycle: TemporaryMoveLifecycle = .planned,
        verification: TemporaryMoveVerification = TemporaryMoveVerification(),
        activatedAt: Date? = nil
    ) {
        self.id = id
        self.equipmentID = equipmentID
        self.location = Self.trimmed(location)
        self.note = Self.trimmed(note)
        self.connections = connections
        self.lifecycle = lifecycle
        self.verification = verification
        self.activatedAt = activatedAt
    }

    func activating(with verification: TemporaryMoveVerification, at date: Date = Date()) -> Self {
        var copy = self
        copy.lifecycle = .active
        copy.verification = verification
        copy.activatedAt = activatedAt ?? date
        return copy
    }

    func preparingApply() -> Self {
        var copy = self
        copy.lifecycle = .readyToApply
        return copy
    }

    func preparingReturn() -> Self {
        var copy = self
        copy.lifecycle = .readyToReturn
        return copy
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct TemporaryMoveSuggestion: Hashable, Sendable {
    var inputConnectors: [Int]
    var outputConnectors: [Int]
}

enum TemporaryMoveConflict: LocalizedError, Equatable {
    case missingEquipment
    case alreadyMoving(String)
    case noHomeConnections(String)
    case connectorCountMismatch
    case insufficientFreeConnectors(direction: String, required: Int, available: Int)
    case duplicateInputConnector(Int)
    case duplicateOutputConnector(Int)
    case inputConnectorInUse(Int)
    case outputConnectorInUse(Int)
    case invalidInputConnector(Int)
    case invalidOutputConnector(Int)

    var errorDescription: String? {
        switch self {
        case .missingEquipment:
            return "The selected equipment no longer exists."
        case .alreadyMoving(let name):
            return "\(name) already has a temporary move."
        case .noHomeConnections(let name):
            return "\(name) has no Home connectors to move."
        case .connectorCountMismatch:
            return "Every Home cable needs one temporary connector."
        case .insufficientFreeConnectors(let direction, let required, let available):
            return "Only \(available) free WING \(direction) connectors are available for \(required) Home cables."
        case .duplicateInputConnector(let connector):
            return "WING input \(connector) is selected more than once."
        case .duplicateOutputConnector(let connector):
            return "WING output \(connector) is selected more than once."
        case .inputConnectorInUse(let connector):
            return "WING input \(connector) is already reserved by Home or another move."
        case .outputConnectorInUse(let connector):
            return "WING output \(connector) is already reserved by Home or another move."
        case .invalidInputConnector(let connector):
            return "WING input \(connector) is outside 1...24."
        case .invalidOutputConnector(let connector):
            return "WING output \(connector) is outside 1...8."
        }
    }
}

enum TemporaryMoveApplyError: LocalizedError {
    case notConnected
    case routingErrors
    case missingMove

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect to the WING or enter Demo Mode before applying routing."
        case .routingErrors:
            return "The current studio patch has routing errors. Fix them before applying this move."
        case .missingMove:
            return "This temporary move is no longer active."
        }
    }
}

enum TemporaryMoveAllocator {
    // Draft metadata and both connector directions belong in one atomic allocation request.
    // swiftlint:disable:next function_parameter_count
    static func makeMove(
        equipmentID: Equipment.ID,
        inputConnectors: [Int],
        outputConnectors: [Int],
        location: String? = nil,
        note: String? = nil,
        home: StudioHomeConnections,
        equipment: [Equipment],
        existingMoves: [TemporaryDeviceMove]
    ) throws -> TemporaryDeviceMove {
        let device = try device(equipmentID, equipment: equipment)
        let homeInputs = inputs(for: equipmentID, in: home)
        let homeOutputs = outputs(for: equipmentID, in: home)
        guard !homeInputs.isEmpty || !homeOutputs.isEmpty else {
            throw TemporaryMoveConflict.noHomeConnections(device.name)
        }
        guard homeInputs.count == inputConnectors.count, homeOutputs.count == outputConnectors.count else {
            throw TemporaryMoveConflict.connectorCountMismatch
        }
        let move = TemporaryDeviceMove(
            equipmentID: equipmentID,
            location: location,
            note: note,
            connections: StudioHomeConnections(
                inputs: zip(homeInputs, inputConnectors).map { homeConnection, connector in
                    StudioInputConnection(
                        connector: connector,
                        equipmentID: equipmentID,
                        outputPort: homeConnection.outputPort,
                        labelOverride: homeConnection.labelOverride
                    )
                },
                outputs: zip(homeOutputs, outputConnectors).map { homeConnection, connector in
                    StudioOutputConnection(
                        connector: connector,
                        equipmentID: equipmentID,
                        inputPort: homeConnection.inputPort,
                        labelOverride: homeConnection.labelOverride
                    )
                }
            )
        )
        try validate(move, home: home, equipment: equipment, existingMoves: existingMoves)
        return move
    }

    static func suggestion(
        for equipmentID: Equipment.ID,
        home: StudioHomeConnections,
        equipment: [Equipment],
        existingMoves: [TemporaryDeviceMove]
    ) throws -> TemporaryMoveSuggestion {
        let device = try device(equipmentID, equipment: equipment)
        guard !existingMoves.contains(where: { $0.equipmentID == equipmentID }) else {
            throw TemporaryMoveConflict.alreadyMoving(device.name)
        }
        let homeInputs = inputs(for: equipmentID, in: home)
        let homeOutputs = outputs(for: equipmentID, in: home)
        guard !homeInputs.isEmpty || !homeOutputs.isEmpty else {
            throw TemporaryMoveConflict.noHomeConnections(device.name)
        }
        var reservations = reservations(home: home, moves: existingMoves, excluding: equipmentID)
        reservations.inputs.formUnion(homeInputs.map(\.connector))
        reservations.outputs.formUnion(homeOutputs.map(\.connector))
        return TemporaryMoveSuggestion(
            inputConnectors: try suggest(
                count: homeInputs.count,
                range: StudioHomeConnections.inputRange,
                reserved: reservations.inputs,
                direction: "input"
            ),
            outputConnectors: try suggest(
                count: homeOutputs.count,
                range: StudioHomeConnections.outputRange,
                reserved: reservations.outputs,
                direction: "output"
            )
        )
    }

    static func validate(
        _ move: TemporaryDeviceMove,
        home: StudioHomeConnections,
        equipment: [Equipment],
        existingMoves: [TemporaryDeviceMove]
    ) throws {
        let device = try device(move.equipmentID, equipment: equipment)
        if existingMoves.contains(where: {
            $0.id != move.id && $0.equipmentID == move.equipmentID
        }) {
            throw TemporaryMoveConflict.alreadyMoving(device.name)
        }
        let reservations = reservations(home: home, moves: existingMoves, excluding: move.equipmentID)
        try validate(
            move.connections.inputs.map(\.connector),
            range: StudioHomeConnections.inputRange,
            reserved: reservations.inputs,
            duplicate: TemporaryMoveConflict.duplicateInputConnector,
            occupied: TemporaryMoveConflict.inputConnectorInUse,
            invalid: TemporaryMoveConflict.invalidInputConnector
        )
        try validate(
            move.connections.outputs.map(\.connector),
            range: StudioHomeConnections.outputRange,
            reserved: reservations.outputs,
            duplicate: TemporaryMoveConflict.duplicateOutputConnector,
            occupied: TemporaryMoveConflict.outputConnectorInUse,
            invalid: TemporaryMoveConflict.invalidOutputConnector
        )
    }

    private static func device(_ id: Equipment.ID, equipment: [Equipment]) throws -> Equipment {
        guard let device = equipment.first(where: { $0.id == id }) else {
            throw TemporaryMoveConflict.missingEquipment
        }
        return device
    }

    private static func inputs(
        for equipmentID: Equipment.ID,
        in home: StudioHomeConnections
    ) -> [StudioInputConnection] {
        home.inputs.filter { $0.equipmentID == equipmentID }.sorted { $0.outputPort < $1.outputPort }
    }

    private static func outputs(
        for equipmentID: Equipment.ID,
        in home: StudioHomeConnections
    ) -> [StudioOutputConnection] {
        home.outputs.filter { $0.equipmentID == equipmentID }.sorted { $0.inputPort < $1.inputPort }
    }

    private static func reservations(
        home: StudioHomeConnections,
        moves: [TemporaryDeviceMove],
        excluding equipmentID: Equipment.ID
    ) -> (inputs: Set<Int>, outputs: Set<Int>) {
        let movingIDs = Set(moves.map(\.equipmentID)).union([equipmentID])
        var inputs = Set(home.inputs.filter { !movingIDs.contains($0.equipmentID) }.map(\.connector))
        var outputs = Set(home.outputs.filter { !movingIDs.contains($0.equipmentID) }.map(\.connector))
        for move in moves where move.equipmentID != equipmentID {
            inputs.formUnion(move.connections.inputs.map(\.connector))
            outputs.formUnion(move.connections.outputs.map(\.connector))
        }
        return (inputs, outputs)
    }

    private static func suggest(
        count: Int,
        range: ClosedRange<Int>,
        reserved: Set<Int>,
        direction: String
    ) throws -> [Int] {
        guard count > 0 else { return [] }
        let free = range.filter { !reserved.contains($0) }
        guard free.count >= count else {
            throw TemporaryMoveConflict.insufficientFreeConnectors(
                direction: direction,
                required: count,
                available: free.count
            )
        }
        if count > 1 {
            for start in range where start + count - 1 <= range.upperBound {
                let candidate = Array(start..<(start + count))
                if candidate.allSatisfy({ !reserved.contains($0) }) {
                    return candidate
                }
            }
        }
        return Array(free.prefix(count))
    }

    // Direction-specific conflict constructors keep validation messages precise.
    // swiftlint:disable:next function_parameter_count
    private static func validate(
        _ connectors: [Int],
        range: ClosedRange<Int>,
        reserved: Set<Int>,
        duplicate: (Int) -> TemporaryMoveConflict,
        occupied: (Int) -> TemporaryMoveConflict,
        invalid: (Int) -> TemporaryMoveConflict
    ) throws {
        var seen: Set<Int> = []
        for connector in connectors {
            guard range.contains(connector) else { throw invalid(connector) }
            guard seen.insert(connector).inserted else { throw duplicate(connector) }
            guard !reserved.contains(connector) else { throw occupied(connector) }
        }
    }
}

extension GlobalStudioConnections {
    var effectiveHome: StudioHomeConnections {
        applyingTemporaryMoves(temporaryMoves.filter { $0.lifecycle.isEffective })
    }

    func effectiveHome(removing moveID: TemporaryDeviceMove.ID) -> StudioHomeConnections {
        applyingTemporaryMoves(temporaryMoves.filter { $0.id != moveID && $0.lifecycle.isEffective })
    }

    func effectiveHome(applying move: TemporaryDeviceMove) -> StudioHomeConnections {
        applyingTemporaryMoves(
            temporaryMoves.filter { $0.id != move.id && $0.lifecycle.isEffective }
                + [move.activating(with: move.verification)]
        )
    }

    func move(for equipmentID: Equipment.ID) -> TemporaryDeviceMove? {
        temporaryMoves.first { $0.equipmentID == equipmentID && $0.lifecycle.isTracked }
    }

    private func applyingTemporaryMoves(_ moves: [TemporaryDeviceMove]) -> StudioHomeConnections {
        var result = home
        for move in moves {
            result.inputs.removeAll { $0.equipmentID == move.equipmentID }
            result.outputs.removeAll { $0.equipmentID == move.equipmentID }
            result.inputs.append(contentsOf: move.connections.inputs)
            result.outputs.append(contentsOf: move.connections.outputs)
        }
        result.inputs.sort { $0.connector < $1.connector }
        result.outputs.sort { $0.connector < $1.connector }
        return result
    }
}
