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
            try ProjectGraphLimits.check(
                node.ports.count, maximum: ProjectGraphLimits.portsPerNode, path: "$.nodes[\(node.id)].ports"
            )
            try ProjectGraphLimits.check(
                node.requiredCapabilities.count + node.advisoryCapabilities.count,
                maximum: ProjectGraphLimits.capabilities, path: "$.nodes[\(node.id)].capabilities"
            )
        }
    }
}
