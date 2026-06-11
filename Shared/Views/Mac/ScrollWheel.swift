//
//  ScrollWheel.swift
//  FluxKlang
//
//  A small bridge that delivers trackpad / mouse scroll-wheel events to SwiftUI
//  on macOS, used for native fader scrubbing and chain-canvas pan / zoom. On
//  other platforms `onScrollWheel` is a no-op.
//

import SwiftUI

/// A scroll-wheel sample: scroll deltas plus the modifier keys held at the time.
struct ScrollWheelInfo {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var commandKey: Bool
    var optionKey: Bool
}

extension View {
    /// Calls `handler` for scroll-wheel events while the pointer is over this
    /// view (macOS only). Returns the view unchanged on other platforms.
    func onScrollWheel(_ handler: @escaping (ScrollWheelInfo) -> Void) -> some View {
        #if os(macOS)
        modifier(ScrollWheelModifier(handler: handler))
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

/// Installs a local scroll-wheel monitor while the pointer hovers the view, so
/// only the hovered control reacts. The monitor is torn down on exit.
@MainActor
private final class ScrollWheelMonitor {
    private var token: Any?
    var handler: (ScrollWheelInfo) -> Void = { _ in }

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            self.handler(
                ScrollWheelInfo(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    commandKey: event.modifierFlags.contains(.command),
                    optionKey: event.modifierFlags.contains(.option)
                )
            )
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

private struct ScrollWheelModifier: ViewModifier {
    let handler: (ScrollWheelInfo) -> Void
    @State private var monitor = ScrollWheelMonitor()

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    monitor.handler = handler
                    monitor.start()
                case .ended:
                    monitor.stop()
                }
            }
            .onDisappear { monitor.stop() }
    }
}
#endif
