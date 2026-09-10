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
    /// Stable link to the physical Equipment whose ports are connected in the
    /// global Home wiring map. Older effects may remain unlinked until resolved.
    var equipmentID: Equipment.ID?
    /// Whether the effect is stereo: it uses a bus pair and two send/return jacks.
    var isStereo: Bool
    /// Legacy per-environment WING output jacks, retained for Codable and the
    /// existing environment-routing workflow. Studio compilation uses Home.
    var sendOutputs: [Int]
    /// Legacy per-environment WING return jacks. Studio compilation resolves the
    /// linked Equipment's output ports through the global Home wiring map.
    var returnInputs: [Int]
    /// The instruments (equipment) whose channels feed this effect.
    var sourceInstruments: [UUID]
    /// Where this effect's processed output goes. `nil` returns it to the main
    /// (a parallel send); a value feeds it into another effect's input instead,
    /// forming a serial chain (this effect -> that effect -> ... -> main).
    var destinationEffectID: Effect.ID?

    init(
        id: UUID = UUID(),
        name: String,
        equipmentID: Equipment.ID? = nil,
        isStereo: Bool = true,
        sendOutputs: [Int] = [1, 2],
        returnInputs: [Int] = [1, 2],
        sourceInstruments: [UUID] = [],
        destinationEffectID: Effect.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.equipmentID = equipmentID
        self.isStereo = isStereo
        self.sendOutputs = sendOutputs
        self.returnInputs = returnInputs
        self.sourceInstruments = sourceInstruments
        self.destinationEffectID = destinationEffectID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, equipmentID, isStereo, sendOutputs, returnInputs, sourceInstruments, destinationEffectID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        equipmentID = try container.decodeIfPresent(Equipment.ID.self, forKey: .equipmentID)
        isStereo = try container.decodeIfPresent(Bool.self, forKey: .isStereo) ?? true
        sendOutputs = try container.decodeIfPresent([Int].self, forKey: .sendOutputs) ?? [1, 2]
        returnInputs = try container.decodeIfPresent([Int].self, forKey: .returnInputs) ?? [1, 2]
        sourceInstruments = try container.decodeIfPresent([UUID].self, forKey: .sourceInstruments) ?? []
        destinationEffectID = try container.decodeIfPresent(Effect.ID.self, forKey: .destinationEffectID)
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

    /// WING physical output jacks available for an effect's send (1-based).
    static let outputRange = 1...8
    /// WING local input jacks available for an effect's return (1-based).
    static let inputRange = 1...WingSourceGroup.local.count

    /// Returns a copy whose jack arrays match `isStereo` — one jack for a mono
    /// effect, two for a stereo one — with every jack clamped to a valid socket
    /// and, for a stereo effect, the two legs forced onto distinct sockets so
    /// one leg can never silently overwrite the other when patched.
    func normalizingJacks() -> Effect {
        var copy = self
        copy.sendOutputs = Self.normalizedJacks(sendOutputs, stereo: isStereo, in: Self.outputRange)
        copy.returnInputs = Self.normalizedJacks(returnInputs, stereo: isStereo, in: Self.inputRange)
        return copy
    }

    private static func normalizedJacks(_ values: [Int], stereo: Bool, in range: ClosedRange<Int>) -> [Int] {
        let left = clamp(values.first ?? range.lowerBound, to: range)
        guard stereo else { return [left] }
        var right = clamp(values.count > 1 ? values[1] : left + 1, to: range)
        if right == left {
            right = left < range.upperBound ? left + 1 : left - 1
        }
        return [left, right]
    }

    /// Clamps `value` into `range`.
    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Effect {
    /// Conservatively links a legacy effect to Equipment by exact ID first, then
    /// by a unique case-insensitive name. Ambiguous or absent matches stay nil.
    func migratingEquipmentLink(in equipment: [Equipment]) -> Effect {
        guard equipmentID == nil else { return self }
        var copy = self
        if equipment.contains(where: { $0.id == id }) {
            copy.equipmentID = id
            return copy
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = equipment.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }
        if matches.count == 1 {
            copy.equipmentID = matches[0].id
        }
        return copy
    }
}
