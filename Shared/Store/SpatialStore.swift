//
//  SpatialStore.swift
//  FluxKlang
//
//  Owns the speaker layout and the placed spatial sources, persisting both to
//  disk. The actual WING sends are driven by `AppModel` using `SpatialPanner`;
//  this store only holds the user's configuration.
//

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class SpatialStore {
    private(set) var array: SpeakerArray = .standardQuad
    private(set) var sources: [SpatialSource] = []

    private let fileName = "spatial.json"
    private var loaded = false

    private struct Persisted: Codable, Sendable {
        var array: SpeakerArray
        var sources: [SpatialSource]
    }

    /// Loads the persisted configuration once, seeding believable defaults on
    /// first launch so the spatial screens are populated (including in demo).
    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load(Persisted.self, from: fileName) {
            array = saved.array
            sources = saved.sources
        } else {
            sources = Self.defaultSources
            persist()
        }
    }

    // MARK: - Sources

    func addSource(_ source: SpatialSource) {
        sources.append(source)
        persist()
    }

    func removeSource(_ identifier: SpatialSource.ID) {
        sources.removeAll { $0.id == identifier }
        persist()
    }

    func updatePosition(_ identifier: SpatialSource.ID, to position: CGPoint) {
        guard let index = sources.firstIndex(where: { $0.id == identifier }) else { return }
        sources[index].position = clamp(position)
        persist()
    }

    func updateWidth(_ identifier: SpatialSource.ID, to width: Double) {
        guard let index = sources.firstIndex(where: { $0.id == identifier }) else { return }
        sources[index].width = min(max(width, 0), 1)
        persist()
    }

    func rename(_ identifier: SpatialSource.ID, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == identifier }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sources[index].name = trimmed
        persist()
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
        let snapshot = Persisted(array: array, sources: sources)
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }

    /// First-launch sources mapped onto the gear rig's channel layout, including
    /// stereo instruments (two consecutive channels) and a mono one.
    private static var defaultSources: [SpatialSource] {
        [
            SpatialSource(
                name: "OP-1 Field",
                mode: .stereo,
                left: .channel(1),
                right: .channel(2),
                position: CGPoint(x: 0.3, y: 0.3),
                width: 0.5
            ),
            SpatialSource(
                name: "OP-XY",
                mode: .stereo,
                left: .channel(3),
                right: .channel(4),
                position: CGPoint(x: 0.7, y: 0.35),
                width: 0.5
            ),
            SpatialSource(
                name: "Torso S-4",
                mode: .stereo,
                left: .channel(11),
                right: .channel(12),
                position: CGPoint(x: 0.5, y: 0.72),
                width: 0.7
            ),
            SpatialSource(name: "MicroFreak", left: .channel(33), position: CGPoint(x: 0.5, y: 0.45))
        ]
    }
}
