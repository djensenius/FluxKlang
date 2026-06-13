//
//  StudioInspectorViews.swift
//  FluxKlang
//

import SwiftUI

struct StudioStatusCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StudioSection<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
            footer
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StudioEndpointCard: View {
    let endpoint: StudioEndpoint
    let allocation: StudioEndpointAllocation?
    var speakers: [Speaker] = []
    var setPlacement: (VoicePlacement) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(endpoint.name, systemImage: endpoint.destination.systemImage)
                    .font(.headline)
                Spacer()
                Text(endpoint.destination.label)
                    .font(.caption)
                    .foregroundStyle(Theme.color(for: endpoint.destination))
            }
            HStack(spacing: 8) {
                ForEach(endpoint.controls.sorted { $0.rawValue < $1.rawValue }, id: \.self) { control in
                    Text(control.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            Text(allocation == nil ? "Nothing is feeding this yet" : "Ready for volume, mute, label and meter")
                .font(.caption)
                .foregroundStyle(.secondary)
            if endpoint.destination == .space {
                spaceControls
            }
        }
        .padding(.vertical, 4)
    }

    private var placement: VoicePlacement {
        endpoint.placement ?? VoicePlacement()
    }

    private var spaceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Place this control in space", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            StudioSpacePlacementPad(
                placement: placement,
                speakers: speakers,
                setPlacement: setPlacement
            )
            placementSlider("Width", value: Binding(
                get: { placement.width },
                set: { setPlacement(VoicePlacement(position: placement.position, width: $0)) }
            ))
        }
        .padding(.top, 4)
    }

    private func placementSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }
}

private struct StudioSpacePlacementPad: View {
    let placement: VoicePlacement
    let speakers: [Speaker]
    let setPlacement: (VoicePlacement) -> Void

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 14, dy: 14)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.35))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary)
                listener
                    .position(point(CGPoint(x: 0.5, y: 0.5), in: rect))
                ForEach(speakers) { speaker in
                    speakerMarker(speaker)
                        .position(point(speaker.position, in: rect))
                }
                puck
                    .position(point(placement.position, in: rect))
                    .gesture(dragGesture(in: rect))
            }
        }
        .frame(height: 190)
        .aspectRatio(1, contentMode: .fit)
    }

    private var listener: some View {
        Image(systemName: "figure.stand")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help("Listening position")
    }

    private var puck: some View {
        VStack(spacing: 2) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.bold))
            Text("Space")
                .font(.caption2.weight(.semibold))
        }
        .padding(8)
        .background(Capsule().fill(Color.accentColor.opacity(0.88)))
        .foregroundStyle(.white)
        .shadow(radius: 3)
    }

    private func speakerMarker(_ speaker: Speaker) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "hifispeaker.fill")
                .font(.caption)
            Text(speaker.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.color(for: speaker.node.kind))
        .help("\(speaker.name) · \(speaker.node.defaultLabel)")
    }

    private func dragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                setPlacement(VoicePlacement(position: normalized(value.location, in: rect), width: placement.width))
            }
    }

    private func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }
}

struct StudioIssueText: Identifiable {
    enum Source {
        case routing(StudioRoutingIssue)
        case resource(StudioResourceIssue)
        case compile(StudioCompileIssue)
    }

    var source: Source

    var id: String {
        switch source {
        case .routing(let issue): return "routing-\(issue.id)"
        case .resource(let issue): return "resource-\(issue.id)"
        case .compile(let issue): return "compile-\(issue.id)"
        }
    }

    var message: String {
        switch source {
        case .routing(let issue): return issue.message
        case .resource(let issue): return issue.message
        case .compile(let issue): return issue.message
        }
    }

    var systemImage: String {
        isError ? "exclamationmark.triangle.fill" : "info.circle"
    }

    var tint: Color {
        isError ? .red : .orange
    }

    static func routing(_ issue: StudioRoutingIssue) -> StudioIssueText {
        StudioIssueText(source: .routing(issue))
    }

    static func resource(_ issue: StudioResourceIssue) -> StudioIssueText {
        StudioIssueText(source: .resource(issue))
    }

    static func compile(_ issue: StudioCompileIssue) -> StudioIssueText {
        StudioIssueText(source: .compile(issue))
    }

    private var isError: Bool {
        switch source {
        case .routing(let issue): return issue.severity == .error
        case .resource(let issue): return issue.severity == .error
        case .compile(let issue): return issue.severity == .error
        }
    }
}

extension StudioEndpointDestination {
    var label: String {
        switch self {
        case .finalMix: return "Final Mix"
        case .space: return "Space"
        case .custom: return "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .finalMix: return "speaker.wave.2"
        case .space: return "dot.radiowaves.left.and.right"
        case .custom: return "slider.horizontal.3"
        }
    }
}

extension StudioEndpointControl {
    var label: String {
        switch self {
        case .volume: return "Volume"
        case .mute: return "Mute"
        case .labelColor: return "Label"
        case .metering: return "Meter"
        }
    }
}
