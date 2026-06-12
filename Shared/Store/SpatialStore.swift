//
//  SpatialStore.swift
//  FluxKlang
//
//  Owns the speaker layout for surround / spatial mixing, persisting it to disk.
//  Where each voice sits in the field is saved per environment (see
//  `RoutingEnvironment.placements`); this store only holds the physical speaker
//  rig, which is shared across environments. The actual WING sends are driven by
//  `AppModel` using `SpatialRouting`.
//

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class SpatialStore {
    private(set) var array: SpeakerArray = .standardQuad

    private let fileName = "spatial.json"
    private var loaded = false

    private struct Persisted: Codable, Sendable {
        var array: SpeakerArray
    }

    /// Loads the persisted speaker layout once, falling back to the standard quad
    /// on first launch so the spatial screens are populated (including in demo).
    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load(Persisted.self, from: fileName) {
            array = saved.array
        } else {
            persist()
        }
    }

    /// Re-reads the persisted layout, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    // MARK: - Speakers

    func setSpeakerNode(_ identifier: Speaker.ID, to node: WingNodeRef) {
        guard let index = array.speakers.firstIndex(where: { $0.id == identifier }) else { return }
        array.speakers[index].node = node
        persist()
    }

    func setSpeakerName(_ identifier: Speaker.ID, to name: String) {
        guard let index = array.speakers.firstIndex(where: { $0.id == identifier }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        array.speakers[index].name = trimmed
        persist()
    }

    func setSpeakerPosition(_ identifier: Speaker.ID, to position: CGPoint) {
        guard let index = array.speakers.firstIndex(where: { $0.id == identifier }) else { return }
        array.speakers[index].position = clamp(position)
        persist()
    }

    func resetArray() {
        array = .standardQuad
        persist()
    }

    // MARK: - Helpers

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func persist() {
        let snapshot = Persisted(array: array)
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
