//
//  PerformPanelLayout.swift
//  FluxKlang
//
//  The perform panel layout (#102 PNL1): sections by group, a row-major placement per width class, the fixed safety
//  strip, the focus order and the pickup announcements. A pure value; no view, no clock, no hardware.
//

/// The column count of the panel at each width class.
struct PerformPanelGrid: Equatable, Sendable {
    let regularColumns: Int
    let compactColumns: Int

    private init(regularColumns: Int, compactColumns: Int) {
        self.regularColumns = regularColumns
        self.compactColumns = compactColumns
    }

    /// Builds the grid, or refuses a column count outside `1...12` (regular) or `1...4` (compact); the regular count
    /// is checked first.
    static func make(regularColumns: Int, compactColumns: Int) throws(PerformPanelRefusal) -> PerformPanelGrid {
        guard PerformPanelLimits.regularColumns.contains(regularColumns) else {
            throw .regularColumnsOutOfRange(regularColumns)
        }
        guard PerformPanelLimits.compactColumns.contains(compactColumns) else {
            throw .compactColumnsOutOfRange(compactColumns)
        }
        return PerformPanelGrid(regularColumns: regularColumns, compactColumns: compactColumns)
    }

    func columns(for width: WorkspaceWidthClass) -> Int {
        switch width {
        case .regular: regularColumns
        case .compact: compactColumns
        }
    }
}

/// One placed cell. `row` and `column` count from zero.
struct PerformPanelCell: Equatable, Sendable {
    let kind: PerformControlKind
    let model: PerformCellModel
    let row: Int
    let column: Int

    fileprivate init(kind: PerformControlKind, model: PerformCellModel, row: Int, column: Int) {
        self.kind = kind
        self.model = model
        self.row = row
        self.column = column
    }
}

/// The cells of one group, in input order. `group` is nil for the one section of ungrouped entries.
struct PerformPanelSection: Equatable, Sendable {
    let group: String?
    let cells: [PerformPanelCell]

    fileprivate init(group: String?, cells: [PerformPanelCell]) {
        self.group = group
        self.cells = cells
    }
}

/// A perform panel for one width class. Only `make` builds one, so every layout has passed the checks documented on
/// `PerformPanelRefusal`; storage is `let`.
struct PerformPanelLayout: Equatable, Sendable {
    let width: WorkspaceWidthClass
    /// The grid's column count at `width`.
    let columns: Int
    /// One section per distinct group in order of first appearance; the ungrouped entries form one section.
    let sections: [PerformPanelSection]
    /// Always `[.panic, .safeMute]`: outside the grid, at every width, even for an empty panel.
    let safety: [CommandOperation]
    /// The same for every width: the safety operations, then each section's header (labelled sections) and cells.
    let focusOrder: [PerformPanelFocusStop]
    /// The parameter of every cell whose model announces a pickup, in focus order.
    let pickupAnnouncements: [ParameterID]

    private init(width: WorkspaceWidthClass, columns: Int, sections: [PerformPanelSection]) {
        self.width = width
        self.columns = columns
        self.sections = sections
        safety = Self.safetyStrip
        focusOrder = Self.focusOrder(safety: Self.safetyStrip, sections: sections)
        pickupAnnouncements = Self.announcements(of: sections)
    }

    /// Builds the layout, or throws the first failing check in the order documented on `PerformPanelRefusal`.
    ///
    /// `previous` is required: the layout the host showed before, or nil on first sight. A cell's previous model is
    /// looked up by parameter, never by position, so `announcesPickup` is true only on the update that moves a cell
    /// into waiting for pickup.
    static func make(entries: [PerformPanelEntry], grid: PerformPanelGrid, width: WorkspaceWidthClass,
                     previous: PerformPanelLayout?) throws(PerformPanelRefusal) -> PerformPanelLayout {
        guard entries.count <= PerformPanelLimits.maximumEntries else { throw .tooManyEntries(count: entries.count) }
        let models = try buildModels(of: entries, previous: previous)
        try rejectDuplicateTargets(models)
        try rejectDuplicateLabels(models)
        let columns = grid.columns(for: width)
        let sections = try buildSections(of: entries, models: models, columns: columns)
        return PerformPanelLayout(width: width, columns: columns, sections: sections)
    }

    private var modelsByParameter: [ParameterID: PerformCellModel] {
        var found: [ParameterID: PerformCellModel] = [:]
        for section in sections {
            for cell in section.cells { found[cell.model.parameterID] = cell.model }
        }
        return found
    }

    private static func buildModels(of entries: [PerformPanelEntry],
                                    previous: PerformPanelLayout?) throws(PerformPanelRefusal) -> [PerformCellModel] {
        let earlier = previous?.modelsByParameter ?? [:]
        var models: [PerformCellModel] = []
        for (index, entry) in entries.enumerated() {
            try validate(entry, at: index)
            do {
                let before = earlier[entry.input.descriptor.fields.id]
                models.append(try PerformCellModel.make(entry.input, previous: before))
            } catch {
                throw .cell(index: index, refusal: error)
            }
        }
        return models
    }

    private static func validate(_ entry: PerformPanelEntry, at index: Int) throws(PerformPanelRefusal) {
        if let group = entry.group {
            let bytes = group.utf8.count
            guard PerformPanelLimits.groupLabelBytes.contains(bytes) else {
                throw .invalidGroupLabel(index: index, bytes: bytes)
            }
        }
        let unit = entry.input.descriptor.fields.unit
        guard entry.kind.accepts(unit) else { throw .kindUnitMismatch(index: index, kind: entry.kind, unit: unit) }
    }

    private static func rejectDuplicateTargets(_ models: [PerformCellModel]) throws(PerformPanelRefusal) {
        var seen = Set<ParameterID>()
        for model in models {
            guard seen.insert(model.parameterID).inserted else { throw .duplicateTarget(model.parameterID) }
        }
    }

    private static func rejectDuplicateLabels(_ models: [PerformCellModel]) throws(PerformPanelRefusal) {
        var seen = Set<[UInt8]>()
        for (index, model) in models.enumerated() {
            guard seen.insert(Array(model.label.utf8)).inserted else { throw .duplicateLabel(index: index) }
        }
    }

    /// A section being built; `key` is the group's utf8 bytes, nil for the ungrouped section.
    private struct Draft {
        let group: String?
        let key: [UInt8]?
        var cells: [PerformPanelCell] = []
    }

    private static func buildSections(of entries: [PerformPanelEntry], models: [PerformCellModel],
                                      columns: Int) throws(PerformPanelRefusal) -> [PerformPanelSection] {
        var drafts: [Draft] = []
        for (entry, model) in zip(entries, models) {
            let key = entry.group.map { Array($0.utf8) }
            let slot: Int
            if let found = drafts.firstIndex(where: { $0.key == key }) {
                slot = found
            } else {
                drafts.append(Draft(group: entry.group, key: key))
                slot = drafts.count - 1
            }
            let position = drafts[slot].cells.count
            drafts[slot].cells.append(PerformPanelCell(kind: entry.kind, model: model, row: position / columns,
                                                       column: position % columns))
        }
        let groups = drafts.filter { $0.key != nil }.count
        guard groups <= PerformPanelLimits.maximumGroups else { throw .tooManyGroups(count: groups) }
        return drafts.map { PerformPanelSection(group: $0.group, cells: $0.cells) }
    }
}
