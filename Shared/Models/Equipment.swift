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
            Equipment(
                id: UUID(uuidString: "8E4EB95D-B4E2-5BC0-A3E0-CDB27A4EFB7B")!,
                name: "OP-1 Field",
                inputs: ["In L", "In R"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "5A36E4F0-5657-57D4-968A-C5924485B4BA")!,
                name: "OP-XY",
                inputs: ["In L", "In R"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "5E785B3B-92A6-57F5-9652-EC3F768B0444")!,
                name: "TX-6",
                inputs: ["In 1", "In 2"],
                outputs: ["Main L", "Main R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "2DF38901-12D2-5FC0-96EF-26CBBF1D8377")!,
                name: "TP-7",
                inputs: ["In L", "In R"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "A60E6A8E-87DF-5DD1-BF60-43F40EA8741D")!,
                name: "CM-15",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "E2488132-69C7-588F-8A1F-2A648963A578")!,
                name: "Torso S-4",
                inputs: ["In L", "In R"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "406A0075-07E5-59B3-9DCC-6B87F07FAAC4")!,
                name: "Elta SOLAR 42F",
                inputs: ["In"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "23DEDC94-B7A2-52A7-B396-457DE5F25D92")!,
                name: "Endorphin.es EviL Pet",
                inputs: ["In L", "In R"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "794D7D73-C5E6-59E7-9155-F475CF61919D")!,
                name: "SOMA Cosmos",
                inputs: ["In L", "In R"],
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "189C1522-0A7B-5745-BE16-1F802F0668AA")!,
                name: "SOMA Ether",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "81AB0FE8-8D7D-50AB-9336-8D3E4507A313")!,
                name: "SOMA Flux",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "4258295C-3B18-5173-9458-A203DA7D8183")!,
                name: "SOMA Pipe",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "D38871F9-5745-5B97-A223-763839353072")!,
                name: "OXI One",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "025FA8B0-292A-58AA-BE10-C0E8327AA442")!,
                name: "OXI E16",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "96602002-B917-5913-9545-E75B16DCA9B0")!,
                name: "Buchla Ziggy",
                outputs: ["Out L", "Out R"],
                isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "6EF53D32-6D36-5F94-87D8-5888FCD0A093")!,
                name: "Hologram Microcosm",
                inputs: ["In L", "In R"], outputs: ["Out L", "Out R"], isStereo: true
            ),
            Equipment(
                id: UUID(uuidString: "C4D389E3-073C-574E-A684-E082E809E45C")!,
                name: "Arturia MicroFreak",
                outputs: ["Out"],
                isStereo: false
            ),
            Equipment(
                id: UUID(uuidString: "8A777206-29CA-543F-A8A3-51B77B48017B")!,
                name: "SOMA Lyra-8",
                outputs: ["Out"],
                isStereo: false
            )
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
