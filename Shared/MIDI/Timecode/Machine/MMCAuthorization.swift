/// The authorization class of an MMC command. Policies and grants name classes, never raw command codes.
/// `recordStrobe` and `recordExit` share `record`; `record` is never implied by any other class.
enum MMCCommandClass: UInt8, CaseIterable, Comparable, Hashable, Sendable {
    case stop = 0
    case play = 1
    case deferredPlay = 2
    case fastForward = 3
    case rewind = 4
    case pause = 5
    case record = 6
    case locate = 7

    init(_ command: MMCCommand) {
        switch command {
        case .stop: self = .stop
        case .play: self = .play
        case .deferredPlay: self = .deferredPlay
        case .fastForward: self = .fastForward
        case .rewind: self = .rewind
        case .pause: self = .pause
        case .recordStrobe, .recordExit: self = .record
        case .locate: self = .locate
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which device ids (the id carried by the MMC message) an allow-list entry applies to.
enum MMCDeviceSelector: Equatable, Hashable, Sendable {
    /// Every device id, including all-call. Always an explicit choice; no policy contains it by default.
    case any
    /// Exactly this id. `.device(.allCall)` matches only messages whose own id is all-call.
    case device(SysExDeviceID)

    func matches(_ deviceID: SysExDeviceID) -> Bool {
        switch self {
        case .any: true
        case let .device(id): id == deviceID
        }
    }

    /// Canonical order: `.any` first, then ascending raw device id.
    fileprivate var sortKey: Int {
        switch self {
        case .any: -1
        case let .device(id): Int(id.rawValue)
        }
    }
}

/// One allow-list entry: messages with a matching device id may become intents of `commandClass`.
struct MMCAuthorizationEntry: Equatable, Hashable, Comparable, Sendable {
    let selector: MMCDeviceSelector
    let commandClass: MMCCommandClass

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.selector.sortKey, lhs.commandClass) < (rhs.selector.sortKey, rhs.commandClass)
    }
}

/// Typed refusals when building a policy.
enum MMCAuthorizationError: Error, Equatable, Hashable, Sendable {
    case tooManyEntries(count: Int, limit: Int)
    /// The smallest duplicated entry in canonical order, so both input orders report the same refusal.
    case duplicateEntry(MMCAuthorizationEntry)
}

/// A default-deny inbound allow-list. The empty policy admits nothing. Inert value: it decides, it never acts.
struct MMCAuthorization: Equatable, Sendable {
    static let maximumEntries = 64
    static let denyAll = MMCAuthorization(sortedEntries: [])

    /// Entries in canonical order (`MMCAuthorizationEntry.<`).
    private(set) var entries: [MMCAuthorizationEntry]

    private init(sortedEntries: [MMCAuthorizationEntry]) {
        entries = sortedEntries
    }

    /// Refuses more than `maximumEntries` entries first, then any duplicated (selector, class) pair.
    static func make(entries: [MMCAuthorizationEntry]) throws(MMCAuthorizationError) -> MMCAuthorization {
        guard entries.count <= maximumEntries else {
            throw .tooManyEntries(count: entries.count, limit: maximumEntries)
        }
        let sorted = entries.sorted()
        for index in sorted.indices.dropFirst() where sorted[index] == sorted[index - 1] {
            throw .duplicateEntry(sorted[index])
        }
        return MMCAuthorization(sortedEntries: sorted)
    }

    func admits(deviceID: SysExDeviceID, commandClass: MMCCommandClass) -> Bool {
        entries.contains { $0.commandClass == commandClass && $0.selector.matches(deviceID) }
    }
}
