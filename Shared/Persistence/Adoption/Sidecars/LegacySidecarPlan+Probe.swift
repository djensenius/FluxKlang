import Foundation

/// One supplied sidecar: which one it is, its fixed package path and the caller's bytes.
struct LegacySidecarCandidate: Sendable {
    let source: LegacySidecarSource
    let path: String
    let data: Data

    /// The supplied sidecars, draft first.
    static func present(draft: Data?, connections: Data?) -> [LegacySidecarCandidate] {
        var candidates: [LegacySidecarCandidate] = []
        if let draft {
            candidates.append(LegacySidecarCandidate(
                source: .pendingDraft, path: LegacySidecarPlan.draftPath, data: draft
            ))
        }
        if let connections {
            candidates.append(LegacySidecarCandidate(
                source: .connections, path: LegacySidecarPlan.connectionsPath, data: connections
            ))
        }
        return candidates
    }
}

/// The validation stages of `make` after the byte caps. Each stage walks the candidates in draft-then-connections
/// order and stops at the first defect, so a stage finishes for both sources before the next stage starts.
extension LegacySidecarPlan {
    static func refuseEmpty(_ candidates: [LegacySidecarCandidate]) throws(LegacySidecarRefusal) {
        for candidate in candidates where candidate.data.isEmpty {
            throw .empty(candidate.source)
        }
    }

    /// Valid UTF-8 is checked explicitly and invalid bytes are refused, never replaced.
    static func refuseInvalidUTF8(_ candidates: [LegacySidecarCandidate]) throws(LegacySidecarRefusal) {
        for candidate in candidates where String(validating: candidate.data, as: UTF8.self) == nil {
            throw .notUTF8(candidate.source)
        }
    }

    /// One decoded value per candidate, in candidate order. The values are used only to inspect the top level.
    static func decodeValues(_ candidates: [LegacySidecarCandidate]) throws(LegacySidecarRefusal) -> [JSONValue] {
        var values: [JSONValue] = []
        values.reserveCapacity(candidates.count)
        for candidate in candidates {
            do {
                values.append(try ContractCoding.decode(JSONValue.self, from: candidate.data))
            } catch {
                throw .undecodable(candidate.source)
            }
        }
        return values
    }

    static func refuseNonObjects(
        _ candidates: [LegacySidecarCandidate], values: [JSONValue]
    ) throws(LegacySidecarRefusal) {
        for (candidate, value) in zip(candidates, values) {
            guard case .object = value else { throw .notAnObject(candidate.source) }
        }
    }
}
