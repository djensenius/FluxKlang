//
//  RigChannelOverlap.swift
//  FluxKlang
//
//  The channel-overlap policy between routes, per device and direction:
//  - an output channel written by two live routes is a conflict (two roles
//    would sum silently into one output). `apply` refuses a conflict that
//    involves an added route or a kept removal candidate; one among the
//    document's other routes was already there and is only reported;
//  - an input channel read by two live routes is shared input (one input may
//    feed more than one role), which is allowed and reported.
//
//  Only live routes (`.proposed` or `.confirmed`) take part: `stale` and
//  `deviceMissing` routes are muted and claim no channel. The scan is linear in
//  routes plus channels, using one bitset per (device, direction) group.
//

/// What an overlap means under the policy.
enum RigChannelOverlapKind: Hashable, Sendable {
    /// Two or more input routes read the channel: allowed and reported.
    case sharedInput
    /// Two or more output routes write the channel: refused by `apply` when it involves an added route or a
    /// kept removal candidate, and only reported when the document's other routes already shared it.
    case outputConflict
}

/// One device channel that more than one live route claims in one direction.
struct RigChannelOverlap: Hashable, Sendable {
    let device: DeviceID
    let direction: RouteDirection
    /// The 0-based device channel.
    let channel: Int
    /// The routes that claim the channel, sorted.
    let routes: [RouteID]
    let kind: RigChannelOverlapKind

    fileprivate init(device: DeviceID, direction: RouteDirection, channel: Int, routes: [RouteID]) {
        self.device = device
        self.direction = direction
        self.channel = channel
        self.routes = routes
        kind = direction == .input ? .sharedInput : .outputConflict
    }
}

/// The pure overlap scan.
enum RigChannelOverlapScan {
    /// The overlaps among the live routes, sorted by device, direction (input first) and channel.
    /// Every channel must be non-negative, as `DeviceCapabilityDocument.validate()` ensures.
    static func overlaps(in routes: [AudioRoute]) -> [RigChannelOverlap] {
        var operations = 0
        return scan(routes, operations: &operations)
    }

    /// Test-only: the overlaps and the number of route and channel visits the scan made.
    static func scanForTesting(_ routes: [AudioRoute]) -> (overlaps: [RigChannelOverlap], operations: Int) {
        var operations = 0
        let overlaps = scan(routes, operations: &operations)
        return (overlaps, operations)
    }

    private struct GroupKey: Hashable {
        let device: DeviceID
        let direction: RouteDirection
    }

    private static func scan(_ routes: [AudioRoute], operations: inout Int) -> [RigChannelOverlap] {
        var groups: [GroupKey: [AudioRoute]] = [:]
        for route in routes where route.binding == .proposed || route.binding == .confirmed {
            operations += 1
            groups[GroupKey(device: route.device, direction: route.direction), default: []].append(route)
        }
        var found: [RigChannelOverlap] = []
        for (key, members) in groups where members.count > 1 {
            found += overlaps(of: members, in: key, operations: &operations)
        }
        return found.sorted { lhs, rhs in
            if lhs.device != rhs.device { return lhs.device < rhs.device }
            if lhs.direction != rhs.direction { return lhs.direction == .input }
            return lhs.channel < rhs.channel
        }
    }

    /// The overlaps among the live routes of one (device, direction) group, unsorted.
    private static func overlaps(
        of members: [AudioRoute], in key: GroupKey, operations: inout Int
    ) -> [RigChannelOverlap] {
        // Pass 1: a channel claimed while its bit is already set is claimed more than once.
        var claimed = ChannelBits()
        var repeated = ChannelBits()
        for route in members {
            for channel in route.channels {
                operations += 1
                if !claimed.insert(channel) { _ = repeated.insert(channel) }
            }
        }
        guard !repeated.isEmpty else { return [] }
        // Pass 2: collect every route on a repeated channel.
        var claimants: [Int: [RouteID]] = [:]
        for route in members {
            for channel in route.channels {
                operations += 1
                if repeated.contains(channel) { claimants[channel, default: []].append(route.id) }
            }
        }
        return claimants.map { channel, ids in
            RigChannelOverlap(device: key.device, direction: key.direction, channel: channel, routes: ids.sorted())
        }
    }
}

/// A growable bitset of non-negative channel indices.
private struct ChannelBits {
    private var words: [UInt64] = []
    private(set) var isEmpty = true

    /// Sets the bit; returns `false` when it was already set.
    mutating func insert(_ channel: Int) -> Bool {
        precondition(channel >= 0, "Route channels are validated as non-negative")
        let (word, bit) = (channel >> 6, UInt64(1) << UInt64(channel & 63))
        if word >= words.count { words.append(contentsOf: repeatElement(0, count: word - words.count + 1)) }
        guard words[word] & bit == 0 else { return false }
        words[word] |= bit
        isEmpty = false
        return true
    }

    func contains(_ channel: Int) -> Bool {
        let word = channel >> 6
        return word < words.count && words[word] & (UInt64(1) << UInt64(channel & 63)) != 0
    }
}
