/// A read-only check that an import source and the plan's three names are not the same node under different
/// spellings (a case-insensitive volume, for example). The spelling test in `StagingPlan.overlaps` cannot see an
/// alias; node identity can, because two statuses with the same volume and identity are the same node.
enum StagingAliasCheck {
    private struct NodeID: Hashable {
        let volume: Int
        let identity: UInt64
    }

    /// The existing prefixes of one path, outermost first, up to the first absent one.
    private struct Chain {
        var nodes: [NodeID] = []
        var isComplete = true
    }

    /// Refuses with `.overlappingPaths` when the source is, or lies beneath, one of the plan's names, or when one of
    /// them is, or lies beneath, the source. An absent source is left to the later read. The source chain is probed
    /// first, then the destination, staging and backup chains; each chain costs at most one status call per path
    /// component, so a run issues at most 4 x the deepest path depth status calls and mutates nothing. A failed
    /// probe is the same typed pre-flight failure as a failed pre-flight status.
    static func refuseAliases<FS: StagingFileSystem>(
        source: String, plan: StagingPlan, in store: inout FS
    ) throws(StagingRefusal) {
        let sourceChain = try chain(of: source, &store)
        guard sourceChain.isComplete, let sourceNode = sourceChain.nodes.last else { return }
        let sourceNodes = Set(sourceChain.nodes)
        for path in [plan.destination, plan.stagingPath, plan.backupPath] {
            let planChain = try chain(of: path, &store)
            if planChain.nodes.contains(sourceNode) { throw .overlappingPaths }
            if planChain.isComplete, let own = planChain.nodes.last, sourceNodes.contains(own) {
                throw .overlappingPaths
            }
        }
    }

    private static func chain<FS: StagingFileSystem>(
        of path: String, _ store: inout FS
    ) throws(StagingRefusal) -> Chain {
        var result = Chain()
        var prefix = ""
        for component in path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false) {
            prefix = StagingPlan.join(prefix, String(component))
            let status: StagingNodeStatus?
            do {
                status = try store.status(at: prefix)
            } catch {
                throw .ioFailed(step: .preflight, fault: error, cleanup: .notNeeded)
            }
            guard let status else {
                result.isComplete = false
                return result
            }
            result.nodes.append(NodeID(volume: status.volume, identity: status.identity))
        }
        return result
    }
}
