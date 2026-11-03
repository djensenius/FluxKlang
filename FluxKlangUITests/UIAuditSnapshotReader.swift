import XCTest

/// Classifies one supplied hierarchy, not global AX coverage, freshness or command delivery.
@MainActor
struct UIAuditSnapshotReader {
    enum Observation: Equatable {
        case snapshotUnavailable
        case observationIncomplete
        case absent
        case ambiguous
        case missingValue
        case nonStringValue
        case receipt(String)
    }

    private static let nodeLimit = 4096

    func read(in app: XCUIApplication) -> Observation {
        do {
            let snapshot = try app.snapshot()
            return inspect(snapshot)
        } catch {
            return .snapshotUnavailable
        }
    }

    func inspect(_ snapshot: any XCUIElementSnapshot) -> Observation {
        var pending: [any XCUIElementSnapshot] = [snapshot]
        var visited = 0
        var candidate: (any XCUIElementSnapshot)?

        while let node = pending.popLast() {
            guard visited < Self.nodeLimit else { return .observationIncomplete }
            visited += 1
            if node.identifier == "fluxklang.audit.capture" {
                guard candidate == nil else { return .ambiguous }
                candidate = node
            }

            // This bounds adapter-owned pending entries, not framework acquisition,
            // children-array materialization, value allocation or wall-clock duration.
            let children = node.children
            guard children.count <= Self.nodeLimit - pending.count else {
                return .observationIncomplete
            }
            pending.append(contentsOf: children)
        }

        guard let candidate else { return .absent }
        guard let value = candidate.value else { return .missingValue }
        guard let receipt = value as? String else { return .nonStringValue }
        return .receipt(receipt)
    }
}
