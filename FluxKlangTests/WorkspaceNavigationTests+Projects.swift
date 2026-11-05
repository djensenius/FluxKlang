//
//  WorkspaceNavigationTests+Projects.swift
//  FluxKlangTests
//
//  Per-project workspace navigation (#99 W2): window-to-project binding,
//  per-project revisions, project lifetime, the project bound and isolation.
//  It also holds the W1 compatibility shim that the W1 suites compile against.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - W1 compatibility shim (test-only)

// W1 compatibility shim: the W1 suites predate project binding and still spell
// `openWindow(_:)`, `revisionApplied(_:present:)` and `lastAppliedRevision`. These
// test-only forms bind all of them to the single fixed project `w1Project`; production
// has no implicit or default project.
extension WorkspaceNavigationTests {
    static let w1Project = ProjectID(validated: "prj.w1")
}

extension WorkspaceNavigationAction {
    /// W1 compatibility shim: opens `window` in `WorkspaceNavigationTests.w1Project`.
    static func openWindow(_ window: WindowID) -> Self {
        .openWindow(window, project: WorkspaceNavigationTests.w1Project)
    }

    /// W1 compatibility shim: applies `revision` to `WorkspaceNavigationTests.w1Project`.
    static func revisionApplied(_ revision: ContractRevision, present: Set<WorkspaceItemRef>) -> Self {
        .revisionApplied(revision, project: WorkspaceNavigationTests.w1Project, present: present)
    }
}

extension WorkspaceNavigationState {
    /// W1 compatibility shim: the revision of `WorkspaceNavigationTests.w1Project`.
    var lastAppliedRevision: ContractRevision? { lastAppliedRevision(for: WorkspaceNavigationTests.w1Project) }
}

// MARK: - Per-project navigation

extension WorkspaceNavigationTests {
    struct Projects {
        static let projectP = ProjectID(validated: "prj.p")
        static let projectQ = ProjectID(validated: "prj.q")
        static let windowP1 = WindowID(validated: "win.p1")
        static let windowP2 = WindowID(validated: "win.p2")
        static let windowQ1 = WindowID(validated: "win.q1")
        static let item = NodeID(validated: "nod.1")
        static let port = Root.port("prt.a")

        /// p1 and p2 on P, q1 on Q; each selects `nod.1` and `prt.a`; no revision applied.
        static func twoProjects() throws -> WorkspaceNavigationState {
            try applying([
                .openWindow(windowP1, project: projectP), .openWindow(windowQ1, project: projectQ),
                .openWindow(windowP2, project: projectP),
                .select([.node(item), port], window: windowP1), .select([.node(item), port], window: windowP2),
                .select([.node(item), port], window: windowQ1)
            ])
        }

        /// Applies `actions` in order, checking the binding and lifetime invariants after each one.
        static func applying(
            _ actions: [WorkspaceNavigationAction], to start: WorkspaceNavigationState = WorkspaceNavigationState(),
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> WorkspaceNavigationState {
            var state = start
            for action in actions {
                try state.apply(action)
                expectInvariants(state, sourceLocation: sourceLocation)
            }
            return state
        }

        static func expectInvariants(_ state: WorkspaceNavigationState, sourceLocation: SourceLocation) {
            #expect(Set(state.windowProjects.keys) == Set(state.windows.keys), sourceLocation: sourceLocation)
            let tracked = Set(state.lastAppliedRevisions.keys)
            #expect(tracked.isSubset(of: state.openProjects), sourceLocation: sourceLocation)
            #expect(state.openProjects.count <= WorkspaceNavigationState.maxProjects, sourceLocation: sourceLocation)
            #expect(state.windows.count <= WorkspaceNavigationState.maxWindows, sourceLocation: sourceLocation)
        }

        static func revision(_ value: Int) throws -> ContractRevision { try Root.revision(value) }

        /// A revision of `project` in which nothing is present.
        static func revise(_ revision: ContractRevision, _ project: ProjectID) -> WorkspaceNavigationAction {
            .revisionApplied(revision, project: project, present: [])
        }

        static func expectStale(
            _ revision: ContractRevision, _ project: ProjectID, on state: WorkspaceNavigationState,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            Root.expectRefusal(
                .staleRevision(revision), applying: revise(revision, project), to: state, sourceLocation: sourceLocation
            )
        }

        @Test func openingBindsTheWindowToItsProject() throws {
            let state = try Self.twoProjects()
            #expect(state.windowProjects == [
                Self.windowP1: Self.projectP, Self.windowP2: Self.projectP, Self.windowQ1: Self.projectQ
            ])
            #expect(state.openProjects == [Self.projectP, Self.projectQ])
            #expect(state.lastAppliedRevisions.isEmpty)
            let opened = try Self.applying([.openWindow(Self.windowP1, project: Self.projectQ)])
            #expect(opened.windows == [Self.windowP1: WorkspaceWindowState()])
            #expect(opened.windowProjects == [Self.windowP1: Self.projectQ])
        }

        @Test func revisionsAreMonotonicPerProjectWhileItsWindowsAreOpen() throws {
            let (one, four) = (try Self.revision(1), try Self.revision(4))
            let (five, six) = (try Self.revision(5), try Self.revision(6))
            var state = try Self.applying([Self.revise(five, Self.projectP)], to: Self.twoProjects())
            state = try Self.applying([Self.revise(one, Self.projectQ)], to: state)
            #expect(state.lastAppliedRevision(for: Self.projectP) == five)
            #expect(state.lastAppliedRevision(for: Self.projectQ) == one)
            for stale in [four, five] {
                Self.expectStale(stale, Self.projectP, on: state)
            }
            Self.expectStale(one, Self.projectQ, on: state)
            state = try Self.applying([Self.revise(six, Self.projectP)], to: state)
            #expect(state.lastAppliedRevisions == [Self.projectP: six, Self.projectQ: one])
        }

        @Test func aRevisionMarksOnlyItsProjectsWindows() throws {
            let before = try Self.twoProjects()
            let two = try Self.revision(2)
            let after = try Self.applying([Self.revise(two, Self.projectP)], to: before)
            let removed: [WorkspaceSelectionEntry] = [.removed(.node(Self.item), in: two), .removed(Self.port, in: two)]
            #expect(after.windows[Self.windowP1]?.selection == removed)
            #expect(after.windows[Self.windowP2]?.selection == removed)
            #expect(after.windows[Self.windowQ1] == before.windows[Self.windowQ1])
            #expect(after.lastAppliedRevision(for: Self.projectQ) == nil)
        }

        @Test func aStaleRevisionForOneProjectLeavesTheOtherProjectApplicable() throws {
            let (one, three) = (try Self.revision(1), try Self.revision(3))
            let state = try Self.applying([Self.revise(three, Self.projectP)], to: Self.twoProjects())
            Self.expectStale(one, Self.projectP, on: state)
            let after = try Self.applying([Self.revise(one, Self.projectQ)], to: state)
            let removed: [WorkspaceSelectionEntry] = [.removed(.node(Self.item), in: one), .removed(Self.port, in: one)]
            #expect(after.windows[Self.windowQ1]?.selection == removed)
            #expect(after.windows[Self.windowP1] == state.windows[Self.windowP1])
            #expect(after.lastAppliedRevision(for: Self.projectP) == three)
        }

        @Test func closingAProjectsLastWindowDiscardsItsRevisionAndReopeningStartsFresh() throws {
            let (one, five) = (try Self.revision(1), try Self.revision(5))
            var state = try Self.applying([Self.revise(five, Self.projectP)], to: Self.twoProjects())
            let windowQ1 = state.windows[Self.windowQ1]

            state = try Self.applying([.closeWindow(Self.windowP1)], to: state)
            #expect(state.lastAppliedRevision(for: Self.projectP) == five)
            Self.expectStale(one, Self.projectP, on: state)
            // A window reopened while P is still open joins P's monotonic sequence.
            let rejoined = try Self.applying([.openWindow(Self.windowP1, project: Self.projectP)], to: state)
            Self.expectStale(five, Self.projectP, on: rejoined)

            state = try Self.applying([.closeWindow(Self.windowP2)], to: state)
            #expect(state.openProjects == [Self.projectQ])
            #expect(state.lastAppliedRevisions.isEmpty)
            #expect(state.windows[Self.windowQ1] == windowQ1)

            state = try Self.applying([
                .openWindow(Self.windowP1, project: Self.projectP), Self.revise(one, Self.projectP)
            ], to: state)
            #expect(state.lastAppliedRevision(for: Self.projectP) == one)
        }

        @Test func aRevisionForAProjectWithoutWindowsIsRefused() throws {
            let other = ProjectID(validated: "prj.other")
            let one = try Self.revision(1)
            Root.expectRefusal(
                .unknownProject(other), applying: Self.revise(one, other),
                to: WorkspaceNavigationState()
            )
            Root.expectRefusal(
                .unknownProject(other), applying: Self.revise(one, other), to: try Self.twoProjects()
            )
            let closed = try Self.applying([.closeWindow(Self.windowQ1)], to: Self.twoProjects())
            Root.expectRefusal(
                .unknownProject(Self.projectQ), applying: Self.revise(one, Self.projectQ), to: closed
            )
        }

        static func projects(_ count: Int) throws -> [ProjectID] { try (0..<count).map { try ProjectID("prj.\($0)") } }

        @Test func projectLimitAcceptsEightAndRefusesTheNinth() throws {
            #expect(WorkspaceNavigationState.maxProjects == 8)
            let ids = try Self.projects(9)
            let windows = try (0..<10).map { try WindowID("win.\($0)") }
            var state = try Self.applying((0..<8).map { .openWindow(windows[$0], project: ids[$0]) })
            #expect(state.openProjects.count == 8)

            Root.expectRefusal(
                .projectLimitExceeded(maximum: 8), applying: .openWindow(windows[8], project: ids[8]), to: state
            )
            let sharing = try Self.applying([.openWindow(windows[8], project: ids[3])], to: state)
            #expect(sharing.windows.count == 9)
            #expect(sharing.openProjects.count == 8)

            state = try Self.applying([.closeWindow(windows[0]), .openWindow(windows[8], project: ids[8])], to: state)
            #expect(state.openProjects == Set(ids[1...8]))
        }

        @Test func openRefusalsPrecedeTheProjectLimit() throws {
            let ids = try Self.projects(9)
            let windows = try (0..<17).map { try WindowID("win.\($0)") }
            let eight = try Self.applying((0..<8).map { .openWindow(windows[$0], project: ids[$0]) })
            Root.expectRefusal(
                .duplicateWindow(windows[2]), applying: .openWindow(windows[2], project: ids[8]), to: eight
            )

            let full = try Self.applying((8..<16).map { .openWindow(windows[$0], project: ids[$0 - 8]) }, to: eight)
            #expect(full.windows.count == 16)
            Root.expectRefusal(
                .windowLimitExceeded(maximum: 16), applying: .openWindow(windows[16], project: ids[8]), to: full
            )
        }

        /// Each one changes only project Q of `twoProjects()`.
        static let projectQEdits: [WorkspaceNavigationAction] = [
            .setMode(.perform, window: windowQ1),
            .setWidthClass(.compact, window: windowQ1),
            .select([.edge(EdgeID(validated: "edg.q"))], window: windowQ1),
            .clearSelection(window: windowQ1),
            .setInspectorRequested(true, window: windowQ1),
            .selectSurface(.library, window: windowQ1),
            .closeWindow(windowQ1),
            .openWindow(WindowID(validated: "win.q2"), project: projectQ),
            .revisionApplied(ContractRevision.initial, project: projectQ, present: [])
        ]

        @Test(arguments: WorkspaceNavigationTests.Projects.projectQEdits)
        func editingOneProjectLeavesTheOtherProjectEqual(_ action: WorkspaceNavigationAction) throws {
            let two = try Self.revision(2)
            let before = try Self.applying([Self.revise(two, Self.projectP)], to: Self.twoProjects())
            let after = try Self.applying([action], to: before)
            #expect(after != before)
            for window in [Self.windowP1, Self.windowP2] {
                #expect(after.windows[window] == before.windows[window])
                #expect(after.windowProjects[window] == Self.projectP)
            }
            #expect(after.lastAppliedRevision(for: Self.projectP) == two)
        }

        @Test func advancedExpansionStaysHostWide() throws {
            var state = try Self.applying([.selectSurface(.diagnostics, window: Self.windowQ1)], to: Self.twoProjects())
            #expect(state.isAdvancedExpanded)
            Root.expectRefusal(.advancedInUse(Self.windowQ1), applying: .setAdvancedExpanded(false), to: state)
            #expect(try state.presentation(for: Self.windowP1).advancedGroupExpanded)
            state = try Self.applying([.closeWindow(Self.windowQ1), .setAdvancedExpanded(false)], to: state)
            #expect(!state.isAdvancedExpanded)
        }
    }
}

// MARK: - W1-style scenarios against two projects

extension WorkspaceNavigationTests.Projects {
    /// W1's isolation scenario run once in each of two projects; P's run must not see Q's.
    @Test func theW1IsolationScenarioRunsIndependentlyInTwoProjects() throws {
        let (three, seven) = (try Self.revision(3), try Self.revision(7))
        func script(_ project: ProjectID, _ windowA: WindowID, _ windowB: WindowID, revision: ContractRevision) throws
            -> [WorkspaceNavigationAction] {
            [
                .openWindow(windowA, project: project), .openWindow(windowB, project: project),
                .selectSurface(.library, window: windowA), .setMode(.perform, window: windowA),
                .setWidthClass(.compact, window: windowA), .setInspectorRequested(true, window: windowA),
                .select([try Root.node(1), Self.port], window: windowA), .select([try Root.node(9)], window: windowB),
                .revisionApplied(revision, project: project, present: [Self.port, .node(Root.owner), try Root.node(9)])
            ]
        }
        let (windowQA, windowQB) = (WindowID(validated: "win.qa"), WindowID(validated: "win.qb"))
        let onlyP = try Self.applying(script(Self.projectP, Root.windowA, Root.windowB, revision: seven))
        let both = try Self.applying(script(Self.projectQ, windowQA, windowQB, revision: three), to: onlyP)

        #expect(both.windows[Root.windowA] == onlyP.windows[Root.windowA])
        #expect(both.windows[Root.windowB] == onlyP.windows[Root.windowB])
        var expectedQA = try #require(onlyP.windows[Root.windowA])
        expectedQA.selection = [.removed(try Root.node(1), in: three), .live(Self.port)]
        #expect(both.windows[windowQA] == expectedQA)
        #expect(onlyP.windows[Root.windowA]?.selection == [.removed(try Root.node(1), in: seven), .live(Self.port)])
        #expect(both.windows[windowQB]?.selection == [.live(try Root.node(9))])
        #expect(both.lastAppliedRevisions == [Self.projectP: seven, Self.projectQ: three])

        let empty = Set<WorkspaceItemRef>()
        let refused = WorkspaceNavigationError.staleRevision(three)
        Root.expectRefusal(refused, applying: .revisionApplied(three, project: Self.projectQ, present: empty), to: both)
        Root.expectRefusal(
            .staleRevision(seven), applying: .revisionApplied(seven, project: Self.projectP, present: empty), to: both
        )
    }

    enum Refusal: CaseIterable, Sendable {
        case unknownProject, projectLimit, perProjectStale

        func scenario() throws -> WorkspaceNavigationTests.RefusalScenario {
            let state = try WorkspaceNavigationTests.Projects.twoProjects()
            let one = try ContractRevision(1)
            switch self {
            case .unknownProject:
                let other = ProjectID(validated: "prj.other")
                return .init(
                    state: state, action: .revisionApplied(one, project: other, present: []),
                    expected: .unknownProject(other)
                )
            case .projectLimit:
                let more = try (0..<6).map { index in
                    WorkspaceNavigationAction.openWindow(
                        try WindowID("win.m\(index)"), project: try ProjectID("prj.m\(index)")
                    )
                }
                return .init(
                    state: try WorkspaceNavigationTests.applying(more, to: state),
                    action: .openWindow(WindowID(validated: "win.z"), project: ProjectID(validated: "prj.z")),
                    expected: .projectLimitExceeded(maximum: 8)
                )
            case .perProjectStale:
                let applied = try WorkspaceNavigationTests.applying(
                    [.revisionApplied(one, project: WorkspaceNavigationTests.Projects.projectQ, present: [])], to: state
                )
                return .init(
                    state: applied,
                    action: .revisionApplied(one, project: WorkspaceNavigationTests.Projects.projectQ, present: []),
                    expected: .staleRevision(one)
                )
            }
        }
    }

    @Test(arguments: Refusal.allCases)
    func everyProjectRefusalLeavesTheStateUnchanged(_ refusal: Refusal) throws {
        let scenario = try refusal.scenario()
        Root.expectRefusal(scenario.expected, applying: scenario.action, to: scenario.state)
    }

    @Test func aTwoProjectScriptAppliedTwiceGivesEqualStatesAndOutcomes() throws {
        let (one, two) = (try Self.revision(1), try Self.revision(2))
        let script: [WorkspaceNavigationAction] = [
            .openWindow(Self.windowP1, project: Self.projectP), .openWindow(Self.windowQ1, project: Self.projectQ),
            .revisionApplied(two, project: Self.projectQ, present: []),
            .revisionApplied(one, project: Self.projectP, present: []),
            .revisionApplied(one, project: Self.projectQ, present: []),
            .openWindow(Self.windowP1, project: Self.projectQ),
            .closeWindow(Self.windowP1),
            .revisionApplied(two, project: Self.projectP, present: []),
            .openWindow(Self.windowP2, project: Self.projectP),
            .revisionApplied(one, project: Self.projectP, present: [])
        ]
        func run() -> (WorkspaceNavigationState, [WorkspaceNavigationError?]) {
            var state = WorkspaceNavigationState()
            let outcomes = script.map { action -> WorkspaceNavigationError? in
                do throws(WorkspaceNavigationError) { try state.apply(action) } catch { return error }
                return nil
            }
            return (state, outcomes)
        }
        let (first, firstOutcomes) = run()
        let (second, secondOutcomes) = run()
        #expect(first == second)
        #expect(firstOutcomes == secondOutcomes)
        #expect(firstOutcomes == [
            nil, nil, nil, nil, .staleRevision(one), .duplicateWindow(Self.windowP1), nil,
            .unknownProject(Self.projectP), nil, nil
        ])
        #expect(first.lastAppliedRevisions == [Self.projectP: one, Self.projectQ: two])
        #expect(first.windowProjects == [Self.windowP2: Self.projectP, Self.windowQ1: Self.projectQ])
    }
}

private typealias Root = WorkspaceNavigationTests
