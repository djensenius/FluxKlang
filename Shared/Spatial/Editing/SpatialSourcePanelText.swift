//
//  SpatialSourcePanelText.swift
//  FluxKlang
//
//  The fixed texts and the title builder of the spatial panel's selected-source section (#116 SSP1). Nothing
//  calls it yet. Strings quoted from docs/transformation/workspace-ux/spatial.md: `Selected: Soft Synth (src.synth)`
//  (line 18), the row names `X`, `Y` and `Width` (lines 19 to 21, 41, 42) and `[Move to speaker...] [Centre]` (22).
//  The title of a source without a name, `Selected: <id>`, is not in the document.
//

enum SpatialSourcePanelText {
    static let selectedPrefix = "Selected: "
    static let moveToSpeakerTitle = "Move to speaker..."
    static let centreTitle = "Centre"
    static let xLabel = "X"
    static let yLabel = "Y"
    static let widthLabel = "Width"

    /// `Selected: Soft Synth (src.synth)`, or `Selected: src.synth` when the source has no name.
    static func title(name: String?, id: String) -> String {
        guard let name else { return "\(selectedPrefix)\(id)" }
        return "\(selectedPrefix)\(name) (\(id))"
    }

    static func label(for axis: SpatialEditAxis) -> String {
        switch axis {
        case .x: xLabel
        case .y: yLabel
        case .width: widthLabel
        }
    }
}
