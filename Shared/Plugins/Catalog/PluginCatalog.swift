//
//  PluginCatalog.swift
//  FluxKlang
//
//  The cached plugin catalog: a pure value that applies every update and
//  absence of a complete scan report, deferring admissions over the cap (see
//  below), and never applies one partially when it throws.
//  Components a pass omits become `missing` and keep their last descriptor;
//  probe crashes and hangs quarantine a component until it is
//  explicitly released, and a probed component needs a fresh description
//  before it resolves again. The catalog generation steps by one whenever
//  anything a consumer could observe changes, and stays put otherwise. The
//  entry cap is never relieved by eviction: only an explicit `forget` of a
//  missing, unquarantined entry frees a slot. Quarantine is safety evidence,
//  so bare quarantined entries (no descriptor) never count against the
//  ordinary cap; all entries together are bounded by the cap plus a separate
//  headroom. Bare entries may therefore exceed the headroom while ordinary
//  slots are free (for example, 257 crashes recorded before 4,095 components
//  were described). Quarantined entries can never be forgotten, only
//  explicitly released.
//
//  A complete report may list up to `entries + quarantineHeadroom` components,
//  the most any catalog can hold, so a full catalog with quarantined
//  components can always be refreshed.
//
//  "Catalog full": once missing and installed entries fill the cap, a pass
//  still applies every update and confirmed absence (installed entries it
//  omits become `missing`), but defers admissions that do not fit: newcomers,
//  and descriptions of bare quarantined entries. `PluginCatalogChange.deferred`
//  counts them; the user forgets missing entries and a rescan admits them.
//  Releasing a bare entry is refused at the cap. A missing, quarantined bare
//  entry leaves in three explicit steps: forget a missing unquarantined entry
//  to make room, release the quarantine (which turns it into a metadata
//  entry), then forget it once a pass marks it missing.
//

import Foundation

enum PluginForgetRefusal: Hashable, Sendable {
    case unknown
    case notMissing
    case quarantined
}

enum PluginCatalogError: Error, Equatable, Sendable {
    case tooManyEntries(maximum: Int)
    /// Recording quarantine would exceed the metadata cap plus quarantine headroom.
    case quarantineHeadroomExhausted(maximum: Int)
    /// One evidence batch is larger than any catalog could record; no amount of
    /// freed room helps, so it is not a capacity condition.
    case evidenceBatchTooLarge(maximum: Int)
    case duplicateIdentity(PluginID)
    case descriptorIdentityMismatch(PluginID)
    /// A metadata-only pass claimed to have instantiated a component.
    case probeOutcomeFromMetadataScan(PluginID)
    /// A pass reported probing a component it was told was quarantined.
    case probedQuarantinedPlugin(PluginID)
    /// The report answers a request whose quarantine set is no longer current.
    case staleRequest
    case notQuarantined(PluginID)
    case cannotForget(PluginID, PluginForgetRefusal)
    case generationOverflow
}

enum PluginPresence: Hashable, Sendable {
    case installed
    /// Absent from the latest complete pass.
    case missing
    case failed(PluginScanFailure)
    /// Probed without a fresh description; `lastKnown` may be stale.
    case needsRescan
}

struct PluginCatalogEntry: Hashable, Sendable {
    let identity: PluginIdentity
    var presence: PluginPresence
    /// The latest successful description, kept while missing, failed or quarantined.
    var lastKnown: PluginDescriptor?
    var quarantine: PluginQuarantineReason?

    /// Quarantined without a descriptor: counts against the quarantine
    /// headroom rather than the ordinary entry cap.
    var isBare: Bool { quarantine != nil && lastKnown == nil }
}

enum PluginCatalogScanState: Hashable, Sendable {
    case notScanned
    case scanned
}

struct PluginCatalogChange: Hashable, Sendable {
    let generation: Generation
    /// Sorted identities whose entry was added, changed or removed; empty when nothing changed.
    let changed: [PluginID]
    /// Admissions a full catalog deferred (newcomers, or descriptions of bare
    /// quarantined entries): "catalog full — forget missing entries".
    let deferred: Int

    init(generation: Generation, changed: [PluginID], deferred: Int = 0) {
        self.generation = generation
        self.changed = changed
        self.deferred = deferred
    }
}

struct PluginCatalog: Hashable, Sendable {
    private(set) var generation: Generation
    private(set) var scanState: PluginCatalogScanState = .notScanned
    private(set) var entries: [PluginID: PluginCatalogEntry] = [:]

    /// An empty, unscanned catalog. A replacement catalog continues from a prior
    /// generation so that resolutions made under the old one cannot match it.
    init(generation: Generation = .initial) {
        self.generation = generation
    }

    var quarantined: Set<PluginID> {
        Set(entries.values.filter { $0.quarantine != nil }.map(\.identity.id))
    }

    /// Generations compare by equality only (M2).
    func isCurrent(_ observed: Generation) -> Bool {
        observed == generation
    }

    func request(depth: PluginScanDepth) -> PluginScanRequest {
        PluginScanRequest(depth: depth, quarantined: quarantined)
    }

    /// Applies every update and absence of one complete pass, deferring
    /// admissions over the cap (counted, never evicted for). Never partially
    /// applies on throw: a throw changes nothing.
    mutating func apply(
        _ report: PluginScanReport, for request: PluginScanRequest
    ) throws(PluginCatalogError) -> PluginCatalogChange {
        guard request.quarantined == quarantined else { throw .staleRequest }
        let maximumReport = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
        guard report.entries.count <= maximumReport else { throw .tooManyEntries(maximum: maximumReport) }
        try Self.check(report.quarantineEvidence, for: request)
        var next = entries
        var seen = Set<PluginID>()
        for scanned in report.entries {
            let id = scanned.identity.id
            guard seen.insert(id).inserted else { throw .duplicateIdentity(id) }
            let previous = entries[id]
            var entry = PluginCatalogEntry(
                identity: scanned.identity, presence: .installed,
                lastKnown: previous?.lastKnown, quarantine: previous?.quarantine
            )
            switch scanned.outcome {
            case .described(let descriptor):
                guard descriptor.identity == scanned.identity else { throw .descriptorIdentityMismatch(id) }
                entry.lastKnown = descriptor
            case .failed(let failure):
                entry.presence = .failed(failure)
            case .probeCrashed:
                entry.presence = .needsRescan
                entry.quarantine = .probeCrashed
            case .probeTimedOut:
                entry.presence = .needsRescan
                entry.quarantine = .probeTimedOut
            }
            next[id] = entry
        }
        for id in entries.keys where !seen.contains(id) {
            next[id]?.presence = .missing
        }
        let deferred = deferAdmissions(&next, reported: report.entries)
        let change = try commit(next, forceStep: scanState == .notScanned)
        scanState = .scanned
        return PluginCatalogChange(generation: change.generation, changed: change.changed, deferred: deferred)
    }

    /// Over the ordinary cap or the total bound (cap plus headroom), undoes
    /// admissions from the highest `PluginID` down until both hold, so the
    /// outcome never depends on scan order: a newcomer is left out, and a
    /// described bare entry stays bare (present, needing a rescan). Only
    /// newcomers relieve the total bound. Updates, absences and quarantine are
    /// kept. If new crash entries alone exceed the total, the commit refuses
    /// (`quarantineHeadroomExhausted`): the service still tries to record the
    /// evidence and, where it cannot fit, latches `.evidenceUnrecorded` and
    /// reports `evidenceNotRecorded`. That pass's confirmed absences are not
    /// applied; the next scan retries them.
    private func deferAdmissions(
        _ next: inout [PluginID: PluginCatalogEntry], reported: [PluginScanEntry]
    ) -> Int {
        let maximumTotal = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
        var ordinary = next.values.count { !$0.isBare }
        var total = next.count
        guard ordinary > PluginCatalogLimits.entries || total > maximumTotal else { return 0 }
        let admissions = reported.map(\.identity.id).filter { id in
            guard let candidate = next[id], !candidate.isBare else { return false }
            return entries[id]?.isBare ?? true
        }.sorted(by: >)
        var deferred = 0
        for id in admissions {
            let overOrdinary = ordinary > PluginCatalogLimits.entries
            let overTotal = total > maximumTotal
            guard overOrdinary || overTotal else { break }
            guard overOrdinary || entries[id] == nil else { continue }
            if var kept = entries[id] {
                kept.presence = .needsRescan
                next[id] = kept
            } else {
                next[id] = nil
                total -= 1
            }
            ordinary -= 1
            deferred += 1
        }
        return deferred
    }

    /// Commits probe failures from a pass whose metadata is being discarded.
    /// Existing quarantine is kept as first recorded; nothing else changes.
    mutating func recordQuarantine(
        _ evidence: [PluginQuarantineEvidence]
    ) throws(PluginCatalogError) -> PluginCatalogChange {
        guard evidence.count <= PluginCatalogLimits.entries else {
            throw .evidenceBatchTooLarge(maximum: PluginCatalogLimits.entries)
        }
        var next = entries
        var seen = Set<PluginID>()
        for item in evidence {
            let id = item.identity.id
            guard seen.insert(id).inserted else { throw .duplicateIdentity(id) }
            guard entries[id]?.quarantine == nil else { continue }
            var entry = entries[id] ?? PluginCatalogEntry(identity: item.identity, presence: .needsRescan)
            entry.presence = .needsRescan
            entry.quarantine = item.reason
            next[id] = entry
        }
        return try commit(next, forceStep: false)
    }

    /// The explicit, user-reviewed way out of quarantine. The entry still needs
    /// a fresh description if it was probed.
    mutating func releaseQuarantine(_ id: PluginID) throws(PluginCatalogError) -> PluginCatalogChange {
        guard entries[id]?.quarantine != nil else { throw .notQuarantined(id) }
        var next = entries
        next[id]?.quarantine = nil
        return try commit(next, forceStep: false)
    }

    /// The explicit, user-confirmed removal of a missing, unquarantined entry.
    /// References to it keep resolving to a `notInstalled` placeholder.
    /// Quarantined entries are refused: their evidence stays until released.
    mutating func forget(_ id: PluginID) throws(PluginCatalogError) -> PluginCatalogChange {
        guard let entry = entries[id] else { throw .cannotForget(id, .unknown) }
        guard entry.quarantine == nil else { throw .cannotForget(id, .quarantined) }
        guard entry.presence == .missing else { throw .cannotForget(id, .notMissing) }
        var next = entries
        next[id] = nil
        return try commit(next, forceStep: false)
    }

    /// Whether one more bare quarantined entry would fit. One free slot is
    /// enough to clear a service's `.evidenceUnrecorded` block even if the
    /// failed batch needed more: a probe that crashes again re-latches the
    /// block, so recovery is retried one probe at a time.
    var hasQuarantineRoom: Bool {
        entries.count < PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
    }

    /// Probe failures are only credible from an instantiating pass that was
    /// told not to touch the components already quarantined.
    static func check(
        _ evidence: [PluginQuarantineEvidence], for request: PluginScanRequest
    ) throws(PluginCatalogError) {
        for item in evidence {
            let id = item.identity.id
            guard request.depth == .instantiatingProbe else { throw .probeOutcomeFromMetadataScan(id) }
            guard !request.quarantined.contains(id) else { throw .probedQuarantinedPlugin(id) }
        }
    }

    /// Entries with metadata are capped; bare quarantined entries may use the
    /// headroom above the cap. Releasing a bare entry turns it into a metadata
    /// entry and is refused at the cap (a scan defers describing one instead).
    private static func checkCapacity(_ next: [PluginID: PluginCatalogEntry]) throws(PluginCatalogError) {
        let bare = next.values.count(where: \.isBare)
        guard next.count - bare <= PluginCatalogLimits.entries else {
            throw .tooManyEntries(maximum: PluginCatalogLimits.entries)
        }
        let maximum = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
        guard next.count <= maximum else { throw .quarantineHeadroomExhausted(maximum: maximum) }
    }

    private mutating func commit(
        _ next: [PluginID: PluginCatalogEntry], forceStep: Bool
    ) throws(PluginCatalogError) -> PluginCatalogChange {
        try Self.checkCapacity(next)
        let keys = Set(next.keys).union(entries.keys)
        let changed = keys.filter { next[$0] != entries[$0] }.sorted()
        guard forceStep || !changed.isEmpty else { return PluginCatalogChange(generation: generation, changed: []) }
        do {
            generation = try generation.next()
        } catch {
            throw .generationOverflow
        }
        entries = next
        return PluginCatalogChange(generation: generation, changed: changed)
    }
}
