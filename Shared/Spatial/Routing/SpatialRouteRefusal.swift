//
//  SpatialRouteRefusal.swift
//  FluxKlang
//
//  Typed refusals, bounds and shared validation for the host-local spatial route
//  state (#114 SP1): route availability, speaker state and measurement identity.
//  Pure data; no clock, device probe or signal.
//

import Foundation

/// Why a route-state operation refused its input. A refusal changes nothing: every
/// input is a value, and no partial output is produced.
enum SpatialRouteRefusal: Error, Equatable, Sendable {
    case tooManyRoutes(Int)
    case tooManyPresenceEntries(Int)
    /// The smallest route id (ascending raw order) that occurs more than once.
    case duplicateRoute(RouteID)
    case channelCountOutOfRange(RouteID, count: Int)
    case negativeChannel(RouteID, channel: Int)
    case duplicateChannel(RouteID, channel: Int)
    case uidTooLong(RouteID, bytes: Int)
    case emptyUID(RouteID)
    case tooManyMeasurements(Int)
    case duplicateMeasurement(SpeakerID)
    /// A measurement or calibration entry names a speaker that is not in the layout.
    case unknownSpeaker(SpeakerID)
    case unknownMaskSpeaker(SpeakerID)
}

/// Every numeric bound of the route state; each is enforced where the input is used.
enum SpatialRouteLimits {
    static let maximumRoutes = 4_096
    static let maximumPresenceEntries = 4_096
    static let channelCounts = 1...64
    /// The device contract's own UID limit.
    static let maximumUIDBytes = 1_024
    static let maximumMeasurements = SpatialLayout.maximumSpeakers
}

/// Channel validation shared by `derive` and `SpatialMeasurementIdentity.make`.
enum SpatialRouteChannels {
    /// The sorted channels of `route`, or the first refusal in the order: count, negative, duplicate.
    /// Negative and duplicate refusals name the smallest offender, so permuted input refuses identically.
    static func validated(_ channels: [Int], route: RouteID) throws(SpatialRouteRefusal) -> [Int] {
        guard SpatialRouteLimits.channelCounts.contains(channels.count) else {
            throw .channelCountOutOfRange(route, count: channels.count)
        }
        let sorted = channels.sorted()
        if let first = sorted.first, first < 0 {
            throw .negativeChannel(route, channel: first)
        }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where previous == next {
            throw .duplicateChannel(route, channel: next)
        }
        return sorted
    }
}

/// A device unit identity string (the contract's `uid`). It is compared by unicode scalars, never by
/// `String ==`, which merges canonically equivalent spellings of different units. It is stored exactly as
/// given: no trimming, normalisation or case folding.
struct SpatialUnitUID: Hashable, Sendable {
    private(set) var value: String

    /// Refuses a UID over `SpatialRouteLimits.maximumUIDBytes` UTF-8 bytes (checked first), then a blank one.
    init(_ value: String, route: RouteID) throws(SpatialRouteRefusal) {
        try Self.validateLength(value, route: route)
        guard !Self.isBlank(value) else { throw .emptyUID(route) }
        self.value = value
    }

    static func validateLength(_ value: String, route: RouteID) throws(SpatialRouteRefusal) {
        let bytes = value.utf8.count
        guard bytes <= SpatialRouteLimits.maximumUIDBytes else { throw .uidTooLong(route, bytes: bytes) }
    }

    /// The device contract's own blank check (`DeviceCapability`), by construction the same call.
    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value.unicodeScalars.elementsEqual(rhs.value.unicodeScalars)
    }

    func hash(into hasher: inout Hasher) {
        for scalar in value.unicodeScalars { hasher.combine(scalar.value) }
    }
}
