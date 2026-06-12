//
//  EffectRow.swift
//  FluxKlang
//
//  A single row in the Environments screen's effect list: the effect's name,
//  how many instruments feed it, and a compact left-to-right summary of the
//  signal path (bus → output → input → destination) derived from `EffectRouting`.
//

import SwiftUI

struct EffectRow: View {
    let effect: Effect
    let allocation: EffectRouting.Allocation?
    let destinationName: String?
    let equipment: EquipmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(effect.name)
                    .font(.headline)
                Spacer()
                Text(effect.isStereo ? "Stereo" : "Mono")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(instrumentSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(routingSummary, systemImage: "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var instrumentSummary: String {
        let count = effect.sourceInstruments.count
        let prefix = count == 1 ? "1 instrument" : "\(count) instruments"
        guard let names = instrumentNames else { return prefix }
        return "\(prefix): \(names)"
    }

    private var instrumentNames: String? {
        let names = effect.sourceInstruments.compactMap { equipment.item($0)?.name }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    /// A compact left-to-right description of the signal path.
    private var routingSummary: String {
        let outs = effect.sendOutputs.map(String.init).joined(separator: "/")
        let ins = effect.returnInputs.map(String.init).joined(separator: "/")
        let destination = destinationName ?? "Main"
        guard let allocation, let bus = allocation.buses.first else {
            return "No free bus available"
        }
        let buses = effect.isStereo && allocation.buses.count > 1 ? "\(bus)/\(allocation.buses[1])" : "\(bus)"
        return "Bus \(buses) → Out \(outs) → In \(ins) → \(destination)"
    }
}
