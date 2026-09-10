//  Canonical Home wiring plus non-destructive temporary overlays.
//

import Foundation
struct StudioInputConnection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var connector: Int
    var equipmentID: Equipment.ID
    var outputPort: Int
    var labelOverride: String?

    init(
        id: UUID = UUID(),
        connector: Int,
        equipmentID: Equipment.ID,
        outputPort: Int,
        labelOverride: String? = nil
    ) {
        self.id = id
        self.connector = connector
        self.equipmentID = equipmentID
        self.outputPort = outputPort
        self.labelOverride = labelOverride
    }

    func label(equipment: [Equipment]) -> String {
        if let labelOverride, !labelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return labelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let device = equipment.first(where: { $0.id == equipmentID }) else {
            return "Unknown equipment"
        }
        let port = device.outputs.indices.contains(outputPort) ? device.outputs[outputPort] : "Output \(outputPort + 1)"
        return "\(device.name) · \(port)"
    }
}
struct StudioOutputConnection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var connector: Int
    var equipmentID: Equipment.ID
    var inputPort: Int
    var labelOverride: String?

    init(
        id: UUID = UUID(),
        connector: Int,
        equipmentID: Equipment.ID,
        inputPort: Int,
        labelOverride: String? = nil
    ) {
        self.id = id
        self.connector = connector
        self.equipmentID = equipmentID
        self.inputPort = inputPort
        self.labelOverride = labelOverride
    }

    func label(equipment: [Equipment]) -> String {
        if let labelOverride, !labelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return labelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let device = equipment.first(where: { $0.id == equipmentID }) else {
            return "Unknown equipment"
        }
        let port = device.inputs.indices.contains(inputPort) ? device.inputs[inputPort] : "Input \(inputPort + 1)"
        return "\(device.name) · \(port)"
    }
}

struct StudioHomeConnections: Codable, Hashable, Sendable {
    static let inputRange = 1...24
    static let outputRange = 1...8

    var inputs: [StudioInputConnection]
    var outputs: [StudioOutputConnection]

    init(inputs: [StudioInputConnection] = [], outputs: [StudioOutputConnection] = []) {
        self.inputs = inputs
        self.outputs = outputs
    }

    var isEmpty: Bool { inputs.isEmpty && outputs.isEmpty }
}

struct StudioConnectionMigrationIssue: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var environmentID: RoutingEnvironment.ID
    var deviceName: String
    var message: String

    init(
        id: UUID = UUID(),
        environmentID: RoutingEnvironment.ID,
        deviceName: String,
        message: String
    ) {
        self.id = id
        self.environmentID = environmentID
        self.deviceName = deviceName
        self.message = message
    }
}

struct GlobalStudioConnections: Codable, Hashable, Sendable {
    var home: StudioHomeConnections
    var temporaryMoves: [TemporaryDeviceMove]
    var migrationIssues: [StudioConnectionMigrationIssue]

    init(
        home: StudioHomeConnections = StudioHomeConnections(),
        temporaryMoves: [TemporaryDeviceMove] = [],
        migrationIssues: [StudioConnectionMigrationIssue] = []
    ) {
        self.home = home
        self.temporaryMoves = temporaryMoves
        self.migrationIssues = migrationIssues
    }

    var isEmpty: Bool { home.isEmpty && temporaryMoves.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case home, temporaryMoves, migrationIssues
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = try container.decodeIfPresent(StudioHomeConnections.self, forKey: .home) ?? StudioHomeConnections()
        temporaryMoves = try container.decodeIfPresent(
            [TemporaryDeviceMove].self,
            forKey: .temporaryMoves
        ) ?? []
        migrationIssues = try container.decodeIfPresent(
            [StudioConnectionMigrationIssue].self,
            forKey: .migrationIssues
        ) ?? []
    }

    static func migratingLegacy(
        environments: [RoutingEnvironment],
        activeID: RoutingEnvironment.ID?,
        equipment: [Equipment]
    ) -> GlobalStudioConnections {
        let ordered = legacySourceOrder(environments, activeID: activeID)
        guard let source = ordered.first(where: { !$0.studioSetup.devices.flatMap(\.patches).isEmpty }) else {
            return GlobalStudioConnections()
        }

        let equipmentByID = Dictionary(equipment.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let effectsByID = Dictionary(source.effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var context = LegacyMigrationContext(
            source: source,
            equipment: equipment,
            equipmentByID: equipmentByID,
            effectsByID: effectsByID
        )
        for profile in source.studioSetup.devices {
            context.migrate(profile)
        }
        return GlobalStudioConnections(
            home: StudioHomeConnections(inputs: context.inputs, outputs: context.outputs),
            migrationIssues: context.issues
        )
    }

    private static func legacySourceOrder(
        _ environments: [RoutingEnvironment],
        activeID: RoutingEnvironment.ID?
    ) -> [RoutingEnvironment] {
        guard let activeID,
              let active = environments.first(where: { $0.id == activeID }) else {
            return environments
        }
        return [active] + environments.filter { $0.id != activeID }
    }

    private static func resolveLegacyDevice(
        profile: StudioDeviceProfile,
        equipment: [Equipment],
        equipmentByID: [Equipment.ID: Equipment],
        effectsByID: [Effect.ID: Effect]
    ) -> Equipment.ID? {
        switch profile.device {
        case .equipment(let id):
            if equipmentByID[id] != nil { return id }
        case .effect(let id):
            if let linked = effectsByID[id]?.equipmentID, equipmentByID[linked] != nil { return linked }
            if equipmentByID[id] != nil { return id }
        }
        let matches = equipment.filter { normalized($0.name) == normalized(profile.name) }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct LegacyMigrationContext {
        var source: RoutingEnvironment
        var equipment: [Equipment]
        var equipmentByID: [Equipment.ID: Equipment]
        var effectsByID: [Effect.ID: Effect]
        var inputs: [StudioInputConnection] = []
        var outputs: [StudioOutputConnection] = []
        var issues: [StudioConnectionMigrationIssue] = []

        mutating func migrate(_ profile: StudioDeviceProfile) {
            guard let equipmentID = GlobalStudioConnections.resolveLegacyDevice(
                profile: profile,
                equipment: equipment,
                equipmentByID: equipmentByID,
                effectsByID: effectsByID
            ) else {
                for _ in profile.patches {
                    issues.append(StudioConnectionMigrationIssue(
                        environmentID: source.id,
                        deviceName: profile.name,
                        message: "Could not match this legacy device to global Equipment."
                    ))
                }
                return
            }
            for patch in profile.patches {
                migrate(patch, profile: profile, equipmentID: equipmentID)
            }
        }

        private mutating func migrate(
            _ patch: StudioPortPatch,
            profile: StudioDeviceProfile,
            equipmentID: Equipment.ID
        ) {
            switch (patch.side, patch.connector) {
            case (.output, .wingInput(let sourceInput)) where sourceInput.group == .local:
                inputs.append(StudioInputConnection(
                    connector: sourceInput.index,
                    equipmentID: equipmentID,
                    outputPort: patch.port
                ))
            case (.input, .wingOutput(let connector)):
                outputs.append(StudioOutputConnection(
                    connector: connector,
                    equipmentID: equipmentID,
                    inputPort: patch.port
                ))
            default:
                issues.append(StudioConnectionMigrationIssue(
                    environmentID: source.id,
                    deviceName: profile.name,
                    message: "Legacy patch \(patch.id) is not a local WING input/output assignment."
                ))
            }
        }
    }
}

struct StudioConnectionIssue: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case duplicateInputConnector(Int)
        case duplicateOutputConnector(Int)
        case inputConnectorOutOfRange(Int)
        case outputConnectorOutOfRange(Int)
        case missingEquipment(Equipment.ID)
        case invalidOutputPort(Equipment.ID, Int)
        case invalidInputPort(Equipment.ID, Int)
        case conflictingOutputPort(Equipment.ID, Int)
        case conflictingInputPort(Equipment.ID, Int)
        case unconfiguredInstrument(Equipment.ID)
        case missingStereoInputLeg(Equipment.ID)
        case unlinkedEffect(Effect.ID)
        case unconfiguredEffectInput(Effect.ID)
        case unconfiguredEffectOutput(Effect.ID)
    }

    var kind: Kind
    var message: String
    var id: String { kind.stableID }
}

struct StudioPhysicalResolver {
    private struct PortKey: Hashable {
        var equipmentID: Equipment.ID
        var port: Int
    }

    private let connections: StudioHomeConnections
    private let equipmentByID: [Equipment.ID: Equipment]

    init(connections: StudioHomeConnections, equipment: [Equipment]) {
        self.connections = connections
        equipmentByID = Dictionary(equipment.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func structuralIssues() -> [StudioConnectionIssue] {
        unique(connectorIssues() + inputIssues() + outputIssues() + conflictIssues())
    }

    private func connectorIssues() -> [StudioConnectionIssue] {
        var issues: [StudioConnectionIssue] = []
        let inputGroups = Dictionary(grouping: connections.inputs, by: \.connector)
        let outputGroups = Dictionary(grouping: connections.outputs, by: \.connector)
        for (connector, values) in inputGroups where values.count > 1 {
            issues.append(.init(
                kind: .duplicateInputConnector(connector),
                message: "WING input \(connector) has multiple assignments."
            ))
        }
        for (connector, values) in outputGroups where values.count > 1 {
            issues.append(.init(
                kind: .duplicateOutputConnector(connector),
                message: "WING output \(connector) has multiple assignments."
            ))
        }
        return issues
    }

    private func inputIssues() -> [StudioConnectionIssue] {
        var issues: [StudioConnectionIssue] = []
        for connection in connections.inputs {
            if !StudioHomeConnections.inputRange.contains(connection.connector) {
                issues.append(.init(
                    kind: .inputConnectorOutOfRange(connection.connector),
                    message: "WING input \(connection.connector) is outside 1...24."
                ))
            }
            guard let device = equipmentByID[connection.equipmentID] else {
                issues.append(.init(
                    kind: .missingEquipment(connection.equipmentID),
                    message: "An input assignment points at missing Equipment."
                ))
                continue
            }
            if !device.outputs.indices.contains(connection.outputPort) {
                issues.append(.init(
                    kind: .invalidOutputPort(device.id, connection.outputPort),
                    message: "\(device.name) output \(connection.outputPort + 1) does not exist."
                ))
            }
        }
        return issues
    }

    private func outputIssues() -> [StudioConnectionIssue] {
        var issues: [StudioConnectionIssue] = []
        for connection in connections.outputs {
            if !StudioHomeConnections.outputRange.contains(connection.connector) {
                issues.append(.init(
                    kind: .outputConnectorOutOfRange(connection.connector),
                    message: "WING output \(connection.connector) is outside 1...8."
                ))
            }
            guard let device = equipmentByID[connection.equipmentID] else {
                issues.append(.init(
                    kind: .missingEquipment(connection.equipmentID),
                    message: "An output assignment points at missing Equipment."
                ))
                continue
            }
            if !device.inputs.indices.contains(connection.inputPort) {
                issues.append(.init(
                    kind: .invalidInputPort(device.id, connection.inputPort),
                    message: "\(device.name) input \(connection.inputPort + 1) does not exist."
                ))
            }
        }
        return issues
    }

    private func conflictIssues() -> [StudioConnectionIssue] {
        var issues: [StudioConnectionIssue] = []
        for (key, values) in Dictionary(
            grouping: connections.inputs,
            by: { PortKey(equipmentID: $0.equipmentID, port: $0.outputPort) }
        ) where values.count > 1 {
            let device = equipmentByID[key.equipmentID]
            let port = device?.outputs.indices.contains(key.port) == true
                ? device?.outputs[key.port] ?? "Output \(key.port + 1)"
                : "Output \(key.port + 1)"
            let connectors = values.map(\.connector).sorted().map(String.init).joined(separator: ", ")
            issues.append(.init(
                kind: .conflictingOutputPort(key.equipmentID, key.port),
                message: "\(device?.name ?? "Equipment") · \(port) is assigned to WING inputs \(connectors)."
            ))
        }
        for (key, values) in Dictionary(
            grouping: connections.outputs,
            by: { PortKey(equipmentID: $0.equipmentID, port: $0.inputPort) }
        ) where values.count > 1 {
            let device = equipmentByID[key.equipmentID]
            let port = device?.inputs.indices.contains(key.port) == true
                ? device?.inputs[key.port] ?? "Input \(key.port + 1)"
                : "Input \(key.port + 1)"
            let connectors = values.map(\.connector).sorted().map(String.init).joined(separator: ", ")
            issues.append(.init(
                kind: .conflictingInputPort(key.equipmentID, key.port),
                message: "\(device?.name ?? "Equipment") · \(port) is assigned to WING outputs \(connectors)."
            ))
        }
        return issues
    }

    func instrumentChannels(_ equipmentID: Equipment.ID) -> StudioInstrumentPhysicalRouting {
        guard let device = equipmentByID[equipmentID] else {
            return StudioInstrumentPhysicalRouting(issues: [.init(
                kind: .missingEquipment(equipmentID),
                message: "Gear in the studio graph no longer exists."
            )])
        }
        let neededPorts = device.isStereo ? [0, 1] : [0]
        let matches = connections.inputs.filter {
            $0.equipmentID == equipmentID && neededPorts.contains($0.outputPort)
        }
        guard neededPorts.allSatisfy({ port in matches.filter { $0.outputPort == port }.count == 1 }) else {
            let kind: StudioConnectionIssue.Kind = device.isStereo && !matches.isEmpty
                ? .missingStereoInputLeg(equipmentID)
                : .unconfiguredInstrument(equipmentID)
            return StudioInstrumentPhysicalRouting(issues: [.init(
                kind: kind,
                message: "\(device.name) does not have every required output connected to a local input."
            )])
        }
        let ordered = neededPorts.compactMap { port in matches.first { $0.outputPort == port } }
        let channels = ordered.map(\.connector)
        let settings = channels.flatMap { connector in
            WingSource(group: .local, index: connector).settings(forChannel: connector)
        }
        return StudioInstrumentPhysicalRouting(channels: channels, settings: settings)
    }

    func effectJacks(_ effect: Effect) -> StudioEffectPhysicalJacks {
        guard let equipmentID = effect.equipmentID,
              let device = equipmentByID[equipmentID] else {
            return StudioEffectPhysicalJacks(issues: [.init(
                kind: .unlinkedEffect(effect.id),
                message: "\(effect.name) is not linked to global Equipment."
            )])
        }
        let neededPorts = effect.isStereo ? [0, 1] : [0]
        let sends = connections.outputs.filter {
            $0.equipmentID == equipmentID && neededPorts.contains($0.inputPort)
        }
        let returns = connections.inputs.filter {
            $0.equipmentID == equipmentID && neededPorts.contains($0.outputPort)
        }
        var issues: [StudioConnectionIssue] = []
        if !neededPorts.allSatisfy({ port in sends.filter { $0.inputPort == port }.count == 1 }) {
            issues.append(.init(
                kind: .unconfiguredEffectInput(effect.id),
                message: "\(device.name) does not have every required input connected to a local output."
            ))
        }
        if !neededPorts.allSatisfy({ port in returns.filter { $0.outputPort == port }.count == 1 }) {
            issues.append(.init(
                kind: .unconfiguredEffectOutput(effect.id),
                message: "\(device.name) does not have every required output connected to a local input."
            ))
        }
        let inputJacks = neededPorts.compactMap { port in sends.first { $0.inputPort == port }?.connector }
        let outputJacks = neededPorts.compactMap { port in returns.first { $0.outputPort == port }?.connector }
        return StudioEffectPhysicalJacks(inputJacks: inputJacks, outputJacks: outputJacks, issues: issues)
    }

    private func unique(_ issues: [StudioConnectionIssue]) -> [StudioConnectionIssue] {
        var seen: Set<StudioConnectionIssue.Kind> = []
        return issues.filter { seen.insert($0.kind).inserted }
    }
}

struct StudioInstrumentPhysicalRouting {
    var channels: [Int]
    var settings: [WingSetting]
    var issues: [StudioConnectionIssue]

    init(
        channels: [Int] = [],
        settings: [WingSetting] = [],
        issues: [StudioConnectionIssue] = []
    ) {
        self.channels = channels
        self.settings = settings
        self.issues = issues
    }
}

struct StudioEffectPhysicalJacks {
    /// WING local outputs feeding the effect inputs.
    var inputJacks: [Int]
    /// WING local inputs receiving the effect outputs.
    var outputJacks: [Int]
    var issues: [StudioConnectionIssue]

    init(
        inputJacks: [Int] = [],
        outputJacks: [Int] = [],
        issues: [StudioConnectionIssue] = []
    ) {
        self.inputJacks = inputJacks
        self.outputJacks = outputJacks
        self.issues = issues
    }
}
