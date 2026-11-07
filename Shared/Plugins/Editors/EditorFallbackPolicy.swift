//
//  EditorFallbackPolicy.swift
//  FluxKlang
//
//  What to do when a plugin's native editor fails (#77, slice PLG4). Every failure
//  falls back to generic controls that keep every control addressable: the policy
//  never drops, sorts, dedupes or renumbers a control id. A retry is only OFFERED,
//  with an explicit next attempt value the caller must hand back; the policy is pure
//  and never retries by itself. Nothing here creates a view or loads a plugin.
//

enum PluginControlTag: ContractIDTag {}
typealias PluginControlID = ContractID<PluginControlTag>

enum PluginEditorFailure: String, Hashable, Sendable, CaseIterable {
    case unavailable
    case crashed
    case timedOut
    case containmentRefused

    /// A missing editor and a containment refusal fail the same way again; a crash
    /// or a timeout may be transient.
    var isRetryable: Bool {
        switch self {
        case .crashed, .timedOut: true
        case .unavailable, .containmentRefused: false
        }
    }
}

enum EditorFallbackError: Error, Hashable, Sendable {
    case duplicateControl(PluginControlID)
    case tooManyControls(count: Int, limit: Int)
    case attemptOutOfRange(Int)
}

/// The controls of one plugin in the caller's display order, without duplicates.
struct EditorControlSet: Hashable, Sendable {
    let ids: [PluginControlID]

    /// Refuses more than `EditorFallbackPolicy.maximumControls` ids first, then names
    /// the first id that repeats an earlier one in input order.
    init(ids: [PluginControlID]) throws(EditorFallbackError) {
        guard ids.count <= EditorFallbackPolicy.maximumControls else {
            throw .tooManyControls(count: ids.count, limit: EditorFallbackPolicy.maximumControls)
        }
        var seen = Set<PluginControlID>()
        for id in ids where !seen.insert(id).inserted {
            throw .duplicateControl(id)
        }
        self.ids = ids
    }
}

/// The 1-based number of one editor attempt, 1...`EditorFallbackPolicy.maximumAttempts`.
struct EditorAttempt: Hashable, Sendable {
    static let first = EditorAttempt(validated: 1)

    let number: Int

    private init(validated number: Int) {
        self.number = number
    }

    init(number: Int) throws(EditorFallbackError) {
        guard (1...EditorFallbackPolicy.maximumAttempts).contains(number) else {
            throw .attemptOutOfRange(number)
        }
        self.number = number
    }

    fileprivate var next: EditorAttempt? {
        number < EditorFallbackPolicy.maximumAttempts ? EditorAttempt(validated: number + 1) : nil
    }
}

enum EditorFallbackDecision: Hashable, Sendable {
    /// Show generic controls now; no retry is offered.
    case useGenericControls(preserving: [PluginControlID])
    /// Show generic controls now. The editor may be tried again only with `next`.
    case useGenericControlsAndOfferRetry(preserving: [PluginControlID], next: EditorAttempt)
}

/// Maps an editor failure to a decision. Total attempts: 3 (two retries).
enum EditorFallbackPolicy {
    static let maximumAttempts = 3
    static let maximumControls = 4_096

    static func decide(
        failure: PluginEditorFailure, controls: EditorControlSet, attempt: EditorAttempt
    ) -> EditorFallbackDecision {
        guard failure.isRetryable, let next = attempt.next else {
            return .useGenericControls(preserving: controls.ids)
        }
        return .useGenericControlsAndOfferRetry(preserving: controls.ids, next: next)
    }
}
