//
//  ShowFootswitchMap.swift
//  FluxKlang
//
//  Which trigger targets navigate a show, and which show input source each
//  control source speaks for (#106 SH3). The map stores IDs only, so reordering
//  a setlist never retargets a jump.
//

struct ShowFootswitchMap: Hashable, Sendable {
    static let maximumTargets = 64
    static let maximumSources = ShowLimits.maximumInputSources

    private let storedCommands: [ControlTriggerTargetID: ShowNavigationCommand]
    private let storedSources: [ControlSourceID: ShowInputSourceID]

    /// Several targets may share one command.
    var commands: [ControlTriggerTargetID: ShowNavigationCommand] { storedCommands }
    /// One to one: no two control sources share a show source.
    var sources: [ControlSourceID: ShowInputSourceID] { storedSources }
    /// The show sources in control source ID order, for `ShowCursor.make(setlist:bounceTicks:sources:in:)`.
    /// The caller merges in any other (for example onscreen) sources, which must not overlap these: an empty map
    /// gives `[]`, which the cursor refuses, and 8 footswitch sources use every slot of
    /// `ShowLimits.maximumInputSources`.
    var showSources: [ShowInputSourceID] { storedSources.sorted { $0.key < $1.key }.map(\.value) }

    private init(commands: [ControlTriggerTargetID: ShowNavigationCommand],
                 sources: [ControlSourceID: ShowInputSourceID]) {
        storedCommands = commands
        storedSources = sources
    }

    /// Checks run in this order: `tooManyTargets`, `tooManySources`, then `duplicateShowSource` for the first
    /// repeated show source met in control source ID order. Empty tables are valid.
    static func make(commands: [ControlTriggerTargetID: ShowNavigationCommand],
                     sources: [ControlSourceID: ShowInputSourceID]) throws(ShowFootInputRefusal)
        -> ShowFootswitchMap {
        guard commands.count <= maximumTargets else { throw .tooManyTargets(commands.count) }
        guard sources.count <= maximumSources else { throw .tooManySources(sources.count) }
        var claimed: [ShowInputSourceID: ControlSourceID] = [:]
        for (control, show) in sources.sorted(by: { $0.key < $1.key }) {
            if let first = claimed.updateValue(control, forKey: show) {
                throw .duplicateShowSource(show, first: first, second: control)
            }
        }
        return ShowFootswitchMap(commands: commands, sources: sources)
    }

    func command(for target: ControlTriggerTargetID) -> ShowNavigationCommand? { storedCommands[target] }

    func showSource(for source: ControlSourceID) -> ShowInputSourceID? { storedSources[source] }
}
