//
//  StudioPhysicalTypes.swift
//  FluxKlang
//

import Foundation

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

enum WingOutputConnectorBank: String, CaseIterable, Codable, Hashable, Sendable {
    case local = "LCL"
    case aes50A = "A"
    case aes50B = "B"
    case aes50C = "C"

    var label: String {
        switch self {
        case .local: "Local"
        case .aes50A: "AES50-A"
        case .aes50B: "AES50-B"
        case .aes50C: "AES50-C"
        }
    }

    var connectorRange: ClosedRange<Int> {
        switch self {
        case .local: 1...8
        case .aes50A, .aes50B, .aes50C: 1...16
        }
    }
}

struct WingOutputConnector: Codable, Hashable, Sendable {
    var bank: WingOutputConnectorBank
    var index: Int

    init(bank: WingOutputConnectorBank = .local, index: Int) {
        self.bank = bank
        self.index = index
    }

    var label: String {
        bank == .local ? "LCL \(index)" : "\(bank.label) \(index)"
    }
}

struct StudioConnectionIssue: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case duplicateInputConnector(Int)
        case duplicateOutputConnector(Int)
        case duplicateBankOutputConnector(WingOutputConnectorBank, Int)
        case inputConnectorOutOfRange(Int)
        case outputConnectorOutOfRange(Int)
        case bankOutputConnectorOutOfRange(WingOutputConnectorBank, Int)
        case missingEquipment(Equipment.ID)
        case invalidOutputPort(Equipment.ID, Int)
        case invalidInputPort(Equipment.ID, Int)
        case invalidOutputDestination(WingOutputConnectorBank, Int)
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
    var inputJacks: [WingOutputConnector]
    var outputJacks: [Int]
    var issues: [StudioConnectionIssue]

    init(
        inputJacks: [WingOutputConnector] = [],
        outputJacks: [Int] = [],
        issues: [StudioConnectionIssue] = []
    ) {
        self.inputJacks = inputJacks
        self.outputJacks = outputJacks
        self.issues = issues
    }
}
