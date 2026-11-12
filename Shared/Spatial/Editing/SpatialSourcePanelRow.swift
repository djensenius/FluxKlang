//
//  SpatialSourcePanelRow.swift
//  FluxKlang
//
//  One adjustable row (X, Y or Width) of the spatial panel's selected-source section (#116 SSP1).
//  Nothing calls it yet.
//

/// What one adjustable row shows and offers. Applying an edit is the caller's job, through
/// `SpatialPlacementEditor.apply(_:)`.
struct SpatialSourcePanelRow: Hashable, Sendable, Identifiable {
    let axis: SpatialEditAxis
    let label: String
    let value: Double
    /// Two decimals, never `-0.00`.
    let numberText: String
    /// The position words of X and Y; the document gives Width none.
    let wordsText: String?
    let range: ClosedRange<Double>
    /// The adjustable element's spoken value, for example `slightly right of centre, 0.10`.
    let accessibilityValue: String
    let incrementEdit: SpatialPlacementEdit
    let decrementEdit: SpatialPlacementEdit

    var id: SpatialEditAxis { axis }

    /// Nil when the axis has no spoken value: Width on a mono source.
    static func make(_ axis: SpatialEditAxis, in placement: SpatialSourcePlacement) -> Self? {
        guard let spoken = SpatialPositionDescription.value(of: axis, in: placement) else { return nil }
        let value: Double
        let words: String?
        switch axis {
        case .x:
            value = placement.position.x
            words = SpatialPositionDescription.words(forX: value)
        case .y:
            value = placement.position.y
            words = SpatialPositionDescription.words(forY: value)
        case .width:
            value = placement.width
            words = nil
        }
        return Self(
            axis: axis, label: SpatialSourcePanelText.label(for: axis), value: value,
            numberText: SpatialPositionDescription.number(value), wordsText: words, range: axis.range,
            accessibilityValue: spoken, incrementEdit: .accessibilityIncrement(axis),
            decrementEdit: .accessibilityDecrement(axis)
        )
    }
}
