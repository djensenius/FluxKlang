//
//  WingNodeRef.swift
//  FluxKlang
//
//  A persistable reference to a WING strip (kind + 1-based index), used by fader
//  layouts, presets and the chain builder.
//

import Foundation

struct WingNodeRef: Codable, Hashable, Sendable, Identifiable {
    var kind: WingNodeKind
    var index: Int

    var id: String { "\(kind.rawValue)-\(index)" }

    /// A default display label, e.g. "Channel 1".
    var defaultLabel: String { "\(kind.label) \(index)" }
}

extension WingNodeRef {
    static func channel(_ index: Int) -> WingNodeRef { WingNodeRef(kind: .channel, index: index) }
    static func bus(_ index: Int) -> WingNodeRef { WingNodeRef(kind: .bus, index: index) }
    static func main(_ index: Int) -> WingNodeRef { WingNodeRef(kind: .main, index: index) }
}
