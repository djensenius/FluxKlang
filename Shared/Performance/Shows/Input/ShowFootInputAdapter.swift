//
//  ShowFootInputAdapter.swift
//  FluxKlang
//
//  Turns B4 trigger commands into `ShowNavigationInput` values (#106 SH3), so a
//  footswitch drives `ShowCursor.navigate` with the same IDs-only, bounce and
//  sequence rules as onscreen controls. Only a momentary press from control
//  input navigates. The adapter is stateless: duplicates and bounce are judged
//  by the cursor, and the detector's sequence passes through unchanged, so a
//  re-delivered command gives an identical input that the cursor ignores.
//
//  Caller requirements:
//  - Footswitch show sources must not overlap any other input source (for
//    example onscreen) feeding the same cursor. One to one is enforced only
//    among footswitch sources; an overlap makes two sequence counters feed one
//    source, so presses are refused as `staleSequence` or ignored as duplicates.
//  - A rebuilt detector must resume its counter with
//    `ControlTriggerDetector(bindings:after:)`, passing the old `lastSequence`;
//    otherwise reissued sequences make `ShowCursor` ignore real presses as
//    `.duplicateSequence` or refuse them as `staleSequence`.
//

/// Why a trigger command is not navigation. Not a refusal: the caller simply has nothing to send to the cursor.
enum ShowFootIgnoral: Hashable, Sendable {
    /// A momentary release edge (cause `.input`).
    case release
    /// A host-caused command (cause `.clear` or `.disconnect`), such as a release from `forgetHeld`.
    case hostCause
    /// The command's target is not a navigation target; another consumer may own it.
    case unmappedTarget
}

enum ShowFootInputOutcome: Hashable, Sendable {
    case input(ShowNavigationInput)
    case notNavigation(ShowFootIgnoral)
}

struct ShowFootInputAdapter: Hashable, Sendable {
    /// The target and source of one validated momentary binding on a navigation target.
    private struct Route: Hashable, Sendable {
        let target: ControlTriggerTargetID
        let source: ControlSourceID
    }

    private let storedMap: ShowFootswitchMap
    /// Lookup only; never iterated.
    private let routes: [BindingID: Route]

    var map: ShowFootswitchMap { storedMap }

    /// Validates `bindings` (the detector's bindings) against `map`. Checks run in this order: `tooManyBindings`,
    /// then for each binding in the given order `duplicateBinding`, and, when its target is a navigation target,
    /// `statefulNavigationBinding` (toggle or latch) and `unmappedSource`. Bindings on other targets are kept out
    /// of navigation and otherwise unchecked.
    init(map: ShowFootswitchMap, bindings: [ControlTriggerBinding]) throws(ShowFootInputRefusal) {
        guard bindings.count <= ControlTriggerDetector.maximumBindings else {
            throw .tooManyBindings(bindings.count)
        }
        var seen = Set<BindingID>()
        var routes: [BindingID: Route] = [:]
        for binding in bindings {
            guard seen.insert(binding.id).inserted else { throw .duplicateBinding(binding.id) }
            guard map.command(for: binding.target) != nil else { continue }
            guard binding.mode == .momentary else { throw .statefulNavigationBinding(binding.id, binding.mode) }
            guard map.showSource(for: binding.source) != nil else { throw .unmappedSource(binding.source) }
            routes[binding.id] = Route(target: binding.target, source: binding.source)
        }
        storedMap = map
        self.routes = routes
    }

    /// Checks run in this order; the first that applies decides:
    /// 1. A target that is not a navigation target is `.notNavigation(.unmappedTarget)`, whatever its action.
    /// 2. `unmappedSource` when the command's control source has no show source.
    /// 3. `bindingTargetUnknown` unless the command's binding is a validated binding with the same target and source.
    /// 4. Cause `.clear` or `.disconnect` is `.notNavigation(.hostCause)`.
    /// 5. A `release` is `.notNavigation(.release)`; `switchedOn` or `switchedOff` is `bindingTargetUnknown`.
    /// 6. A `press` is `.input`: the map's command from the source's show source, with the command's sequence,
    ///    the caller's `tick` and `expected`.
    func input(for command: ControlTriggerCommand, tick: UInt64,
               expected: ShowPosition? = nil) throws(ShowFootInputRefusal) -> ShowFootInputOutcome {
        guard let navigation = storedMap.command(for: command.target) else { return .notNavigation(.unmappedTarget) }
        guard let source = storedMap.showSource(for: command.source) else { throw .unmappedSource(command.source) }
        guard let route = routes[command.binding], route.target == command.target, route.source == command.source
        else { throw .bindingTargetUnknown(command.binding) }
        switch command.cause {
        case .clear, .disconnect:
            return .notNavigation(.hostCause)
        case .input:
            break
        }
        switch command.action {
        case .press:
            return .input(ShowNavigationInput(navigation, source: source, sequence: command.sequence, tick: tick,
                                              expected: expected))
        case .release:
            return .notNavigation(.release)
        case .switchedOn, .switchedOff:
            throw .bindingTargetUnknown(command.binding)
        }
    }
}
