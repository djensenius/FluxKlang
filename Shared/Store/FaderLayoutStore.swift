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

    /// Re-reads the persisted layout, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    /// Adds a strip for `node` unless one already exists.
    func addStrip(_ node: WingNodeRef) {
        guard !layout.contains(node) else { return }
        layout.strips.append(FaderStrip(node: node))
        persist()
    }

    /// Adds a ganged stereo strip across `left` and `right` unless either channel
    /// already has a strip.
    func addStereoStrip(left: WingNodeRef, right: WingNodeRef, label: String? = nil) {
        guard !layout.contains(left), !layout.contains(right) else { return }
        layout.strips.append(FaderStrip(node: left, rightNode: right, customLabel: label))
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

    /// Resets the bank to the standard gear-rig layout plus the main fader.
    func resetToStandard() {
        layout = .standard
        persist()
    }

    private func persist() {
        let snapshot = layout
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
