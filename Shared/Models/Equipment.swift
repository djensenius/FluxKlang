//
//  Equipment.swift
//  FluxKlang
//
//  User gear modelled for the signal-chain builder: a named device with input
//  and output ports, and whether it is a stereo device. The library is seeded
//  with the user's known instruments and is editable. The seeded library doubles
//  as the canonical channel rig: it drives the default fader bank and the demo's
//  channel naming, so a stereo device occupies two consecutive WING channels.
//

import Foundation

struct Equipment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var inputs: [String]
    var outputs: [String]
    /// Whether the device is a stereo source (occupies two WING channels). Mono
    /// devices occupy a single channel.
    var isStereo: Bool

    init(
        id: UUID = UUID(),
        name: String,
        inputs: [String] = [],
        outputs: [String] = ["Out"],
        isStereo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.inputs = inputs
        self.outputs = outputs
        self.isStereo = isStereo
    }

    // Custom decoder keeps older saved equipment.json files (which predate
    // `isStereo`) loadable: a missing flag is inferred from the output count.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        inputs = try container.decodeIfPresent([String].self, forKey: .inputs) ?? []
        outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? ["Out"]
        isStereo = try container.decodeIfPresent(Bool.self, forKey: .isStereo) ?? (outputs.count >= 2)
    }
}

extension Equipment {
    /// The user's known gear, used to seed the equipment library. This is also
    /// the canonical channel rig (see `channelAssignments()`): every device is
    /// stereo except the two mono boxes — the Arturia MicroFreak and SOMA Lyra-8.
    static var seededLibrary: [Equipment] {
        [
            Equipment(name: "OP-1 Field", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "OP-XY", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "TX-6", inputs: ["In 1", "In 2"], outputs: ["Main L", "Main R"], isStereo: true),
            Equipment(name: "TP-7", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "CM-15", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "Torso S-4", inputs: ["Audio In"], outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "Elta SOLAR 42F", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "Endorphin.es EviL Pet", inputs: ["In"], outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "SOMA Cosmos", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "SOMA Ether", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "SOMA Flux", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "SOMA Pipe", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "OXI One", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "OXI E16", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(name: "Buchla Ziggy", outputs: ["Out L", "Out R"], isStereo: true),
            Equipment(
                name: "Hologram Microcosm",
                inputs: ["In L", "In R"], outputs: ["Out L", "Out R"], isStereo: true
            ),
            Equipment(name: "Arturia MicroFreak", outputs: ["Out"], isStereo: false),
            Equipment(name: "SOMA Lyra-8", outputs: ["Out"], isStereo: false)
        ]
    }

    /// Left/right output port labels for a stereo device, falling back to
    /// synthesised "<base> L/R" labels when explicit ones aren't present.
    func stereoPorts() -> (left: String, right: String) {
        if outputs.count >= 2 {
            return (outputs[0], outputs[1])
        }
        let base = outputs.first ?? "Out"
        return ("\(base) L", "\(base) R")
    }

    /// One device laid out across one or two consecutive WING channels.
    struct ChannelAssignment: Identifiable, Hashable, Sendable {
        var equipment: Equipment
        /// The first (or only) WING channel number, 1-based.
        var leftChannel: Int
        /// The second WING channel for stereo devices; `nil` for mono.
        var rightChannel: Int?

        var id: UUID { equipment.id }
        var isStereo: Bool { rightChannel != nil }
    }

    /// Lays the seeded gear across WING channels in library order: a stereo
    /// device takes two consecutive channels (L, R); a mono device takes one.
    /// This is the single source of truth consumed by both the default fader
    /// bank and the demo simulator's channel naming.
    static func channelAssignments(
        from library: [Equipment] = Equipment.seededLibrary
    ) -> [ChannelAssignment] {
        var assignments: [ChannelAssignment] = []
        var channel = 1
        for device in library {
            if device.isStereo {
                assignments.append(
                    ChannelAssignment(equipment: device, leftChannel: channel, rightChannel: channel + 1)
                )
                channel += 2
            } else {
                assignments.append(
                    ChannelAssignment(equipment: device, leftChannel: channel, rightChannel: nil)
                )
                channel += 1
            }
        }
        return assignments
    }
}
