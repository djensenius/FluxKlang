//
//  GraphNode+WiringTitle.swift
//  FluxKlang
//
//  The one node display-title rule the wiring surfaces share (#101 WNT1): the inspector, the focus order, the
//  Connections list and the performance wiring text.
//

extension GraphNode {
    /// The node's label, or its raw ID when the label is empty (no UTF-8 bytes). A whitespace-only label is kept.
    var wiringTitle: String {
        label.utf8.isEmpty ? id.rawValue : label
    }
}
