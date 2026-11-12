//
//  ActionV1Record.swift
//  FluxKlang
//
//  One declaration of the media contract v1 `actions` header (#107 ACT1): exactly the schema's fields,
//  validated fail-closed and encoded deterministically. Pure: it writes no file.
//

import Foundation

/// One entry of a contract v1 trace's `actions` (`$defs.action`). Built only by `make`.
///
/// The builder derives nothing from the policy: `quantize` is the declared `$defs.target`, because `ActionPolicy`
/// holds only a grid. The input types already guarantee the policy's time policy for its media, its lateness and
/// retroactive bounds, a positive `nextBoundary` grid, and the `PrefetchPlan` ranges, so there is no refusal for them.
///
/// Not checked here: that a `ready` `timeStretch` action has `adapterCapabilities.timeStretch`, that a trigger or
/// readiness record names the action, and the readiness transitions. All of that needs other parts of the trace.
///
/// Dropped: `stoppedPolicy`, which the v1 trace has no field for. Omitted: `retroactiveMs` when 0 (the checker reads
/// an absent value as 0), and `maxLatenessMs` for `drop` and `nextBoundary`, which carry none. A `prefetch` on a
/// non-audio action is written as given.
struct ActionV1Record: Hashable, Sendable {
    let id: ActionID
    let policy: ActionPolicy
    let quantize: TriggerTarget
    let readiness: ReadinessState
    let prefetch: PrefetchPlan?

    /// Builds the declaration, or throws the first refusal in the order `ActionV1RecordRefusal` documents.
    static func make(id: ActionID, policy: ActionPolicy, quantize: TriggerTarget, readiness: ReadinessState,
                     prefetch: PrefetchPlan? = nil) throws(ActionV1RecordRefusal) -> ActionV1Record {
        guard MediaContractV1ID.matches(id.rawValue) else { throw .invalidActionID(id) }
        guard !policy.hasUnknownFields, policy.extensions?.isEmpty != false else { throw .extensionFields }
        try check(quantize)
        guard policy.media != .audio || prefetch != nil else { throw .audioWithoutPrefetch }
        try checkGrids(of: policy, against: quantize)
        return ActionV1Record(id: id, policy: policy, quantize: quantize, readiness: readiness, prefetch: prefetch)
    }

    private static func check(_ quantize: TriggerTarget) throws(ActionV1RecordRefusal) {
        switch quantize {
        case .grid(let ticks): guard ticks >= 1 else { throw .invalidGrid(ticks) }
        case .musical(let ticks): guard ticks >= 0 else { throw .negativeMusicalTicks(ticks) }
        case .sample, .asap: break
        }
    }

    /// `nextBoundary` needs a grid `quantize`; then the policy's `gridTicks` and the `nextBoundary` grid, in that
    /// order, must each equal it.
    private static func checkGrids(of policy: ActionPolicy,
                                   against quantize: TriggerTarget) throws(ActionV1RecordRefusal) {
        var boundaryGrid: Int64?
        if case .nextBoundary(let grid) = policy.latePolicy {
            guard case .grid = quantize else { throw .nextBoundaryWithoutGrid }
            boundaryGrid = grid
        }
        for grid in [policy.gridTicks, boundaryGrid] {
            if let grid, quantize != .grid(ticks: grid) { throw .policyGridMismatch(policy: grid, quantize: quantize) }
        }
    }

    private init(id: ActionID, policy: ActionPolicy, quantize: TriggerTarget, readiness: ReadinessState,
                 prefetch: PrefetchPlan?) {
        self.id = id
        self.policy = policy
        self.quantize = quantize
        self.readiness = readiness
        self.prefetch = prefetch
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the schema's
    /// fields. Identical input encodes to identical bytes. The output is bounded: one ID of at most
    /// `ContractID.maximumLength` (128) bytes and a fixed set of numbers and constants.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension ActionV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case media, quantize, late, notReady, readiness, timePolicy, prefetch
        case id = "actionId"
    }

    private enum LateKeys: String, CodingKey {
        case policy, maxLatenessMs, retroactiveMs
    }

    private enum PrefetchKeys: String, CodingKey {
        case blockFrames, blockCount, headFrames
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(policy.media, forKey: .media)
        try container.encode(TargetShape(target: quantize), forKey: .quantize)
        var late = container.nestedContainer(keyedBy: LateKeys.self, forKey: .late)
        try late.encode(Self.name(of: policy.latePolicy), forKey: .policy)
        try late.encodeIfPresent(policy.latePolicy.maxLatenessMs, forKey: .maxLatenessMs)
        if policy.retroactiveMs != 0 { try late.encode(policy.retroactiveMs, forKey: .retroactiveMs) }
        try container.encode("dropAndReport", forKey: .notReady)
        try container.encode(readiness, forKey: .readiness)
        try container.encodeIfPresent(policy.timePolicy, forKey: .timePolicy)
        if let prefetch {
            var block = container.nestedContainer(keyedBy: PrefetchKeys.self, forKey: .prefetch)
            try block.encode(prefetch.blockFrames, forKey: .blockFrames)
            try block.encode(prefetch.blockCount, forKey: .blockCount)
            try block.encode(prefetch.headFrames, forKey: .headFrames)
        }
    }

    private static func name(of late: LatePolicy) -> String {
        switch late {
        case .drop: "drop"
        case .fireLate: "fireLate"
        case .joinInProgress: "joinInProgress"
        case .nextBoundary: "nextBoundary"
        }
    }
}
