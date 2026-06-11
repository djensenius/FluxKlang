//
//  MeterView.swift
//  FluxKlang
//
//  A slim vertical level meter shown beside a fader. Driven by the strip's
//  current level so it animates with live changes (including the demo's ambient
//  drift and moves made elsewhere on the network).
//

import SwiftUI

struct MeterView: View {
    /// Normalised level, `0.0...1.0`.
    var level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .green, .yellow, .red],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: max(2, geo.size.height * clamped))
            }
        }
        .frame(width: 6)
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.2), value: clamped)
        .accessibilityHidden(true)
    }

    private var clamped: Double { min(max(level, 0), 1) }
}

#Preview {
    HStack(spacing: 16) {
        MeterView(level: 0.2)
        MeterView(level: 0.6)
        MeterView(level: 0.95)
    }
    .frame(height: 200)
    .padding()
}
