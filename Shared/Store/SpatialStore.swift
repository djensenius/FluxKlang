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
    private let injectedStore: JSONFileStore?
    private var loaded = false
    @ObservationIgnored private var saveTail: Task<Void, Never>?

    init(store: JSONFileStore? = nil) {
        injectedStore = store
    }

    private struct Persisted: Codable, Sendable {
        var array: SpeakerArray
    }

    /// Loads the persisted speaker layout once, falling back to the standard quad
    /// on first launch so the spatial screens are populated (including in demo).
    func load() async {
        guard !loaded else { return }
        loaded = true
        let store = injectedStore ?? JSONFileStore.shared
        if let saved = await store.load(Persisted.self, from: fileName) {
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

    /// Awaits the tail captured when this MainActor method begins, including its predecessors.
    /// Does not await later producers, establish all-producer quiescence, coalesce concurrent
    /// loads, or guarantee durable persistence success: JSON saves are best-effort.
    /// Cancelling the waiter does not cancel the save chain.
    func awaitScheduledSavesSnapshot() async {
        let tail = saveTail
        await tail?.value
    }

    // MARK: - Helpers

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func persist() {
        let snapshot = Persisted(array: array)
        let fileName = fileName
        let injectedStore = injectedStore
        let previousTail = saveTail
        saveTail = Task {
            await previousTail?.value
            let store = injectedStore ?? JSONFileStore.shared
            await store.save(snapshot, to: fileName)
        }
    }
}
