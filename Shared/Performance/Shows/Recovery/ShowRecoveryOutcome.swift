//
//  ShowRecoveryOutcome.swift
//  FluxKlang
//
//  The result of a recovery batch (#106 SH4): the recovered library, how many targets were relinked and cleared, and
//  what is still missing. The initializer is file private and `ShowChartRecovery.apply` is the only code in this
//  file that calls it, so an outcome always comes from a batch that was applied to a library in a catalog.
//

struct ShowRecoveryOutcome: Hashable, Sendable {
    private let storedLibrary: ShowLibrary
    private let storedRelinkedTargetCount: Int
    private let storedClearedTargetCount: Int
    private let storedWorklist: ShowRecoveryWorklist

    /// Only chart references differ from the library the batch was applied to.
    var library: ShowLibrary { storedLibrary }
    /// Targets moved to a new chart: one per target, however the decision named them.
    var relinkedTargetCount: Int { storedRelinkedTargetCount }
    /// Targets whose chart reference was removed, by an explicit decision.
    var clearedTargetCount: Int { storedClearedTargetCount }
    /// What is still missing in `library`, recomputed from it.
    var worklist: ShowRecoveryWorklist { storedWorklist }

    fileprivate init(library: ShowLibrary, relinked: Int, cleared: Int, worklist: ShowRecoveryWorklist) {
        storedLibrary = library
        storedRelinkedTargetCount = relinked
        storedClearedTargetCount = cleared
        storedWorklist = worklist
    }
}

extension ShowChartRecovery {
    /// Applies `decisions` in order to a copy of `library`; later decisions see the earlier results. Atomic: the first
    /// refusal names its index and yields no outcome, and `library` is a value that is never touched. Setlists are
    /// carried over unchanged. A batch over `maximumDecisions` is refused before any decision is read (index
    /// `maximumDecisions`, the first one that does not fit); an empty batch returns an equal library and worklist.
    static func apply(_ decisions: [ShowRecoveryDecision], to library: ShowLibrary,
                      in catalog: ShowLinkCatalog) throws(ShowRecoveryRefusal) -> ShowRecoveryOutcome {
        guard decisions.count <= maximumDecisions else {
            throw ShowRecoveryRefusal(index: maximumDecisions, reason: .tooManyDecisions(decisions.count))
        }
        var batch = ShowRecoveryBatch(library: library, catalog: catalog)
        for (index, decision) in decisions.enumerated() {
            do throws(ShowRecoveryReason) {
                try batch.apply(decision)
            } catch {
                throw ShowRecoveryRefusal(index: index, reason: error)
            }
        }
        // The songs keep their IDs, order and count and the setlists are unchanged, so this cannot refuse; it is the
        // only way to build a `ShowLibrary`, and its failure is reported rather than trapped.
        do throws(ShowRefusal) {
            let recovered = try ShowLibrary.make(songs: batch.songs, setlists: library.setlists)
            let worklist = ShowRecoveryWorklist.make(library: recovered, catalog: catalog)
            return ShowRecoveryOutcome(library: recovered, relinked: batch.relinkedCount,
                                       cleared: batch.clearedCount, worklist: worklist)
        } catch {
            throw ShowRecoveryRefusal(index: decisions.count, reason: .show(error))
        }
    }
}
