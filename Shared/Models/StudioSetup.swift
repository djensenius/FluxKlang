//
//  StudioSetup.swift
//  FluxKlang
//
//  Semantic studio setup models: what role each piece of gear plays and where
//  its physical ports are plugged into the WING. This is the source material for
//  the future setup wizard and for compiling a user-drawn studio graph without
//  exposing channels, buses or connector groups in the primary workflow.
//

import Foundation

enum StudioDeviceRole: String, Codable, Hashable, Sendable, CaseIterable {
    case instrument
    case outboardEffect
    case speaker
    case output
    case utility
}

enum StudioDeviceRef: Codable, Hashable, Sendable {
    case equipment(Equipment.ID)
    case effect(Effect.ID)
}

enum StudioConnector: Codable, Hashable, Sendable {
    /// A device output physically plugged into a WING input source.
    case wingInput(WingSource)
    /// A WING local physical output feeding a device input.
    case wingOutput(Int)
}

struct StudioPortPatch: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var device: StudioDeviceRef
    var side: StudioPortSide
    var port: Int
    var connector: StudioConnector

    init(
        id: UUID = UUID(),
        device: StudioDeviceRef,
        side: StudioPortSide,
        port: Int,
        connector: StudioConnector
    ) {
        self.id = id
        self.device = device
        self.side = side
        self.port = port
        self.connector = connector
    }
}

struct StudioDeviceProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var device: StudioDeviceRef
    var name: String
    var role: StudioDeviceRole
    var patches: [StudioPortPatch]

    init(
        id: UUID = UUID(),
        device: StudioDeviceRef,
        name: String,
        role: StudioDeviceRole,
        patches: [StudioPortPatch] = []
    ) {
        self.id = id
        self.device = device
        self.name = name
        self.role = role
        self.patches = patches
    }
}

struct StudioSetup: Codable, Hashable, Sendable {
    var devices: [StudioDeviceProfile]

    init(devices: [StudioDeviceProfile] = []) {
        self.devices = devices
    }

    func profile(for device: StudioDeviceRef) -> StudioDeviceProfile? {
        devices.first { $0.device == device }
    }

    /// Seed a setup from the current equipment library and its canonical channel
    /// order. This is intentionally conservative: it records instrument outputs
    /// plugged into local WING inputs, leaving effect input/output jacks for the
    /// setup wizard or WING-name inference to confirm.
    static func inferredFromEquipment(_ equipment: [Equipment]) -> StudioSetup {
        var profiles: [StudioDeviceProfile] = []
        for assignment in Equipment.channelAssignments(from: equipment) {
            let device = StudioDeviceRef.equipment(assignment.equipment.id)
            var patches = [
                StudioPortPatch(
                    device: device,
                    side: .output,
                    port: 0,
                    connector: .wingInput(WingSource(group: .local, index: assignment.leftChannel))
                )
            ]
            if let right = assignment.rightChannel {
                patches.append(StudioPortPatch(
                    device: device,
                    side: .output,
                    port: 1,
                    connector: .wingInput(WingSource(group: .local, index: right))
                ))
            }
            profiles.append(StudioDeviceProfile(
                device: device,
                name: assignment.equipment.name,
                role: .instrument,
                patches: patches
            ))
        }
        return StudioSetup(devices: profiles)
    }
}
