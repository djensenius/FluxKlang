//
//  ReviewSheetModel.swift
//  FluxKlang
//
//  The value model of the review sheet shown before a draft becomes active (#99 RV1): rows, provenance, hazards, the
//  stale banner and a default action that is the safe one unless every condition holds. It emits no command and
//  applies nothing; it holds no `ActivationRequest`. Only `make` builds a model, and a refusal builds none.
//

/// Everything the sheet shows, as plain values.
struct ReviewSheetInput: Hashable, Sendable {
    var diff: WiringReviewDiff
    var provenance: ReviewProvenance
    var hazards: [ReviewHazard]
    var staleness: ReviewStaleness
    var phase: ActivationPhase
    /// The active graph's revision; an activation would create the one after it.
    var activeRevision: ContractRevision
}

/// The size limits of a model. Only `make` and `standard` build one, so the bounds always hold.
struct ReviewSheetLimits: Hashable, Sendable {
    /// The values a caller may CHOOSE for `maximumRows`; not a bound on the number of rows of a model.
    static let rowBounds = 1...512
    /// The values a caller may choose for `maximumHazards`.
    static let hazardBounds = 0...64
    static let hazardIDBytes = 1...64
    static let hazardSummaryBytes = 1...160
    static let standard = ReviewSheetLimits(maximumRows: 512, maximumHazards: 64)

    /// The most CHANGES (rows of the diff) a model accepts; hazard rows are not counted against it.
    let maximumRows: Int
    /// The most hazards a model accepts; they are capped separately from the changes.
    let maximumHazards: Int

    private init(maximumRows: Int, maximumHazards: Int) {
        self.maximumRows = maximumRows
        self.maximumHazards = maximumHazards
    }

    static func make(maximumRows: Int, maximumHazards: Int) throws(ReviewSheetRefusal) -> ReviewSheetLimits {
        guard rowBounds.contains(maximumRows), hazardBounds.contains(maximumHazards) else {
            throw .invalidLimits(rows: maximumRows, hazards: maximumHazards)
        }
        return ReviewSheetLimits(maximumRows: maximumRows, maximumHazards: maximumHazards)
    }
}

/// Why `ReviewSheetModel.make` or `ReviewSheetLimits.make` refused. The refusals of `make` are checked in the order of
/// the cases below, from `revisionOverflow` to `duplicateHazardID`; nothing is trimmed, truncated or repaired.
enum ReviewSheetRefusal: Error, Hashable, Sendable {
    /// The limits are outside 1...512 rows or 0...64 hazards.
    case invalidLimits(rows: Int, hazards: Int)
    /// The active revision is `ContractRevision.maximumValue`, so no next revision exists.
    case revisionOverflow
    /// The stale report names another active revision than the input.
    case staleActiveRevisionMismatch(stale: ContractRevision, active: ContractRevision)
    /// The diff has more changes than the limit.
    case tooManyRows(count: Int, maximum: Int)
    /// There are more hazards than the limit.
    case tooManyHazards(count: Int, maximum: Int)
    /// A hazard id has no bytes or more than 64; names the smallest such id by bytes.
    case invalidHazardID(String)
    /// A hazard summary has no bytes or more than 160; names the smallest such hazard id by bytes.
    case invalidHazardSummary(id: String)
    /// Two hazards have byte-equal ids; names the smallest such id by bytes.
    case duplicateHazardID(String)

    /// Equality compares the hazard ids by UTF-8 bytes, so a refusal naming one id never equals a refusal naming a
    /// canonically equivalent but byte-different one. The last arm names every case on the left and has no default,
    /// so adding a case stops the build until its arm is written.
    static func == (lhs: ReviewSheetRefusal, rhs: ReviewSheetRefusal) -> Bool {
        switch (lhs, rhs) {
        case let (.invalidLimits(lhsRows, lhsHazards), .invalidLimits(rhsRows, rhsHazards)):
            lhsRows == rhsRows && lhsHazards == rhsHazards
        case (.revisionOverflow, .revisionOverflow):
            true
        case let (.staleActiveRevisionMismatch(lhsStale, lhsActive), .staleActiveRevisionMismatch(rhsStale, rhsActive)):
            lhsStale == rhsStale && lhsActive == rhsActive
        case let (.tooManyRows(lhsCount, lhsMaximum), .tooManyRows(rhsCount, rhsMaximum)):
            lhsCount == rhsCount && lhsMaximum == rhsMaximum
        case let (.tooManyHazards(lhsCount, lhsMaximum), .tooManyHazards(rhsCount, rhsMaximum)):
            lhsCount == rhsCount && lhsMaximum == rhsMaximum
        case let (.invalidHazardID(lhsID), .invalidHazardID(rhsID)):
            lhsID.utf8.elementsEqual(rhsID.utf8)
        case let (.invalidHazardSummary(lhsID), .invalidHazardSummary(rhsID)):
            lhsID.utf8.elementsEqual(rhsID.utf8)
        case let (.duplicateHazardID(lhsID), .duplicateHazardID(rhsID)):
            lhsID.utf8.elementsEqual(rhsID.utf8)
        case (.invalidLimits, _), (.revisionOverflow, _), (.staleActiveRevisionMismatch, _), (.tooManyRows, _),
             (.tooManyHazards, _), (.invalidHazardID, _), (.invalidHazardSummary, _), (.duplicateHazardID, _):
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .invalidLimits(let rows, let hazards):
            hasher.combine(0)
            hasher.combine(rows)
            hasher.combine(hazards)
        case .revisionOverflow:
            hasher.combine(1)
        case .staleActiveRevisionMismatch(let stale, let active):
            hasher.combine(2)
            hasher.combine(stale)
            hasher.combine(active)
        case .tooManyRows(let count, let maximum):
            hasher.combine(3)
            hasher.combine(count)
            hasher.combine(maximum)
        case .tooManyHazards(let count, let maximum):
            hasher.combine(4)
            hasher.combine(count)
            hasher.combine(maximum)
        case .invalidHazardID(let id):
            hasher.combine(5)
            ReviewHazard.combine(id, into: &hasher)
        case .invalidHazardSummary(let id):
            hasher.combine(6)
            ReviewHazard.combine(id, into: &hasher)
        case .duplicateHazardID(let id):
            hasher.combine(7)
            ReviewHazard.combine(id, into: &hasher)
        }
    }
}

/// The review sheet as a value: no mutating API, storage only `private(set)`, built only by `make`.
struct ReviewSheetModel: Hashable, Sendable {
    /// The change rows in the diff's order, then the hazard rows sorted by the UTF-8 bytes of their ids: at most
    /// `maximumRows + maximumHazards` entries (576 with `standard`).
    private(set) var rows: [ReviewRow]
    private(set) var provenance: ReviewProvenance
    private(set) var phase: ActivationPhase
    private(set) var defaultAction: ReviewDefaultAction
    /// Present for a stale review; carries both revisions and the revalidate state.
    private(set) var staleBanner: ReviewStaleBanner?
    /// The revision an activation would create ("Creates rev N+1"); `nil` when the diff has no change.
    private(set) var creates: ContractRevision?
    /// False when stale, when a hazard blocks activation or when the diff has no change. It does not cover the
    /// assistant confirmation (`needsExtraConfirmation`) or the activation phase; `defaultAction` carries them.
    private(set) var canActivate: Bool

    /// True when activating needs one more explicit confirmation.
    var needsExtraConfirmation: Bool { provenance.needsExtraConfirmation }

    private init(
        rows: [ReviewRow], input: ReviewSheetInput, creates: ContractRevision?, canActivate: Bool, hasHazards: Bool
    ) {
        self.rows = rows
        provenance = input.provenance
        phase = input.phase
        staleBanner = input.staleness.banner
        self.creates = creates
        self.canActivate = canActivate
        defaultAction = ReviewDefaultAction.choose(
            canActivate: canActivate, hasHazards: hasHazards, provenance: input.provenance, phase: input.phase
        )
    }

    /// What `key` does with the sheet: Return takes the default, Escape keeps the draft.
    func resolve(_ key: ReviewKeyBinding) -> ReviewDefaultAction {
        key.resolve(defaultAction: defaultAction)
    }

    /// Refusals, in this order: `revisionOverflow`, `staleActiveRevisionMismatch`, `tooManyRows`, `tooManyHazards`,
    /// then the hazards (`invalidHazardID`, `invalidHazardSummary`, `duplicateHazardID`). The row count is checked
    /// before any row is built and the hazard count before any hazard is inspected. `limits.maximumRows` caps the
    /// changes of the diff only and `limits.maximumHazards` the hazards, so a model has up to their sum as rows.
    static func make(
        _ input: ReviewSheetInput, limits: ReviewSheetLimits
    ) throws(ReviewSheetRefusal) -> ReviewSheetModel {
        let next = try nextRevision(after: input.activeRevision)
        try requireSameActiveRevision(input)
        let changeCount = ReviewRow.changeCount(of: input.diff)
        guard changeCount <= limits.maximumRows else {
            throw .tooManyRows(count: changeCount, maximum: limits.maximumRows)
        }
        guard input.hazards.count <= limits.maximumHazards else {
            throw .tooManyHazards(count: input.hazards.count, maximum: limits.maximumHazards)
        }
        let hazards = try ReviewHazard.checked(input.hazards)
        let rows = ReviewRow.changeRows(of: input.diff) + hazards.map(ReviewRow.hazard)
        let blocked = hazards.contains { $0.blocksActivation }
        let canActivate = input.staleness.banner == nil && !blocked && changeCount > 0
        return ReviewSheetModel(
            rows: rows, input: input, creates: changeCount > 0 ? next : nil,
            canActivate: canActivate, hasHazards: !hazards.isEmpty
        )
    }

    private static func nextRevision(after revision: ContractRevision) throws(ReviewSheetRefusal) -> ContractRevision {
        do {
            return try revision.next()
        } catch {
            throw .revisionOverflow
        }
    }

    private static func requireSameActiveRevision(_ input: ReviewSheetInput) throws(ReviewSheetRefusal) {
        guard let banner = input.staleness.banner, banner.activeRevision != input.activeRevision else { return }
        throw .staleActiveRevisionMismatch(stale: banner.activeRevision, active: input.activeRevision)
    }
}
