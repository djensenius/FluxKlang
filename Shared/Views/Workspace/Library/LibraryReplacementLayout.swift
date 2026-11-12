//
//  LibraryReplacementLayout.swift
//  FluxKlang
//
//  The port layout of a candidate replacement for a Missing plugin node (#101 REP1; library-inspector.md "Replace
//  with..."): an opaque picker key, a name and the declared ports. An inert input: there is no plugin catalog yet,
//  so nothing here reads one. Nothing calls it yet.
//

/// One port a replacement declares. Converts to the graph's `GraphPort` through its production initializer.
struct LibraryReplacementPort: Hashable, Sendable {
    let id: PortID
    let direction: PortDirection
    let signal: PortSignal
    /// Audio channel count; nil for other signals, or when unset.
    let channels: Int?
    let label: String?

    init(
        id: PortID, direction: PortDirection, signal: PortSignal, channels: Int? = nil, label: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.signal = signal
        self.channels = channels
        self.label = label
    }

    var graphPort: GraphPort {
        GraphPort(id: id, direction: direction, signal: signal, channels: channels, label: label)
    }
}

/// A candidate replacement's port layout.
struct LibraryReplacementLayout: Hashable, Sendable {
    /// An opaque identity for the picker; layouts are offered in the UTF-8 byte order of their keys.
    let key: String
    /// Becomes the replacement node's label.
    let name: String
    /// In the plugin's declared order, which the replacement node keeps.
    let ports: [LibraryReplacementPort]
}
