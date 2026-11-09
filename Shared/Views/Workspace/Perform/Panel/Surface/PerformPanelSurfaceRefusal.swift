//
//  PerformPanelSurfaceRefusal.swift
//  FluxKlang
//
//  Why `PerformPanelSurface.make` builds no surface (#102 PNS1).
//

/// The checks run in this order and the first failing one is thrown: the cell cap; then per entry, every XY entry in
/// index order and then every recall entry (an XY entry: class, label, targets); then repeated cell ids; repeated
/// parameters; repeated recall targets; repeated labels.
enum PerformPanelSurfaceRefusal: Error, Equatable, Sendable {
    /// The layout's cells plus the added cells exceed `PerformPanelLimits.maximumEntries`; `count` is the total.
    case tooManyCells(count: Int)
    /// An XY pad has no authorization step to show, so only a live class is performable.
    case classNotPerformable(PerformPanelSurfaceSlot, ControlClass)
    case emptyLabel(PerformPanelSurfaceSlot)
    case labelTooLong(PerformPanelSurfaceSlot, bytes: Int)
    case sameTargetOnBothAxes(PerformPanelSurfaceSlot)
    /// The later slot of two cells with the same id, in the order XY then recall.
    case duplicateCellID(PerformPanelSurfaceSlot)
    /// A parameter already used by a layout cell or an earlier XY pad axis.
    case duplicateTarget(ParameterID)
    /// The later recall entry with the same patch and variation.
    case duplicateRecallTarget(PerformPanelSurfaceSlot)
    /// The later slot whose label has the same UTF-8 bytes as an earlier cell's.
    case duplicateLabel(PerformPanelSurfaceSlot)
}
