//
//  SpatialPadView.swift
//  FluxKlang
//
//  A 2D placement pad: speakers are fixed markers, instruments are draggable
//  pucks. Dragging a puck recomputes its DBAP bus sends and pushes them to the
//  WING live (throttled), committing the new position when the drag ends. Stereo
//  sources render their two channels spread by the source width.
//

import SwiftUI

struct SpatialPadView: View {
    let appModel: AppModel
    @Binding var selection: SpatialSource.ID?

    private let inset: CGFloat = 26
    @State private var dragOverrides: [SpatialSource.ID: CGPoint] = [:]
    @State private var lastPush = Date.distantPast

    private var store: SpatialStore { appModel.spatial }

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local).insetBy(dx: inset, dy: inset)
            ZStack {
                background
                ForEach(store.array.speakers) { speaker in
                    speakerMarker(speaker, in: rect)
                }
                ForEach(store.sources) { source in
                    sourcePuck(source, in: rect)
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

    private func sourcePuck(_ source: SpatialSource, in rect: CGRect) -> some View {
        let center = dragOverrides[source.id] ?? source.position
        let isSelected = selection == source.id
        return ZStack {
            if source.isStereo {
                stereoUnderlay(source, center: center, in: rect)
            }
            puckLabel(source, isSelected: isSelected)
                .position(point(center, in: rect))
        }
        .gesture(dragGesture(for: source, in: rect))
    }

    private func puckLabel(_ source: SpatialSource, isSelected: Bool) -> some View {
        let tint = Theme.color(for: .channel)
        return Text(source.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(isSelected ? 0.9 : 0.65)))
            .foregroundStyle(.white)
            .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 1 : 0), lineWidth: 2))
            .shadow(radius: isSelected ? 4 : 1)
    }

    private func stereoUnderlay(_ source: SpatialSource, center: CGPoint, in rect: CGRect) -> some View {
        var moved = source
        moved.position = center
        let points = moved.channelPlacements().map { point($0.point, in: rect) }
        return ZStack {
            if points.count == 2 {
                Path { path in
                    path.move(to: points[0])
                    path.addLine(to: points[1])
                }
                .stroke(Theme.color(for: .channel).opacity(0.6), style: .init(lineWidth: 2, dash: [4, 3]))
                ForEach(Array(zip(["L", "R"], points)), id: \.0) { label, position in
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(Circle().fill(Theme.color(for: .channel)))
                        .foregroundStyle(.white)
                        .position(position)
                }
            }
        }
    }

    // MARK: - Dragging

    private func dragGesture(for source: SpatialSource, in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
            .onChanged { value in
                selection = source.id
                let normalized = normalize(value.location, in: rect)
                dragOverrides[source.id] = normalized
                throttledPush(source, to: normalized)
            }
            .onEnded { value in
                let normalized = normalize(value.location, in: rect)
                dragOverrides[source.id] = nil
                store.updatePosition(source.id, to: normalized)
                var moved = source
                moved.position = normalized
                Task { await appModel.applyPlacement(moved) }
            }
    }

    private func throttledPush(_ source: SpatialSource, to position: CGPoint) {
        guard Date().timeIntervalSince(lastPush) > 0.05 else { return }
        lastPush = Date()
        var moved = source
        moved.position = position
        Task { await appModel.applyPlacement(moved) }
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
    @Previewable @State var selection: SpatialSource.ID?
    let model = AppModel.preview()
    return SpatialPadView(appModel: model, selection: $selection)
        .task { await model.spatial.load() }
        .frame(width: 360, height: 360)
}
