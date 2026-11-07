//
//  SpatialMeasurementIdentity.swift
//  FluxKlang
//
//  The unit a calibration was measured on (#114 SP1), host-local rig data. The portable
//  `SpatialLayout` and `SpatialCalibrationSet` carry no unit identity and stay unchanged; this
//  value lives beside them. `SpatialCalibrationBinding.check` flags a calibration whose route now
//  points at a different unit instead of silently reusing it. It never mutates the calibration.
//

import Foundation

/// Where one speaker was measured: route, unit UID, channel set and host. Built only by `make`.
/// Host-local rig data: it is never portable and must not travel with a layout or calibration set.
///
/// The UID is compared by unicode scalars (see `SpatialUnitUID`); a `DeviceID` is deliberately not
/// part of it, so a model-only or device-id-only match can never stand in for the unit's UID.
struct SpatialMeasurementIdentity: Hashable, Sendable {
    private(set) var route: RouteID
    private(set) var uid: SpatialUnitUID
    /// Sorted ascending.
    private(set) var channels: [Int]
    private(set) var host: HostID

    private init(route: RouteID, uid: SpatialUnitUID, channels: [Int], host: HostID) {
        self.route = route
        self.uid = uid
        self.channels = channels
        self.host = host
    }

    /// Refusals, in order: `uidTooLong`, `emptyUID`, `channelCountOutOfRange`, `negativeChannel`,
    /// `duplicateChannel`. Channels are stored sorted.
    static func make(
        route: RouteID,
        deviceUID: String,
        channels: [Int],
        host: HostID
    ) throws(SpatialRouteRefusal) -> SpatialMeasurementIdentity {
        let uid = try SpatialUnitUID(deviceUID, route: route)
        let sorted = try SpatialRouteChannels.validated(channels, route: route)
        return SpatialMeasurementIdentity(route: route, uid: uid, channels: sorted, host: host)
    }
}

/// A measurement identity for one speaker.
struct SpatialSpeakerMeasurement: Hashable, Sendable {
    let speaker: SpeakerID
    let identity: SpatialMeasurementIdentity
}

/// The verdict for one calibrated speaker. Only `SpatialCalibrationBinding.check` can build one.
struct SpatialCalibrationFlag: Hashable, Sendable {
    /// The first matching kind, in this order of checks: `noMeasurement`, `otherHost`, `routeUnavailable`,
    /// route changed (`remapped`), UID changed (`unitChanged`), channel set changed (`remapped`), `matches`.
    enum Kind: Hashable, Sendable {
        case matches
        /// The speaker is now on another route, or the same unit's channel set changed.
        case remapped
        /// The same route now points at a unit with a different UID.
        case unitChanged
        case noMeasurement
        /// The speaker is unmapped or its route is not available now, so the unit cannot be verified.
        case routeUnavailable
        /// Measured on another host; identity is host-local.
        case otherHost
    }

    let speaker: SpeakerID
    let kind: Kind

    fileprivate init(speaker: SpeakerID, kind: Kind) {
        self.speaker = speaker
        self.kind = kind
    }
}

enum SpatialCalibrationBinding {
    /// One flag per calibration entry, ascending speaker id. A speaker without a calibration entry has no
    /// calibration to reuse and gets no flag. Refusals, in order: `tooManyMeasurements`,
    /// `duplicateMeasurement` (smallest speaker), `unknownSpeaker` (smallest among measurements and entries).
    /// Nothing is mutated; a flagged speaker is never treated as calibrated by this function.
    static func check(
        calibration: SpatialCalibrationSet,
        layout: SpatialLayout,
        measured: [SpatialSpeakerMeasurement],
        current: SpatialRouteAvailability
    ) throws(SpatialRouteRefusal) -> [SpatialCalibrationFlag] {
        guard measured.count <= SpatialRouteLimits.maximumMeasurements else {
            throw .tooManyMeasurements(measured.count)
        }
        let sorted = measured.sorted { $0.speaker < $1.speaker }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where previous.speaker == next.speaker {
            throw .duplicateMeasurement(next.speaker)
        }
        let known = Set(layout.speakers.map(\.id))
        let named = sorted.map(\.speaker) + calibration.entries.map(\.speaker)
        if let unknown = named.filter({ !known.contains($0) }).min() {
            throw .unknownSpeaker(unknown)
        }
        return calibration.entries.map { entry in
            let identity = sorted.first { $0.speaker == entry.speaker }?.identity
            let kind = kind(identity: identity, route: layout.route(for: entry.speaker), current: current)
            return SpatialCalibrationFlag(speaker: entry.speaker, kind: kind)
        }
    }

    private static func kind(
        identity: SpatialMeasurementIdentity?,
        route: RouteID?,
        current: SpatialRouteAvailability
    ) -> SpatialCalibrationFlag.Kind {
        guard let identity else { return .noMeasurement }
        if identity.host != current.host { return .otherHost }
        guard let route, let entry = current.entry(for: route) else { return .routeUnavailable }
        if identity.route != route { return .remapped }
        if identity.uid != entry.uid { return .unitChanged }
        if identity.channels != entry.channels { return .remapped }
        return .matches
    }
}
