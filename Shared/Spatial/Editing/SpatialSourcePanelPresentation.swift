//
//  SpatialSourcePanelPresentation.swift
//  FluxKlang
//
//  What the spatial panel's selected-source section shows and offers for one source (#116 SSP1): the title,
//  the X, Y and Width rows, the "Move to speaker..." and "Centre" controls and the VoiceOver move actions.
//  A pure value composed from `SpatialPositionDescription` and the editor's own actions. Nothing calls it yet.
//  See docs/transformation/workspace-ux/spatial.md lines 18 to 22, 41 to 43 and 48.
//

struct SpatialSourcePanelPresentation: Hashable, Sendable {
    let source: SpatialSourceID
    let title: String
    /// The source element's spoken label, as `SpatialPositionDescription.describe(_:)` reads it.
    let accessibilityLabel: String
    /// X, then Y, then Width for a stereo source only.
    let rows: [SpatialSourcePanelRow]
    let moveToSpeakerTitle: String
    /// The editor's move actions without the centre action, in layout order.
    let speakerActions: [SpatialPlacementAction]
    let centreTitle: String
    let centreEdit: SpatialPlacementEdit
    /// The VoiceOver custom actions: the speakers in layout order, then "Move to centre".
    let moveActions: [SpatialPlacementAction]

    private init(
        source: SpatialSourceID, title: String, accessibilityLabel: String, rows: [SpatialSourcePanelRow],
        speakerActions: [SpatialPlacementAction], moveActions: [SpatialPlacementAction]
    ) {
        self.source = source
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.rows = rows
        self.moveToSpeakerTitle = SpatialSourcePanelText.moveToSpeakerTitle
        self.speakerActions = speakerActions
        self.centreTitle = SpatialSourcePanelText.centreTitle
        self.centreEdit = .snap(.centre)
        self.moveActions = moveActions
    }

    static func make(_ editor: SpatialPlacementEditor) -> SpatialSourcePanelPresentation {
        let placement = editor.placement
        let moveActions = editor.moveActions
        return SpatialSourcePanelPresentation(
            source: placement.sourceID,
            title: SpatialSourcePanelText.title(name: placement.name, id: placement.sourceID.rawValue),
            accessibilityLabel: SpatialPositionDescription.describe(placement),
            rows: [SpatialEditAxis.x, .y, .width].compactMap { SpatialSourcePanelRow.make($0, in: placement) },
            speakerActions: moveActions.filter { $0.edit != .snap(.centre) },
            moveActions: moveActions
        )
    }
}
