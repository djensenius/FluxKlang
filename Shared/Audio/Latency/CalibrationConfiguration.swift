//
//  CalibrationConfiguration.swift
//  FluxKlang
//
//  Exact device, route, stream and generation snapshot for a calibration.
//

/// The dimensions of a calibration that changed since it was recorded.
enum CalibrationStaleReason: String, CaseIterable, Hashable, Sendable {
    case deviceID
    case deviceIdentity
    case sampleRate
    case inputBuffer
    case outputBuffer
    case routes
    case deviceGeneration
    case calibrationGeneration
}

/// Identity evidence stored with its exact host-local device identifier.
struct DeviceIdentitySnapshot: Hashable, Sendable {
    let deviceID: DeviceID
    let uid: String
    let evidence: Set<IdentityEvidence>

    fileprivate init(deviceID: DeviceID, identity: DeviceIdentity) {
        self.deviceID = deviceID
        uid = identity.uid
        evidence = identity.evidence
    }
}

/// Signal-path fields of a route; its device is represented once by the configuration identity.
struct RouteSnapshot: Hashable, Sendable {
    let id: RouteID
    let direction: RouteDirection
    let channels: [Int]

    fileprivate init(route: AudioRoute) {
        id = route.id
        direction = route.direction
        channels = route.channels
    }
}

/// An immutable snapshot of the device, signal routes, stream and relevant generations.
struct CalibrationConfiguration: Hashable, Sendable {
    static let maximumRoutes = 16
    static let routeChannels = 0..<4_096

    let device: DeviceIdentitySnapshot
    let stream: StreamSetup
    /// Routes are ordered by `RouteID`; channel order within each route is retained.
    let routes: [RouteSnapshot]
    let generations: CalibrationGenerations

    private init(device: DeviceIdentitySnapshot, stream: StreamSetup, routes: [RouteSnapshot],
                 generations: CalibrationGenerations) {
        self.device = device
        self.stream = stream
        self.routes = routes
        self.generations = generations
    }

    /// Validates and snapshots routes for one explicit `(DeviceID, DeviceIdentity)` pair.
    static func make(deviceID: DeviceID, identity: DeviceIdentity, routes: [AudioRoute], stream: StreamSetup,
                     generations: CalibrationGenerations) throws(LatencyRefusal) -> Self {
        guard !routes.isEmpty else { throw .noRoutes }
        guard routes.count <= maximumRoutes else { throw .tooManyRoutes(count: routes.count) }

        var seen = Set<RouteID>()
        let duplicates = routes.compactMap { route -> RouteID? in
            seen.insert(route.id).inserted ? nil : route.id
        }
        if let duplicate = duplicates.min() { throw .duplicateRoute(duplicate) }

        let ordered = routes.sorted { $0.id < $1.id }
        for route in ordered where !validChannels(route.channels) {
            throw .invalidRouteChannels(route.id)
        }
        for route in ordered where route.device != deviceID {
            throw .routeDeviceMismatch(route.id, expected: deviceID, found: route.device)
        }
        return Self(device: DeviceIdentitySnapshot(deviceID: deviceID, identity: identity), stream: stream,
                    routes: ordered.map(RouteSnapshot.init), generations: generations)
    }

    /// Returns every changed bound field in `CalibrationStaleReason` declaration order.
    func staleReasons(comparedTo current: Self) -> [CalibrationStaleReason] {
        var reasons: [CalibrationStaleReason] = []
        if device.deviceID != current.device.deviceID { reasons.append(.deviceID) }
        if device.uid != current.device.uid || device.evidence != current.device.evidence {
            reasons.append(.deviceIdentity)
        }
        if stream.sampleRateHz != current.stream.sampleRateHz { reasons.append(.sampleRate) }
        if stream.inputBufferFrames != current.stream.inputBufferFrames { reasons.append(.inputBuffer) }
        if stream.outputBufferFrames != current.stream.outputBufferFrames { reasons.append(.outputBuffer) }
        if routes != current.routes { reasons.append(.routes) }
        if generations.device != current.generations.device { reasons.append(.deviceGeneration) }
        if generations.calibration != current.generations.calibration { reasons.append(.calibrationGeneration) }
        return reasons
    }

    private static func validChannels(_ channels: [Int]) -> Bool {
        guard !channels.isEmpty else { return false }
        var seen = Set<Int>()
        return channels.allSatisfy { routeChannels.contains($0) && seen.insert($0).inserted }
    }
}
