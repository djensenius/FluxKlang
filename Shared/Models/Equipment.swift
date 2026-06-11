//
//  Equipment.swift
//  FluxKlang
//
//  User gear modelled for the signal-chain builder: a named device with input
//  and output ports. The library is seeded with the user's known instruments and
//  is editable.
//

import Foundation

struct Equipment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var inputs: [String]
    var outputs: [String]

    init(id: UUID = UUID(), name: String, inputs: [String] = [], outputs: [String] = ["Out"]) {
        self.id = id
        self.name = name
        self.inputs = inputs
        self.outputs = outputs
    }
}

extension Equipment {
    /// The user's known gear, used to seed the equipment library.
    static var seededLibrary: [Equipment] {
        [
            Equipment(name: "OP-1 Field", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"]),
            Equipment(name: "OP-XY", outputs: ["Out L", "Out R"]),
            Equipment(name: "TX-6", inputs: ["In 1", "In 2"], outputs: ["Main L", "Main R"]),
            Equipment(name: "TP-7", inputs: ["In"], outputs: ["Out"]),
            Equipment(name: "CM-15", outputs: ["Out L", "Out R"]),
            Equipment(name: "Torso S-4", inputs: ["Audio In"], outputs: ["Out L", "Out R"]),
            Equipment(name: "Elta SOLAR 42F", outputs: ["Out"]),
            Equipment(name: "Endorphin.es EviL Pet", inputs: ["In"], outputs: ["Out L", "Out R"]),
            Equipment(name: "SOMA Cosmos", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"]),
            Equipment(name: "SOMA Ether", outputs: ["Out"]),
            Equipment(name: "SOMA Flux", outputs: ["Out"]),
            Equipment(name: "SOMA Pipe", outputs: ["Out"]),
            Equipment(name: "OXI One", outputs: ["Out L", "Out R"]),
            Equipment(name: "OXI E16", outputs: ["Out"]),
            Equipment(name: "Buchla Ziggy", outputs: ["Out L", "Out R"]),
            Equipment(name: "Hologram Microcosm", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"])
        ]
    }
}
