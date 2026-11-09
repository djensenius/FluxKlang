//
//  PerformPanelSurface+Checks.swift
//  FluxKlang
//
//  The checks of `PerformPanelSurface.make` after the cell cap, in the order documented on
//  `PerformPanelSurfaceRefusal` (#102 PNS1). Each identity check builds one Set and fills it once.
//

extension PerformPanelSurface {
    static func validate(layout: PerformPanelLayout, pads: [PerformPanelSurfaceXYEntry],
                         recalls: [PerformPanelSurfaceRecallEntry]) throws(PerformPanelSurfaceRefusal) {
        try checkEntries(pads: pads, recalls: recalls)
        try rejectDuplicateIDs(pads: pads, recalls: recalls)
        try rejectDuplicateTargets(layout: layout, pads: pads)
        try rejectDuplicateRecallTargets(recalls)
        try rejectDuplicateLabels(layout: layout, pads: pads, recalls: recalls)
    }

    private static func checkEntries(pads: [PerformPanelSurfaceXYEntry],
                                     recalls: [PerformPanelSurfaceRecallEntry]) throws(PerformPanelSurfaceRefusal) {
        for (index, entry) in pads.enumerated() {
            let slot = PerformPanelSurfaceSlot.xy(index)
            guard entry.controlClass == .live else { throw .classNotPerformable(slot, entry.controlClass) }
            try checkLabel(entry.label, slot: slot)
            guard !entry.xTarget.rawValue.utf8.elementsEqual(entry.yTarget.rawValue.utf8) else {
                throw .sameTargetOnBothAxes(slot)
            }
        }
        for (index, entry) in recalls.enumerated() {
            try checkLabel(entry.label, slot: .recall(index))
        }
    }

    private static func checkLabel(_ label: String, slot: PerformPanelSurfaceSlot) throws(PerformPanelSurfaceRefusal) {
        let bytes = label.utf8.count
        guard bytes >= PerformCellLimits.labelBytes.lowerBound else { throw .emptyLabel(slot) }
        guard bytes <= PerformCellLimits.labelBytes.upperBound else { throw .labelTooLong(slot, bytes: bytes) }
    }

    private static func rejectDuplicateIDs(
        pads: [PerformPanelSurfaceXYEntry], recalls: [PerformPanelSurfaceRecallEntry]
    ) throws(PerformPanelSurfaceRefusal) {
        var seen = Set<PerformPanelSurfaceCellID>()
        for (index, entry) in pads.enumerated() {
            guard seen.insert(entry.id).inserted else { throw .duplicateCellID(.xy(index)) }
        }
        for (index, entry) in recalls.enumerated() {
            guard seen.insert(entry.id).inserted else { throw .duplicateCellID(.recall(index)) }
        }
    }

    private static func rejectDuplicateTargets(
        layout: PerformPanelLayout, pads: [PerformPanelSurfaceXYEntry]
    ) throws(PerformPanelSurfaceRefusal) {
        var seen = Set<ParameterID>()
        for section in layout.sections {
            for cell in section.cells { seen.insert(cell.model.parameterID) }
        }
        for entry in pads {
            guard seen.insert(entry.xTarget).inserted else { throw .duplicateTarget(entry.xTarget) }
            guard seen.insert(entry.yTarget).inserted else { throw .duplicateTarget(entry.yTarget) }
        }
    }

    /// A recall target as a hashable key: `PerformRecallTarget` itself is not Hashable.
    private struct RecallKey: Hashable {
        let patch: PatchID
        let variation: PerformRecallVariationID?
    }

    private static func rejectDuplicateRecallTargets(
        _ recalls: [PerformPanelSurfaceRecallEntry]
    ) throws(PerformPanelSurfaceRefusal) {
        var seen = Set<RecallKey>()
        for (index, entry) in recalls.enumerated() {
            let key = RecallKey(patch: entry.target.patch, variation: entry.target.variation)
            guard seen.insert(key).inserted else { throw .duplicateRecallTarget(.recall(index)) }
        }
    }

    private static func rejectDuplicateLabels(
        layout: PerformPanelLayout, pads: [PerformPanelSurfaceXYEntry], recalls: [PerformPanelSurfaceRecallEntry]
    ) throws(PerformPanelSurfaceRefusal) {
        var seen = Set<[UInt8]>()
        for section in layout.sections {
            for cell in section.cells { seen.insert(Array(cell.model.label.utf8)) }
        }
        for (index, entry) in pads.enumerated() {
            guard seen.insert(Array(entry.label.utf8)).inserted else { throw .duplicateLabel(.xy(index)) }
        }
        for (index, entry) in recalls.enumerated() {
            guard seen.insert(Array(entry.label.utf8)).inserted else { throw .duplicateLabel(.recall(index)) }
        }
    }
}
