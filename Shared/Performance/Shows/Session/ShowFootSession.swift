//
//  ShowFootSession.swift
//  FluxKlang
//
//  One value that owns a validated footswitch adapter and the show cursor
//  (#106 SFS1), so trigger commands and onscreen input share one position and
//  one bounce window. The session reads no MIDI port, owns no detector, holds
//  no library, catalog or tick source (the caller passes each by value), and
//  recalls and fires nothing.
//
//  Caller requirement: the detector feeding `deliver` is the caller's, and a
//  rebuilt detector must resume with `ControlTriggerDetector(bindings:after:)`
//  and the old `lastSequence`. The session cannot see the detector, so it
//  cannot enforce this: a counter restarted from zero has its real presses
//  refused as `staleSequence` or ignored as `duplicateSequence`.
//

struct ShowFootSession: Hashable, Sendable {
    private let storedAdapter: ShowFootInputAdapter
    private var storedCursor: ShowCursor

    var adapter: ShowFootInputAdapter { storedAdapter }
    var cursor: ShowCursor { storedCursor }

    /// Checks run in this order: the adapter's own (`foot`), then `cursorMissingSource` for the first footswitch
    /// show source, in `ShowFootswitchMap.showSources` order (control source ID order), that `cursor` does not
    /// declare. The cursor may declare more sources (for example onscreen ones); none is added.
    init(map: ShowFootswitchMap, bindings: [ControlTriggerBinding],
         cursor: ShowCursor) throws(ShowFootSessionRefusal) {
        let adapter = try Self.validated(map: map, bindings: bindings)
        for source in map.showSources where !Self.contains(cursor.sources, source) {
            throw .cursorMissingSource(source)
        }
        storedAdapter = adapter
        storedCursor = cursor
    }

    /// Answers a trigger command from the caller's detector. Checks run in the adapter's order, then the cursor's;
    /// the session adds none between them. A refused call and a `notNavigation` leave the session equal to its
    /// value before the call, and `ignored(.duplicateSequence)` changes nothing; `ignored(.bounce)` is not a
    /// refusal and records the press's sequence and tick in the cursor.
    mutating func deliver(_ command: ControlTriggerCommand, tick: UInt64, expected: ShowPosition? = nil,
                          in library: ShowLibrary,
                          catalog: ShowLinkCatalog) throws(ShowFootSessionRefusal) -> ShowFootSessionOutcome {
        switch try route(command, tick: tick, expected: expected) {
        case .notNavigation(let ignoral):
            return .notNavigation(ignoral)
        case .input(let input):
            return try move(input, in: library, catalog: catalog)
        }
    }

    /// Onscreen input on the same cursor. A source that the footswitch map owns is refused with `footSource`
    /// before the cursor sees it; otherwise the cursor's checks and atomicity apply unchanged.
    mutating func navigate(_ input: ShowNavigationInput, in library: ShowLibrary,
                           catalog: ShowLinkCatalog) throws(ShowFootSessionRefusal) -> ShowFootSessionOutcome {
        guard !Self.contains(storedAdapter.map.showSources, input.source) else { throw .footSource(input.source) }
        return try move(input, in: library, catalog: catalog)
    }

    private static func validated(map: ShowFootswitchMap,
                                  bindings: [ControlTriggerBinding]) throws(ShowFootSessionRefusal)
        -> ShowFootInputAdapter {
        do throws(ShowFootInputRefusal) {
            return try ShowFootInputAdapter(map: map, bindings: bindings)
        } catch {
            throw .foot(error)
        }
    }

    private static func contains(_ sources: [ShowInputSourceID], _ source: ShowInputSourceID) -> Bool {
        sources.contains { $0.rawValue.utf8.elementsEqual(source.rawValue.utf8) }
    }

    private func route(_ command: ControlTriggerCommand, tick: UInt64,
                       expected: ShowPosition?) throws(ShowFootSessionRefusal) -> ShowFootInputOutcome {
        do throws(ShowFootInputRefusal) {
            return try storedAdapter.input(for: command, tick: tick, expected: expected)
        } catch {
            throw .foot(error)
        }
    }

    private mutating func move(_ input: ShowNavigationInput, in library: ShowLibrary,
                               catalog: ShowLinkCatalog) throws(ShowFootSessionRefusal) -> ShowFootSessionOutcome {
        do throws(ShowRefusal) {
            switch try storedCursor.navigate(input, in: library, catalog: catalog) {
            case .moved(let stop):
                return .moved(stop)
            case .ignored(let ignoral):
                return .ignored(ignoral)
            }
        } catch {
            throw .show(error)
        }
    }
}
