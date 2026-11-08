//
//  PerformPanelRefusal.swift
//  FluxKlang
//
//  Typed refusals of the perform panel layout (#102 PNL1).
//

/// Why a grid or a panel layout is not built. Nothing is dropped or truncated to avoid a refusal.
///
/// `PerformPanelLayout.make` checks in this order and the first failing check decides: `tooManyEntries`; then the
/// entries in index order (a group label, then the kind against the unit, then the cell); then `duplicateTarget`;
/// then `duplicateLabel`; then `tooManyGroups`.
enum PerformPanelRefusal: Error, Equatable, Sendable {
    case regularColumnsOutOfRange(Int)
    case compactColumnsOutOfRange(Int)
    /// More entries than `PerformPanelLimits.maximumEntries`.
    case tooManyEntries(count: Int)
    /// The group label of the entry at `index` has no utf8 bytes or more than 64.
    case invalidGroupLabel(index: Int, bytes: Int)
    /// A button needs a boolean parameter; a fader or a knob needs a parameter that is not boolean.
    case kindUnitMismatch(index: Int, kind: PerformControlKind, unit: ParameterUnit)
    /// `PerformCellModel.make` refused the entry at `index`.
    case cell(index: Int, refusal: PerformCellRefusal)
    /// The second entry, in index order, for a parameter that already has a cell.
    case duplicateTarget(ParameterID)
    /// The later entry of two cells whose labels have the same unicode scalars.
    case duplicateLabel(index: Int)
    /// More distinct group labels than `PerformPanelLimits.maximumGroups`.
    case tooManyGroups(count: Int)
}
