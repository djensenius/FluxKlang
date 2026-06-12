//
//  Effect.swift
//  FluxKlang
//
//  An outboard effect wired into the WING's physical I/O, modelled as an aux
//  send: instruments (channels) feed it via an auto-allocated bus that is
//  patched to the effect's input jack(s), and its processed output returns on
//  input jack(s) routed to a return channel. The user only ever picks which
//  instruments feed which effect; the bridging bus and return channel are
//  managed automatically by `EffectRouting`.
//

import Foundation

struct Effect: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Whether the effect is stereo: it uses a bus pair and two send/return jacks.
    var isStereo: Bool
    /// The WING physical output jack(s) the effect's input is plugged into. One
    /// entry for a mono effect, two (L, R) for a stereo effect.
    var sendOutputs: [Int]
    /// The WING physical input jack(s) the effect's processed output returns on.
    /// One entry for a mono effect, two (L, R) for a stereo effect.
    var returnInputs: [Int]
    /// The instruments (equipment) whose channels feed this effect.
    var sourceInstruments: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        isStereo: Bool = true,
        sendOutputs: [Int] = [1, 2],
        returnInputs: [Int] = [1, 2],
        sourceInstruments: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.isStereo = isStereo
        self.sendOutputs = sendOutputs
        self.returnInputs = returnInputs
        self.sourceInstruments = sourceInstruments
    }

    /// Whether `instrument` currently feeds this effect.
    func feeds(_ instrument: Equipment.ID) -> Bool {
        sourceInstruments.contains(instrument)
    }

    /// Returns a copy with `instrument` added to or removed from its sources.
    func togglingSource(_ instrument: Equipment.ID, _ isOn: Bool) -> Effect {
        var copy = self
        if isOn {
            if !copy.sourceInstruments.contains(instrument) {
                copy.sourceInstruments.append(instrument)
            }
        } else {
            copy.sourceInstruments.removeAll { $0 == instrument }
        }
        return copy
    }

    /// Returns a copy whose jack arrays are resized to match `isStereo`, so a
    /// stereo effect always has two send/return jacks and a mono effect one.
    func normalizingJacks() -> Effect {
        var copy = self
        let width = isStereo ? 2 : 1
        copy.sendOutputs = Self.resize(sendOutputs, to: width, default: 1)
        copy.returnInputs = Self.resize(returnInputs, to: width, default: 1)
        return copy
    }

    private static func resize(_ values: [Int], to width: Int, default fallback: Int) -> [Int] {
        var result = Array(values.prefix(width))
        while result.count < width {
            let next = (result.last ?? fallback) + 1
            result.append(next)
        }
        return result
    }
}
