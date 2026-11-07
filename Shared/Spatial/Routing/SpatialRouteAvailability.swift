//
//  SpatialRouteAvailability.swift
//  FluxKlang
//
//  Which output routes are usable on ONE host (#114 SP1), derived from `AudioRoute`
//  plus device presence. A route is available only if it is a confirmed output, confirmed
//  on this host with a unit UID, and its device is observed present. Everything else is
//  inert with the first failing reason; nothing is substituted or guessed.
//

import Foundation

/// The availability of every route on one host. Built only by `derive`.
///
/// Contract: `available` and `unavailable` are sorted by raw route id and disjoint; a route
/// in the input appears in exactly one of them. `confirmedEpoch` is ignored (the generation
/// of a confirmation is not unit identity, and is deliberately ignored). A device missing from `presence` is
/// `deviceUnobserved`, never available. Presence is keyed by `DeviceID` only: a different unit under the same
/// id is detected only by the UID comparison in calibration.
struct SpatialRouteAvailability: Hashable, Sendable {
    /// Why a route is not available. The first failing check in the order of the cases
    /// `wrongDirection`, `notConfirmed`, `otherHost`, `missingUID`, then device presence.
    enum Reason: Hashable, Sendable {
        case wrongDirection
        case notConfirmed(RouteBinding)
        /// Confirmed for another host, or confirmed with no host recorded (`nil`).
        case otherHost(HostID?)
        /// No `confirmedDeviceUID`, or one that is blank.
        case missingUID
        case deviceMissing
        case deviceStale
        /// The device is not in the presence map at all.
        case deviceUnobserved
        /// Never produced by `derive`: `reason(for:)` answers it for a route that was not in the input.
        case routeAbsent
    }

    /// An available route and the unit it points at. Only `derive` can build one.
    struct Entry: Hashable, Sendable {
        let route: RouteID
        let device: DeviceID
        let uid: SpatialUnitUID
        /// Sorted ascending.
        let channels: [Int]

        fileprivate init(route: RouteID, device: DeviceID, uid: SpatialUnitUID, channels: [Int]) {
            self.route = route
            self.device = device
            self.uid = uid
            self.channels = channels
        }
    }

    /// An unavailable route and its first failing reason. Only `derive` can build one.
    struct Unavailable: Hashable, Sendable {
        let route: RouteID
        let reason: Reason

        fileprivate init(route: RouteID, reason: Reason) {
            self.route = route
            self.reason = reason
        }
    }

    private(set) var host: HostID
    private(set) var available: [Entry]
    private(set) var unavailable: [Unavailable]

    private init(host: HostID, available: [Entry], unavailable: [Unavailable]) {
        self.host = host
        self.available = available
        self.unavailable = unavailable
    }

    /// Exactly what `SpatialMaskSet.passes(layout:availableRoutes:)` takes. Used for membership only.
    var availableRoutes: Set<RouteID> { Set(available.map(\.route)) }

    /// `nil` when `route` is available, its reason when it is not, `.routeAbsent` when it was not in the input.
    func reason(for route: RouteID) -> Reason? {
        if available.contains(where: { $0.route == route }) { return nil }
        return unavailable.first { $0.route == route }?.reason ?? .routeAbsent
    }

    /// The available entry for `route`, if any.
    func entry(for route: RouteID) -> Entry? {
        available.first { $0.route == route }
    }

    /// Derives availability for `host`. Limits are enforced here, at the point of use; the first
    /// refusal in the documented order is thrown and nothing partial is returned. Empty input is legal.
    /// A route's channel list is validated only for a route that passed every availability check, so a
    /// route failing an earlier check stays unavailable with its first reason whatever its channels hold.
    /// A refusal means "nothing available": a caller must never turn it into `availableRoutes: nil`, which
    /// skips loss in `SpatialMaskSet.passes`.
    static func derive(
        routes: [AudioRoute],
        presence: [DeviceID: DevicePresence],
        host: HostID
    ) throws(SpatialRouteRefusal) -> SpatialRouteAvailability {
        guard routes.count <= SpatialRouteLimits.maximumRoutes else { throw .tooManyRoutes(routes.count) }
        guard presence.count <= SpatialRouteLimits.maximumPresenceEntries else {
            throw .tooManyPresenceEntries(presence.count)
        }
        let sorted = routes.sorted { $0.id < $1.id }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where previous.id == next.id {
            throw .duplicateRoute(next.id)
        }
        var available: [Entry] = []
        var unavailable: [Unavailable] = []
        for route in sorted {
            let checked = try CheckedRoute(route)
            switch checked.verdict(host: host, presence: presence) {
            case .available(let uid):
                let channels = try SpatialRouteChannels.validated(route.channels, route: route.id)
                available.append(Entry(route: route.id, device: route.device, uid: uid, channels: channels))
            case .unavailable(let reason):
                unavailable.append(Unavailable(route: route.id, reason: reason))
            }
        }
        return SpatialRouteAvailability(host: host, available: available, unavailable: unavailable)
    }
}

/// A route whose UID length passed validation. Channels are validated only once the route is available.
private struct CheckedRoute {
    let route: AudioRoute
    /// `nil` when the route has no UID or a blank one.
    let uid: SpatialUnitUID?

    init(_ route: AudioRoute) throws(SpatialRouteRefusal) {
        self.route = route
        if let raw = route.confirmedDeviceUID {
            try SpatialUnitUID.validateLength(raw, route: route.id)
            uid = SpatialUnitUID.isBlank(raw) ? nil : try SpatialUnitUID(raw, route: route.id)
        } else {
            uid = nil
        }
    }

    enum Verdict {
        case available(SpatialUnitUID)
        case unavailable(SpatialRouteAvailability.Reason)
    }

    func verdict(host: HostID, presence: [DeviceID: DevicePresence]) -> Verdict {
        if route.direction != .output { return .unavailable(.wrongDirection) }
        if route.binding != .confirmed { return .unavailable(.notConfirmed(route.binding)) }
        if route.confirmedHost != host { return .unavailable(.otherHost(route.confirmedHost)) }
        guard let uid else { return .unavailable(.missingUID) }
        switch presence[route.device] {
        case .present: return .available(uid)
        case .missing: return .unavailable(.deviceMissing)
        case .stale: return .unavailable(.deviceStale)
        case nil: return .unavailable(.deviceUnobserved)
        }
    }
}
