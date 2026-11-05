//
//  ShowCursor.swift
//  FluxKlang
//
//  The navigation cursor shared by foot input and onscreen controls (#106 SH1).
//  It stores IDs only, so reordering never retargets it. Foot input arrives as
//  a `ShowNavigationCommand` value (binding wiring is B4/SH2) from a declared
//  input source, with a per-source sequence and caller ticks on one shared
//  clock: a re-delivered sequence is ignored, a press within the bounce window
//  of that same command's last accepted press (from any source, whatever was
//  pressed in between) is ignored, and nothing wraps. Navigation recalls and fires nothing; it returns
//  the new position and its resolved links.
//

struct ShowPosition: Hashable, Sendable {
    let setlist: SetlistID
    let entry: SetlistEntryID
    /// `nil` only for a song without parts; once that song gains parts the cursor's status is `.partsAdded`.
    let part: SongPartID?
}

enum ShowNavigationCommand: Hashable, Sendable {
    /// After a song's last part, the next entry's first part.
    case nextPart
    /// Before a song's first part, the previous entry's last part.
    case previousPart
    case nextSong
    case previousSong
    /// `part == nil` means the entry's first part. Never bounced and never recorded for bounce: repeating a
    /// jump is idempotent by target, and a jump neither opens nor resets a relative command's window.
    case jump(SetlistEntryID, SongPartID?)

    static let bounceSlotCount = 4

    /// Each relative command's own bounce slot; jumps have none.
    var bounceSlot: Int? {
        switch self {
        case .nextPart: 0
        case .previousPart: 1
        case .nextSong: 2
        case .previousSong: 3
        case .jump: nil
        }
    }
}

struct ShowNavigationInput: Hashable, Sendable {
    let command: ShowNavigationCommand
    /// Which declared source sent the press; each source has its own sequence.
    let source: ShowInputSourceID
    /// Caller-assigned, increasing per press within `source`; a re-delivery repeats it.
    let sequence: UInt64
    /// Caller's monotonic clock, in the unit of the cursor's bounce window.
    let tick: UInt64
    /// When set, the press applies only if the cursor is still here.
    let expected: ShowPosition?

    init(_ command: ShowNavigationCommand, source: ShowInputSourceID, sequence: UInt64, tick: UInt64,
         expected: ShowPosition? = nil) {
        self.command = command
        self.source = source
        self.sequence = sequence
        self.tick = tick
        self.expected = expected
    }
}

/// Where the cursor now is, with the song and the effective links of that part. Built only by navigation.
struct ShowStop: Hashable, Sendable {
    private let storedPosition: ShowPosition
    private let storedSong: SongID
    private let storedLinks: ShowResolvedLinks

    var position: ShowPosition { storedPosition }
    var song: SongID { storedSong }
    var links: ShowResolvedLinks { storedLinks }

    fileprivate init(position: ShowPosition, song: SongID, links: ShowResolvedLinks) {
        storedPosition = position
        storedSong = song
        storedLinks = links
    }
}

enum ShowInputIgnoral: Hashable, Sendable {
    /// This sequence was already handled.
    case duplicateSequence(UInt64)
    /// Same command, fewer than the bounce window's ticks after the last accepted press.
    case bounce(ticksSinceAccepted: UInt64)
}

enum ShowNavigationResult: Hashable, Sendable {
    case moved(ShowStop)
    case ignored(ShowInputIgnoral)
}

enum ShowCursorStatus: Hashable, Sendable {
    case current
    case setlistRemoved(SetlistID)
    case entryRemoved(SetlistEntryID)
    case partRemoved(SongPartID)
    /// The cursor is on a song without parts (`part == nil`) that has since gained parts. Stale like a removed
    /// part: no stop is built, relative commands are refused and only a jump recovers.
    case partsAdded(SongID)
}

struct ShowCursor: Hashable, Sendable {
    private let storedSetlist: SetlistID
    private let storedBounceTicks: UInt64
    private let storedSources: [ShowInputSourceID]
    private var storedPosition: ShowPosition?
    /// Lookup only; never iterated.
    private var lastSequences: [ShowInputSourceID: UInt64] = [:]
    private var lastTick: UInt64?
    /// The last accepted tick of each relative command, shared across sources, indexed by `bounceSlot`.
    private var lastAcceptedTicks = [UInt64?](repeating: nil, count: ShowNavigationCommand.bounceSlotCount)

    var setlist: SetlistID { storedSetlist }
    var bounceTicks: UInt64 { storedBounceTicks }
    /// In declaration order.
    var sources: [ShowInputSourceID] { storedSources }
    /// `nil` only while the setlist is empty at creation.
    var position: ShowPosition? { storedPosition }

    private init(setlist: SetlistID, bounceTicks: UInt64, sources: [ShowInputSourceID], position: ShowPosition?) {
        storedSetlist = setlist
        storedBounceTicks = bounceTicks
        storedSources = sources
        storedPosition = position
    }

    /// Starts at the setlist's first entry and first part. Another setlist needs another cursor.
    static func make(setlist id: SetlistID, bounceTicks: UInt64, sources: [ShowInputSourceID],
                     in library: ShowLibrary) throws(ShowRefusal) -> ShowCursor {
        guard bounceTicks <= ShowLimits.maximumBounceTicks else { throw .bounceOutOfRange(bounceTicks) }
        guard (1...ShowLimits.maximumInputSources).contains(sources.count) else {
            throw .inputSourceCountOutOfRange(sources.count)
        }
        var seen = Set<ShowInputSourceID>()
        for source in sources where !seen.insert(source).inserted { throw .duplicateInputSource(source) }
        guard let setlist = library.setlist(id) else { throw .unknownSetlist(id) }
        var position: ShowPosition?
        if let first = setlist.entries.first { position = try start(of: first, in: setlist, library: library) }
        return ShowCursor(setlist: id, bounceTicks: bounceTicks, sources: sources, position: position)
    }

    /// Anything but `.current` means the target is gone or stale: `currentStop` and relative commands refuse with
    /// `cursorTargetRemoved` until a jump. A `nil` part is valid only while its song has no parts.
    func status(in library: ShowLibrary) -> ShowCursorStatus {
        guard let setlist = library.setlist(storedSetlist) else { return .setlistRemoved(storedSetlist) }
        guard let position = storedPosition else { return .current }
        guard let entry = setlist.entries.first(where: { $0.id == position.entry }) else {
            return .entryRemoved(position.entry)
        }
        if let part = position.part, library.song(entry.song)?.part(part) == nil { return .partRemoved(part) }
        if position.part == nil, library.song(entry.song)?.parts.isEmpty == false { return .partsAdded(entry.song) }
        return .current
    }

    func currentStop(in library: ShowLibrary, catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowStop? {
        guard let position = storedPosition else { return nil }
        let status = status(in: library)
        guard status == .current else { throw .cursorTargetRemoved(status) }
        return try Self.stop(at: position, in: library, catalog: catalog)
    }

    /// Checks run in this order; the first that applies decides:
    /// 1. `unknownInputSource`.
    /// 2. The source's sequence: a repeat is `.ignored(.duplicateSequence)`, a lower one `staleSequence`.
    /// 3. `ticksWentBackwards` on the shared clock.
    /// 4. Relative commands only: `cursorTargetRemoved` unless `status` is `.current` (removed or stale target).
    /// 5. Relative commands only: `.ignored(.bounce)` inside that command's window (per command, across sources).
    /// 6. `positionMismatch` when `expected` no longer holds.
    /// 7. The target: `emptySetlist`, `atStart`, `atEnd`; for a jump `cursorTargetRemoved(.setlistRemoved)`,
    ///    `unknownEntry` or `unknownPart`.
    /// A refusal changes nothing, not even the remembered sequence or tick. A duplicate records nothing and a bounce
    /// only the sequence and tick. Only a move writes a bounce slot, its own command's.
    mutating func navigate(_ input: ShowNavigationInput, in library: ShowLibrary,
                           catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowNavigationResult {
        guard storedSources.contains(input.source) else { throw .unknownInputSource(input.source) }
        if let lastSequence = lastSequences[input.source] {
            if input.sequence == lastSequence { return .ignored(.duplicateSequence(input.sequence)) }
            guard input.sequence > lastSequence else {
                throw .staleSequence(last: lastSequence, received: input.sequence)
            }
        }
        if let lastTick, input.tick < lastTick { throw .ticksWentBackwards(last: lastTick, received: input.tick) }
        try requireCurrentTarget(for: input.command, in: library)
        let slot = input.command.bounceSlot
        if let slot, let accepted = lastAcceptedTicks[slot] {
            let elapsed = input.tick - accepted
            if elapsed < storedBounceTicks {
                lastSequences[input.source] = input.sequence
                lastTick = input.tick
                return .ignored(.bounce(ticksSinceAccepted: elapsed))
            }
        }
        if let expected = input.expected, expected != storedPosition {
            throw .positionMismatch(expected: expected, actual: storedPosition)
        }
        let target = try target(for: input.command, in: library)
        let stop = try Self.stop(at: target, in: library, catalog: catalog)
        storedPosition = target
        lastSequences[input.source] = input.sequence
        lastTick = input.tick
        if let slot { lastAcceptedTicks[slot] = input.tick }
        return .moved(stop)
    }

    /// Step 4 of `navigate`: a relative command (one with a bounce slot) needs a `.current` status. A jump skips
    /// this, because a jump is how a stale cursor recovers.
    private func requireCurrentTarget(for command: ShowNavigationCommand,
                                      in library: ShowLibrary) throws(ShowRefusal) {
        guard command.bounceSlot != nil else { return }
        let status = status(in: library)
        guard status == .current else { throw .cursorTargetRemoved(status) }
    }

    private func target(for command: ShowNavigationCommand, in library: ShowLibrary) throws(ShowRefusal)
        -> ShowPosition {
        guard let setlist = library.setlist(storedSetlist) else {
            throw .cursorTargetRemoved(.setlistRemoved(storedSetlist))
        }
        if case let .jump(entryID, partID) = command {
            guard let entry = setlist.entries.first(where: { $0.id == entryID }) else { throw .unknownEntry(entryID) }
            guard let partID else { return try Self.start(of: entry, in: setlist, library: library) }
            // A part from another song is refused by `stop(at:)` (`resolvedLinks`) before the cursor moves.
            return ShowPosition(setlist: setlist.id, entry: entryID, part: partID)
        }
        // A relative command gets here only with a `.current` status, checked in `navigate` before the bounce window.
        guard !setlist.entries.isEmpty else { throw .emptySetlist(setlist.id) }
        guard let position = storedPosition, let index = setlist.index(of: position.entry) else {
            guard command == .nextPart || command == .nextSong else { throw .atStart }
            return try Self.start(of: setlist.entries[0], in: setlist, library: library)
        }
        return try Self.relative(command, from: position, at: index, in: setlist, library: library)
    }

    private static func relative(_ command: ShowNavigationCommand, from position: ShowPosition, at index: Int,
                                 in setlist: ShowSetlist, library: ShowLibrary) throws(ShowRefusal)
        -> ShowPosition {
        let entries = setlist.entries
        guard let song = library.song(entries[index].song) else { throw .unknownSong(entries[index].song) }
        let partIndex = position.part.flatMap { id in song.parts.firstIndex { $0.id == id } }
        switch command {
        case .nextPart:
            let next = (partIndex ?? -1) + 1
            if next < song.parts.count {
                return ShowPosition(setlist: setlist.id, entry: position.entry, part: song.parts[next].id)
            }
            fallthrough
        case .nextSong:
            guard index + 1 < entries.count else { throw .atEnd }
            return try start(of: entries[index + 1], in: setlist, library: library)
        case .previousPart:
            if let partIndex, partIndex > 0 {
                return ShowPosition(setlist: setlist.id, entry: position.entry, part: song.parts[partIndex - 1].id)
            }
            return try end(before: index, in: setlist, library: library)
        case .previousSong:
            guard index > 0 else { throw .atStart }
            return try start(of: entries[index - 1], in: setlist, library: library)
        case .jump:
            return position
        }
    }

    /// The last part of the entry before `index`.
    private static func end(before index: Int, in setlist: ShowSetlist,
                            library: ShowLibrary) throws(ShowRefusal) -> ShowPosition {
        guard index > 0 else { throw .atStart }
        let previous = setlist.entries[index - 1]
        guard let song = library.song(previous.song) else { throw .unknownSong(previous.song) }
        return ShowPosition(setlist: setlist.id, entry: previous.id, part: song.parts.last?.id)
    }

    private static func start(of entry: SetlistEntry, in setlist: ShowSetlist,
                              library: ShowLibrary) throws(ShowRefusal) -> ShowPosition {
        guard let song = library.song(entry.song) else { throw .unknownSong(entry.song) }
        return ShowPosition(setlist: setlist.id, entry: entry.id, part: song.parts.first?.id)
    }

    private static func stop(at position: ShowPosition, in library: ShowLibrary,
                             catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowStop {
        guard let setlist = library.setlist(position.setlist) else { throw .unknownSetlist(position.setlist) }
        guard let entry = setlist.entries.first(where: { $0.id == position.entry }) else {
            throw .unknownEntry(position.entry)
        }
        guard let song = library.song(entry.song) else { throw .unknownSong(entry.song) }
        return try ShowStop(position: position, song: song.id,
                            links: ShowLibrary.resolvedLinks(song: song, part: position.part, in: catalog))
    }
}
