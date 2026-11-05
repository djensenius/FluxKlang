//
//  WorkspaceNavigationModel.swift
//  FluxKlang
//
//  The pure navigation state of the workspace shell (#99): each window's
//  surface, Edit/Perform mode, width class, selection, inspector request and
//  project, each project's revision, plus the presentation derived from them. Layout follows width; mode and
//  permissions never do (workspace-ux README principle 4, perform.md "Edit
//  versus Perform"). Only `WorkspaceNavigationState.apply(_:)` changes the state:
//  it reduces an action on a private staged transition and commits it only after
//  every check passes, so a refusal leaves the state unchanged. Nothing reads a
//  clock, randomness or global state.
//

import Foundation

/// A sidebar group. Advanced is collapsed unless expanded or in use.
enum WorkspaceSurfaceGroup: String, CaseIterable, Hashable, Sendable {
    case create
    case perform
    case help
    case advanced
}

/// A top-level workspace surface.
enum WorkspaceSurface: String, CaseIterable, Hashable, Sendable {
    case wiring
    case perform
    case spatial
    case library
    case diagnostics
    case assistant
    case help
    case compatibility

    var group: WorkspaceSurfaceGroup {
        switch self {
        case .wiring, .spatial, .library: .create
        case .perform: .perform
        case .assistant, .help: .help
        case .diagnostics, .compatibility: .advanced
        }
    }

    /// The compact tab that hosts this surface; the surface itself is unchanged.
    var compactTab: WorkspaceCompactTab {
        switch self {
        case .wiring: .wiring
        case .perform: .perform
        case .spatial: .spatial
        case .library, .diagnostics, .assistant, .help, .compatibility: .more
        }
    }
}

/// Perform hides layout handles and wiring affordances. Neither mode changes
/// permissions, and neither is chosen by width.
enum WorkspaceMode: Hashable, Sendable {
    case edit
    case perform

    var showsLayoutHandles: Bool { self == .edit }
    var showsWiringAffordances: Bool { self == .edit }
}

enum WorkspaceWidthClass: Hashable, Sendable {
    case regular
    case compact
}

/// A selectable graph item, keyed by its kind and stable contract IDs. A `GraphPort` ID is
/// unique only within its node, so a port is keyed by its owning node and its port ID
/// together: two nodes' `out` ports are different items. Not Codable; W1 never persists it.
enum WorkspaceItemRef: Hashable, Sendable {
    case node(NodeID)
    case port(node: NodeID, port: PortID)
    case edge(EdgeID)

    /// Whether a revision whose items are `present` still has this item. A port also
    /// needs its owning node, because `GraphDocument` removes a node together with its
    /// ports. `removeNode` also drops the edges touching the node; an edge is keyed by
    /// its graph-unique ID alone, so `present` must omit those edges itself.
    func isPresent(in present: Set<WorkspaceItemRef>) -> Bool {
        switch self {
        case .node, .edge: present.contains(self)
        case let .port(node, _): present.contains(self) && present.contains(.node(node))
        }
    }
}

/// A selected item. An item missing from an applied revision stays selected as
/// `.removed`, so the inspector can say "Removed in rev N" instead of going blank.
enum WorkspaceSelectionEntry: Hashable, Sendable {
    case live(WorkspaceItemRef)
    // swiftlint:disable:next identifier_name
    case removed(WorkspaceItemRef, in: ContractRevision)

    var item: WorkspaceItemRef {
        switch self {
        case let .live(item), let .removed(item, _): item
        }
    }
}

/// One window's navigation. A new window shows Wiring in Edit mode at regular
/// width, with nothing selected and no inspector; it never copies another window.
struct WorkspaceWindowState: Equatable, Sendable {
    var surface: WorkspaceSurface = .wiring
    var mode: WorkspaceMode = .edit
    var widthClass: WorkspaceWidthClass = .regular
    /// Ordered and duplicate-free by item.
    var selection: [WorkspaceSelectionEntry] = []
    var inspectorRequested = false
}

/// The navigation of every workspace window on one host. It holds no
/// permissions. Only `apply(_:)` changes it, and a refusal leaves it unchanged.
///
/// Every window is bound to one project when it opens. A project is open while any
/// of its windows is, and its revision state lives exactly that long: revisions are
/// monotonic per project, and closing a project's last window discards its revision.
struct WorkspaceNavigationState: Equatable, Sendable {
    static let maxWindows = 16
    static let maxProjects = 8
    static let maxSelection = 256

    private(set) var windows: [WindowID: WorkspaceWindowState] = [:]
    /// The project of each open window; its keys are exactly the keys of `windows`.
    private(set) var windowProjects: [WindowID: ProjectID] = [:]
    /// Shared by every window of every project; it stays expanded while any window shows an advanced surface.
    private(set) var isAdvancedExpanded = false
    /// The newest revision applied to each open project's selections; only open projects have one.
    private(set) var lastAppliedRevisions: [ProjectID: ContractRevision] = [:]

    init() {}

    /// The projects with at least one open window.
    var openProjects: Set<ProjectID> { Set(windowProjects.values) }

    /// nil if `project` has no applied revision or no open window.
    func lastAppliedRevision(for project: ProjectID) -> ContractRevision? { lastAppliedRevisions[project] }

    /// Reduces `action` on a staged transition and commits it only if every check passes.
    mutating func apply(_ action: WorkspaceNavigationAction) throws(WorkspaceNavigationError) {
        var transition = WorkspaceNavigationTransition(self)
        try transition.reduce(action)
        commit(transition)
    }

    func presentation(for window: WindowID) throws(WorkspaceNavigationError) -> WorkspaceShellPresentation {
        guard let state = windows[window] else { throw .unknownWindow(window) }
        return WorkspaceShellPresentation(window: state, advancedGroupExpanded: isAdvancedExpanded)
    }

    private mutating func commit(_ transition: WorkspaceNavigationTransition) {
        windows = transition.windows
        windowProjects = transition.windowProjects
        isAdvancedExpanded = transition.isAdvancedExpanded
        lastAppliedRevisions = transition.lastAppliedRevisions
    }
}

// MARK: - Reducing

/// A staged copy of the state that one action edits. Only `WorkspaceNavigationState.apply(_:)`
/// creates and commits one, and only after every check has passed.
private struct WorkspaceNavigationTransition {
    var windows: [WindowID: WorkspaceWindowState]
    var windowProjects: [WindowID: ProjectID]
    var isAdvancedExpanded: Bool
    var lastAppliedRevisions: [ProjectID: ContractRevision]

    init(_ state: WorkspaceNavigationState) {
        windows = state.windows
        windowProjects = state.windowProjects
        isAdvancedExpanded = state.isAdvancedExpanded
        lastAppliedRevisions = state.lastAppliedRevisions
    }

    mutating func reduce(_ action: WorkspaceNavigationAction) throws(WorkspaceNavigationError) {
        switch action {
        case let .openWindow(window, project):
            try open(window, project: project)
        case let .closeWindow(window):
            try close(window)
        case let .setAdvancedExpanded(expanded):
            try setAdvancedExpanded(expanded)
        case let .revisionApplied(revision, project, present):
            try applyRevision(revision, project: project, present: present)
        case let .selectSurface(_, window), let .setMode(_, window), let .setWidthClass(_, window),
             let .select(_, window), let .clearSelection(window), let .setInspectorRequested(_, window):
            try edit(window, with: action)
        }
    }

    private var openProjects: Set<ProjectID> { Set(windowProjects.values) }

    /// Refuses a duplicate window, then a full host, then a new project beyond `maxProjects`.
    private mutating func open(_ window: WindowID, project: ProjectID) throws(WorkspaceNavigationError) {
        guard windows[window] == nil else { throw .duplicateWindow(window) }
        let maxWindows = WorkspaceNavigationState.maxWindows
        guard windows.count < maxWindows else { throw .windowLimitExceeded(maximum: maxWindows) }
        let projects = openProjects
        let maxProjects = WorkspaceNavigationState.maxProjects
        guard projects.contains(project) || projects.count < maxProjects else {
            throw .projectLimitExceeded(maximum: maxProjects)
        }
        windows[window] = WorkspaceWindowState()
        windowProjects[window] = project
    }

    /// Discards the project's revision with its last window, so a reopened project starts fresh.
    private mutating func close(_ window: WindowID) throws(WorkspaceNavigationError) {
        guard windows[window] != nil, let project = windowProjects[window] else { throw .unknownWindow(window) }
        windows[window] = nil
        windowProjects[window] = nil
        if !openProjects.contains(project) { lastAppliedRevisions[project] = nil }
    }

    /// Changes only the named window's own fields, plus Advanced when it selects an advanced surface.
    private mutating func edit(
        _ window: WindowID, with action: WorkspaceNavigationAction
    ) throws(WorkspaceNavigationError) {
        guard var state = windows[window] else { throw .unknownWindow(window) }
        switch action {
        case let .selectSurface(surface, _):
            state.surface = surface
            if surface.group == .advanced { isAdvancedExpanded = true }
        case let .setMode(mode, _):
            state.mode = mode
        case let .setWidthClass(widthClass, _):
            state.widthClass = widthClass
        case let .select(items, _):
            state.selection = try Self.liveSelection(items)
        case .clearSelection:
            state.selection = []
        case let .setInspectorRequested(requested, _):
            state.inspectorRequested = requested
        case .openWindow, .closeWindow, .setAdvancedExpanded, .revisionApplied:
            return // Not window-scoped; `reduce(_:)` handles these itself.
        }
        windows[window] = state
    }

    private mutating func setAdvancedExpanded(_ expanded: Bool) throws(WorkspaceNavigationError) {
        if !expanded, let inUse = windows.filter({ $0.value.surface.group == .advanced }).keys.min() {
            throw .advancedInUse(inUse)
        }
        isAdvancedExpanded = expanded
    }

    /// Checks and marks only `project`'s windows; other projects keep their selections and revisions.
    private mutating func applyRevision(
        _ revision: ContractRevision, project: ProjectID, present: Set<WorkspaceItemRef>
    ) throws(WorkspaceNavigationError) {
        guard openProjects.contains(project) else { throw .unknownProject(project) }
        if let last = lastAppliedRevisions[project], revision <= last { throw .staleRevision(revision) }
        for (id, owner) in windowProjects where owner == project {
            guard var window = windows[id] else { continue }
            window.selection = window.selection.map { entry in
                guard case let .live(item) = entry, !item.isPresent(in: present) else { return entry }
                return .removed(item, in: revision)
            }
            windows[id] = window
        }
        lastAppliedRevisions[project] = revision
    }

    /// Refuses over-limit or duplicate input instead of truncating or deduplicating it.
    private static func liveSelection(
        _ items: [WorkspaceItemRef]
    ) throws(WorkspaceNavigationError) -> [WorkspaceSelectionEntry] {
        let maximum = WorkspaceNavigationState.maxSelection
        guard items.count <= maximum else { throw .selectionLimitExceeded(maximum: maximum) }
        var seen = Set<WorkspaceItemRef>()
        for item in items where !seen.insert(item).inserted {
            throw .duplicateSelectionItem(item)
        }
        return items.map(WorkspaceSelectionEntry.live)
    }
}

// MARK: - Presentation

/// The primary tabs at compact width; every other surface is reached through More.
enum WorkspaceCompactTab: String, CaseIterable, Hashable, Sendable {
    case wiring
    case perform
    case spatial
    case more
}

enum WorkspaceShellLayout: Hashable, Sendable {
    /// Regular width: a sidebar of groups beside the surface.
    case split(sidebarGroups: [WorkspaceSurfaceGroup])
    case compact(primaryTabs: [WorkspaceCompactTab], activeTab: WorkspaceCompactTab)
}

/// Where the inspector appears; its content and permissions are the same in both.
enum WorkspaceInspectorPlacement: Hashable, Sendable {
    case trailingPanel
    case sheet
}

/// What the shell shows for one window, derived only from the navigation state.
struct WorkspaceShellPresentation: Hashable, Sendable {
    /// The window's real surface, including one shown under More.
    let surface: WorkspaceSurface
    let layout: WorkspaceShellLayout
    /// nil unless the window requested the inspector.
    let inspectorPlacement: WorkspaceInspectorPlacement?
    let advancedGroupExpanded: Bool
    let showsLayoutHandles: Bool
    let showsWiringAffordances: Bool

    /// Panic and Safe Mute stay reachable in every mode, width and surface.
    var safetyControlsReachable: Bool { true }

    fileprivate init(window: WorkspaceWindowState, advancedGroupExpanded: Bool) {
        surface = window.surface
        switch window.widthClass {
        case .regular:
            let groups = WorkspaceSurfaceGroup.allCases.filter { $0 != .advanced || advancedGroupExpanded }
            layout = .split(sidebarGroups: groups)
            inspectorPlacement = window.inspectorRequested ? .trailingPanel : nil
        case .compact:
            layout = .compact(primaryTabs: WorkspaceCompactTab.allCases, activeTab: window.surface.compactTab)
            inspectorPlacement = window.inspectorRequested ? .sheet : nil
        }
        self.advancedGroupExpanded = advancedGroupExpanded
        showsLayoutHandles = window.mode.showsLayoutHandles
        showsWiringAffordances = window.mode.showsWiringAffordances
    }
}
