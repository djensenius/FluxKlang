//
//  SpatialPadView.swift
//  FluxKlang
//
//  A 2D placement pad for an environment's voices: speakers are fixed markers,
//  voices are draggable pucks. Dragging a puck saves its position in the active
//  environment and pushes the recomputed DBAP speaker-bus sends to the WING live
//  (throttled), committing when the drag ends. Voices not yet placed sit at the
//  centre, dimmed, until first moved. Stereo voices render their two channels
//  spread by the voice width; shared effect returns are tagged so it's clear
//  their bundled sources move together.
//

import SwiftUI

struct SpatialPadView: View {
    let appModel: AppModel
    let voices: [PlacedVoice]
    @Binding var selection: String?

    private let inset: CGFloat = 26
    @State private var dragOverrides: [String: CGPoint] = [:]
    @State private var lastPush = Date.distantPast

    private var store: EnvironmentStore { appModel.environments }

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local).insetBy(dx: inset, dy: inset)
            ZStack {
                background
                ForEach(appModel.spatial.array.speakers) { speaker in
                    speakerMarker(speaker, in: rect)
                }
                ForEach(voices) { voice in
                    voicePuck(voice, in: rect)
                }
            }
            .coordinateSpace(name: "pad")
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
        }
        .frame(minWidth: 280, minHeight: 280)
        .aspectRatio(1, contentMode: .fit)
        .padding()
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary.opacity(0.4))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
            Image(systemName: "figure.stand")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .help("Listening position")
        }
    }

    private func speakerMarker(_ speaker: Speaker, in rect: CGRect) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "hifispeaker.fill")
                .font(.title3)
            Text(speaker.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.color(for: speaker.node.kind))
        .position(point(speaker.position, in: rect))
        .help("\(speaker.name) · \(speaker.node.defaultLabel)")
    }

    private func voicePuck(_ voice: PlacedVoice, in rect: CGRect) -> some View {
        let center = dragOverrides[voice.id] ?? voice.position
        let isSelected = selection == voice.id
        return ZStack {
            if voice.voice.isStereo {
                stereoUnderlay(voice, center: center, in: rect)
            }
            puckLabel(voice, isSelected: isSelected)
                .position(point(center, in: rect))
        }
        .gesture(dragGesture(for: voice, in: rect))
    }

    private func puckLabel(_ voice: PlacedVoice, isSelected: Bool) -> some View {
        let tint = Theme.color(for: voice.voice.kind == .source ? .channel : .bus)
        let fill = voice.isPlaced ? tint.opacity(isSelected ? 0.9 : 0.65) : tint.opacity(0.18)
        let border: Color = voice.isPlaced ? .white.opacity(isSelected ? 1 : 0) : tint
        return HStack(spacing: 4) {
            if voice.voice.isShared {
                Image(systemName: "link").font(.caption2.weight(.bold))
            }
            Text(voice.voice.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(fill))
        .foregroundStyle(voice.isPlaced ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .overlay(Capsule().strokeBorder(border, lineWidth: isSelected ? 2 : 1))
        .shadow(radius: isSelected ? 4 : 1)
    }

    private func stereoUnderlay(_ voice: PlacedVoice, center: CGPoint, in rect: CGRect) -> some View {
        let placements = voice.voice.spatialSource(position: center, width: voice.width)?.channelPlacements() ?? []
        let points = placements.map { point($0.point, in: rect) }
        let tint = Theme.color(for: voice.voice.kind == .source ? .channel : .bus)
        return ZStack {
            if points.count == 2 {
                Path { path in
                    path.move(to: points[0])
                    path.addLine(to: points[1])
                }
                .stroke(tint.opacity(0.6), style: .init(lineWidth: 2, dash: [4, 3]))
                ForEach(Array(zip(["L", "R"], points)), id: \.0) { label, position in
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(Circle().fill(tint))
                        .foregroundStyle(.white)
                        .position(position)
                }
            }
        }
    }

    // MARK: - Dragging

    private func dragGesture(for voice: PlacedVoice, in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
            .onChanged { value in
                selection = voice.id
                let normalized = normalize(value.location, in: rect)
                dragOverrides[voice.id] = normalized
                throttledPush(voice, to: normalized)
            }
            .onEnded { value in
                let normalized = normalize(value.location, in: rect)
                dragOverrides[voice.id] = nil
                store.setVoicePosition(voice.id, to: normalized)
                var moved = voice
                moved.position = normalized
                moved.isPlaced = true
                Task { await appModel.applyVoicePlacement(moved) }
            }
    }

    private func throttledPush(_ voice: PlacedVoice, to position: CGPoint) {
        guard Date().timeIntervalSince(lastPush) > 0.05 else { return }
        lastPush = Date()
        var moved = voice
        moved.position = position
        moved.isPlaced = true
        Task { await appModel.applyVoicePlacement(moved) }
    }

    // MARK: - Coordinate mapping

    private func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    private func normalize(_ location: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(max((location.x - rect.minX) / rect.width, 0), 1),
            y: min(max((location.y - rect.minY) / rect.height, 0), 1)
        )
    }
}

#Preview {
    @Previewable @State var selection: String?
    let model = AppModel.preview()
    return SpatialPadView(appModel: model, voices: model.placedVoices(), selection: $selection)
        .task {
            await model.equipment.load()
            await model.environments.load()
            await model.spatial.load()
        }
        .frame(width: 360, height: 360)
}
