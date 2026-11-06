import Foundation

enum ProjectGraphLimitError: Error, Hashable, Sendable {
    case exceeded(path: String, maximum: Int)
}

/// Resource ceilings for portable intent, not render capacities or device limits.
enum ProjectGraphLimits {
    static let documentBytes = 4 * 1_024 * 1_024
    static let nodes = 4_096
    static let edges = 16_384
    static let portsPerNode = 256
    static let capabilities = 1_024
    static let projectRecords = 4_096
    static let edits = 4_096

    static func check(_ count: Int, maximum: Int, path: String) throws(ProjectGraphLimitError) {
        if count > maximum { throw .exceeded(path: path, maximum: maximum) }
    }

    static func checkBytes(_ data: Data) throws(ProjectGraphLimitError) {
        try check(data.count, maximum: documentBytes, path: "$bytes")
    }
}

extension GraphDocument {
    func checkCollectionBounds() throws(ProjectGraphLimitError) {
        try ProjectGraphLimits.check(nodes.count, maximum: ProjectGraphLimits.nodes, path: "$.nodes")
        try ProjectGraphLimits.check(edges.count, maximum: ProjectGraphLimits.edges, path: "$.edges")
        try ProjectGraphLimits.check(
            capabilities.count, maximum: ProjectGraphLimits.capabilities, path: "$.capabilities"
        )
        for node in nodes {
            try node.checkCollectionBounds()
        }
    }
}

extension GraphNode {
    /// The per-node limits of `GraphDocument.checkCollectionBounds()`: ports first, then required and
    /// advisory capabilities together. The draft edit fold checks an added node with this too.
    func checkCollectionBounds() throws(ProjectGraphLimitError) {
        try ProjectGraphLimits.check(
            ports.count, maximum: ProjectGraphLimits.portsPerNode, path: "$.nodes[\(id)].ports"
        )
        try ProjectGraphLimits.check(
            requiredCapabilities.count + advisoryCapabilities.count,
            maximum: ProjectGraphLimits.capabilities, path: "$.nodes[\(id)].capabilities"
        )
    }
}
