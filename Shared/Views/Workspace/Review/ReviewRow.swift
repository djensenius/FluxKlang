//
//  ReviewRow.swift
//  FluxKlang
//
//  One row of the review sheet and the caller-supplied hazard it can show (#99 RV1). A hazard is a plain value the
//  caller built, so it is re-validated here at the point of use. Text is measured and ordered by UTF-8 bytes, never by
//  Character counts or Swift `String` equality (canonical equivalence), and a summary is stored unchanged.
//

/// The kind of a row, in the order the sheet lists them: the diff's kinds, then hazards.
enum ReviewRowKind: Hashable, Sendable, CaseIterable {
    case addedNode
    case movedNode
    case removedNode
    case addedEdge
    case removedEdge
    case hazard
}

/// A caller-supplied hazard. The review never infers one.
struct ReviewHazard: Hashable, Sendable {
    /// 1...`ReviewSheetLimits.hazardIDBytes` UTF-8 bytes.
    var id: String
    /// 1...`ReviewSheetLimits.hazardSummaryBytes` UTF-8 bytes; shown as given.
    var summary: String
    /// True when the review cannot be activated while this hazard stands.
    var blocksActivation: Bool

    /// The hazards in UTF-8 byte order of their ids, or the first refusal in the documented order: an invalid id,
    /// an invalid summary, a repeated id. Each refusal names the smallest offending id by bytes, so the result and the
    /// refusal do not depend on the order the caller gave the hazards in.
    static func checked(_ hazards: [ReviewHazard]) throws(ReviewSheetRefusal) -> [ReviewHazard] {
        let badID = hazards.filter { !ReviewSheetLimits.hazardIDBytes.contains($0.id.utf8.count) }
        if let offender = badID.map(\.id).min(by: bytesPrecede) { throw .invalidHazardID(offender) }
        let badSummary = hazards.filter { !ReviewSheetLimits.hazardSummaryBytes.contains($0.summary.utf8.count) }
        if let offender = badSummary.map(\.id).min(by: bytesPrecede) { throw .invalidHazardSummary(id: offender) }
        let sorted = hazards.sorted { bytesPrecede($0.id, $1.id) }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where earlier.id.utf8.elementsEqual(later.id.utf8) {
            throw .duplicateHazardID(earlier.id)
        }
        return sorted
    }

    private static func bytesPrecede(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

/// One row of the sheet: a change of the diff, or a hazard.
enum ReviewRow: Hashable, Sendable {
    case change(WiringReviewChange)
    case hazard(ReviewHazard)

    var kind: ReviewRowKind {
        switch self {
        case .change(let change): ReviewRowKind(change.kind)
        case .hazard: .hazard
        }
    }

    /// The raw node, edge or hazard id the row is about.
    var subject: String {
        switch self {
        case .change(let change): change.sortID
        case .hazard(let hazard): hazard.id
        }
    }

    /// True for a hazard that blocks activation.
    var blocksActivation: Bool {
        switch self {
        case .change: false
        case .hazard(let hazard): hazard.blocksActivation
        }
    }
}
