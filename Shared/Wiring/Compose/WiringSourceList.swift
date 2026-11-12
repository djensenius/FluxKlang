//
//  WiringSourceList.swift
//  FluxKlang
//
//  The Add Connection "From" list (#101 WSRC1; phone-compact-routing.md "Add Connection flow", step 1): the
//  outputs of a graph grouped by node, with signal and channel count, and each observed shortcut listed as
//  "observed, not routable" and disabled. A pure value: it reads only the graph's nodes (no edge, draft or
//  presence), validates nothing and classifies no destination; `WiringDestinationList.make(from:in:)` does that for
//  the address a row names. Nothing calls it yet.
//

/// One output port of a routable node. Built only by `WiringSourceList.make(in:)`.
struct WiringSourceRow: Hashable, Sendable, Identifiable {
    /// The port's address, without extension fields: what the destination step takes as its source.
    let address: PortAddress
    /// The port's label, or its raw ID when the label is nil or empty.
    let title: String
    /// `2ch`, `audio` (no channel count), `MIDI`, `control` or `clock`.
    let signalText: String
    /// The next screen's header: `Vocal (1ch audio)`, or `Vocal Aux (1ch audio)` when the node lists several outputs.
    let fromText: String
    /// `Vocal, out, audio, 1 channel.`
    let accessibilityLabel: String

    var id: PortAddress { address }

    fileprivate init(node: GraphNode, port: GraphPort, showsPort: Bool) {
        let nodeTitle = node.wiringTitle
        address = PortAddress(node: node.id, port: port.id)
        title = WiringSourceText.title(port)
        signalText = WiringConnectionListText.signalText(port)
        fromText = WiringSourceText.fromText(node: nodeTitle, port: port, showsPort: showsPort)
        accessibilityLabel = WiringSourceText.rowLabel(node: nodeTitle, port: port)
    }
}

/// One node of the list. Built only by `WiringSourceList.make(in:)`.
struct WiringSourceSection: Hashable, Sendable, Identifiable {
    let node: NodeID
    /// The node's label, or its raw ID when the label is empty.
    let title: String
    /// The distinct row signals in row order (`2ch, control`); nil for an observed shortcut.
    let signalText: String?
    /// `observed, not routable` for an observed shortcut; nil otherwise.
    let stateText: String?
    /// False for an observed shortcut, true otherwise.
    let isEnabled: Bool
    /// Ordered by port title, then port ID (UTF-8 bytes). Empty for an observed shortcut.
    let rows: [WiringSourceRow]
    /// `Mains (2ch)`, `Console channel 7 (observed, not routable)`.
    let heading: String
    /// `Vocal, 1 channel, 1 output.`, `Console channel 7, observed, not routable.`
    let accessibilityLabel: String

    var id: NodeID { node }

    fileprivate init(routable node: GraphNode, outputs: [GraphPort]) {
        let ports = outputs.map { (title: WiringSourceText.title($0), port: $0) }.sorted { lhs, rhs in
            WiringSourceList.precedes((lhs.title, lhs.port.id.rawValue), (rhs.title, rhs.port.id.rawValue))
        }.map(\.port)
        let rows = ports.map { WiringSourceRow(node: node, port: $0, showsPort: ports.count > 1) }
        self.node = node.id
        title = node.wiringTitle
        signalText = Self.distinct(ports, WiringConnectionListText.signalText)
        stateText = nil
        isEnabled = true
        self.rows = rows
        heading = WiringSourceText.heading(title: title, signal: signalText ?? "")
        accessibilityLabel = WiringSourceText.sectionLabel(
            title: title, signals: Self.distinct(ports, WiringConnectionListText.spokenSignal), outputs: rows.count
        )
    }

    fileprivate init(shortcut node: GraphNode) {
        self.node = node.id
        title = node.wiringTitle
        signalText = nil
        stateText = WiringSourceText.observedNotRoutable
        isEnabled = false
        rows = []
        heading = WiringSourceText.shortcutHeading(title: title)
        accessibilityLabel = WiringSourceText.shortcutLabel(title: title)
    }

    /// The distinct descriptions of `ports` in order, joined by `, ` (distinct by UTF-8 bytes).
    private static func distinct(_ ports: [GraphPort], _ describe: (GraphPort) -> String) -> String {
        var seen = Set<[UInt8]>()
        var texts: [String] = []
        for port in ports {
            let text = describe(port)
            if seen.insert(Array(text.utf8)).inserted { texts.append(text) }
        }
        return texts.joined(separator: ", ")
    }
}

/// The "From" list: one section per node that has an output or is an observed shortcut.
struct WiringSourceList: Hashable, Sendable {
    /// Routable nodes first, then observed shortcuts; each group ordered by node title, then node ID (UTF-8 bytes).
    let sections: [WiringSourceSection]
    /// Every row of every section, in order.
    let rows: [WiringSourceRow]
    /// `No outputs` when no section has a row (shortcuts are still listed); nil otherwise.
    let emptyText: String?

    private init(sections: [WiringSourceSection]) {
        self.sections = sections
        rows = sections.flatMap(\.rows)
        emptyText = rows.isEmpty ? WiringSourceText.noOutputs : nil
    }

    func section(for node: NodeID) -> WiringSourceSection? {
        sections.first { $0.node == node }
    }

    /// The row of the port with this node and port ID (extension fields are ignored).
    func row(for address: PortAddress) -> WiringSourceRow? {
        rows.first { $0.address.node == address.node && $0.address.port == address.port }
    }

    /// Lists `graph`'s output ports. A section is made for every observed shortcut (with no rows, even when it
    /// declares ports) and for every routable node with an output port. Refused, with nothing listed, in the order
    /// of `WiringSourceListRefusal`'s cases.
    static func make(in graph: GraphDocument) throws(WiringSourceListRefusal) -> WiringSourceList {
        do { try graph.checkCollectionBounds() } catch { throw .bounds(error) }
        var seenNodes = Set<NodeID>()
        for node in graph.nodes where !seenNodes.insert(node.id).inserted { throw .duplicateNode(node.id) }
        for node in graph.nodes where node.kind.isRoutable {
            var seenPorts = Set<PortID>()
            for port in node.ports where !seenPorts.insert(port.id).inserted {
                throw .duplicatePort(PortAddress(node: node.id, port: port.id))
            }
        }
        var routable: [(node: GraphNode, outputs: [GraphPort])] = []
        var shortcuts: [GraphNode] = []
        for node in graph.nodes {
            guard node.kind.isRoutable else {
                shortcuts.append(node)
                continue
            }
            let outputs = node.ports.filter { $0.direction == .output }
            if !outputs.isEmpty { routable.append((node, outputs)) }
        }
        routable.sort { precedes($0.node, $1.node) }
        shortcuts.sort(by: precedes)
        let sections = routable.map { WiringSourceSection(routable: $0.node, outputs: $0.outputs) }
            + shortcuts.map { WiringSourceSection(shortcut: $0) }
        return WiringSourceList(sections: sections)
    }

    /// Title bytes, then node ID bytes. IDs are unique once `make` has checked them, so the order is total.
    private static func precedes(_ lhs: GraphNode, _ rhs: GraphNode) -> Bool {
        precedes((lhs.wiringTitle, lhs.id.rawValue), (rhs.wiringTitle, rhs.id.rawValue))
    }

    /// The first string's UTF-8 bytes, then the second's (never `String <`, which compares by Unicode).
    fileprivate static func precedes(_ lhs: (String, String), _ rhs: (String, String)) -> Bool {
        if !lhs.0.utf8.elementsEqual(rhs.0.utf8) { return lhs.0.utf8.lexicographicallyPrecedes(rhs.0.utf8) }
        return lhs.1.utf8.lexicographicallyPrecedes(rhs.1.utf8)
    }
}
