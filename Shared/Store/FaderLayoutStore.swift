//
//  FaderLayoutStore.swift
//  FluxKlang
//
//  Owns the user's configurable fader bank and persists it to disk.
//

import Foundation
import Observation

@MainActor
@Observable
final class FaderLayoutStore {
    private(set) var layout: FaderLayout = .standard

    private let fileName = "fader-layout.json"
    private var loaded = false

    /// Loads the persisted layout once, falling back to the standard bank.
    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load(FaderLayout.self, from: fileName) {
            layout = saved
        }
    }

    /// Adds a strip for `node` unless one already exists.
    func addStrip(_ node: WingNodeRef) {
        guard !layout.contains(node) else { return }
        layout.strips.append(FaderStrip(node: node))
        persist()
    }

    func removeStrips(at offsets: IndexSet) {
        layout.strips.remove(atOffsets: offsets)
        persist()
    }

    func remove(_ strip: FaderStrip) {
        layout.strips.removeAll { $0.id == strip.id }
        persist()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        layout.strips.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    func setLabel(_ label: String?, for stripID: FaderStrip.ID) {
        guard let index = layout.strips.firstIndex(where: { $0.id == stripID }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        layout.strips[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        persist()
    }

    /// Resets the bank to the standard channels 1–16 plus main layout.
    func resetToStandard() {
        layout = .standard
        persist()
    }

    private func persist() {
        let snapshot = layout
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
