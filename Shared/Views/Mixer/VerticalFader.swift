//
//  VerticalFader.swift
//  FluxKlang
//
//  A lightweight vertical fader control: a track, a level fill and a draggable
//  knob. Position is a normalised value in `0.0...1.0`. The richer native
//  behaviours (scroll-wheel, double-click reset, fine drag) arrive with the Mac
//  polish phase.
//

import SwiftUI

struct VerticalFader: View {
    @Binding var position: Double
    @Binding var isEditing: Bool

    private let knobHeight: CGFloat = 18
    private let trackWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let travel = max(height - knobHeight, 1)
            let clamped = min(max(position, 0), 1)
            let knobOffset = travel * (1 - clamped)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: trackWidth)
                    .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(.tint)
                        .frame(width: trackWidth, height: travel * clamped + knobHeight / 2)
                }

                RoundedRectangle(cornerRadius: 5)
                    .fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tint, lineWidth: 2))
                    .frame(width: 34, height: knobHeight)
                    .shadow(radius: 1, y: 1)
                    .offset(y: knobOffset)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isEditing = true
                        let raw = 1 - Double((value.location.y - knobHeight / 2) / travel)
                        position = min(max(raw, 0), 1)
                    }
                    .onEnded { _ in isEditing = false }
            )
        }
        .frame(minWidth: 40, minHeight: 150)
    }
}

#Preview {
    @Previewable @State var position = 0.75
    @Previewable @State var isEditing = false
    VerticalFader(position: $position, isEditing: $isEditing)
        .tint(.blue)
        .frame(width: 56, height: 240)
        .padding()
}
