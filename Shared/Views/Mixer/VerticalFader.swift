//
//  VerticalFader.swift
//  FluxKlang
//
//  A vertical fader control: a track, a level fill and a draggable knob. Position
//  is a normalised value in `0.0...1.0`. On Mac it feels native — scroll-wheel to
//  adjust, double-click to reset to unity, and ⌥-drag for fine control.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct VerticalFader: View {
    @Binding var position: Double
    @Binding var isEditing: Bool

    /// Position the knob returns to on a double-click (0 dB by default).
    var unityPosition: Double = Double(FaderMath.unityPosition)
    /// Called for discrete, non-drag changes (double-click reset, scroll-wheel)
    /// so the owner can push the new value to the WING.
    var onSet: (Double) -> Void = { _ in }

    private let knobHeight: CGFloat = 18
    private let trackWidth: CGFloat = 6

    @State private var lastTranslation: CGFloat = 0

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
            .gesture(dragGesture(travel: travel))
            .highPriorityGesture(
                TapGesture(count: 2).onEnded {
                    position = clampUnit(unityPosition)
                    onSet(position)
                }
            )
        }
        .frame(minWidth: 40, minHeight: 150)
        .onScrollWheel { info in
            let step = Double(info.deltaY) * (info.optionKey ? 0.001 : 0.004)
            position = clampUnit(position + step)
            onSet(position)
        }
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isEditing = true
                let delta = value.translation.height - lastTranslation
                lastTranslation = value.translation.height
                let factor: Double = fineModifierActive ? 0.2 : 1
                position = clampUnit(position - Double(delta) / Double(travel) * factor)
            }
            .onEnded { _ in
                isEditing = false
                lastTranslation = 0
            }
    }

    private func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Whether the Option key is held, enabling fine drag (macOS only).
    private var fineModifierActive: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
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
