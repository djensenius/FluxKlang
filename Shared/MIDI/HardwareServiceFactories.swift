//
//  HardwareServiceFactories.swift
//  FluxKlang
//
//  Startup seam for services that can reach hardware. Production keeps the
//  CoreMIDI input; XCTest hosts and DEBUG `-ui-testing` launches select inert
//  doubles, using the same flag that already isolates persistence.
//

import Foundation

/// A Launch Control XL control-change source. `CoreMIDIInput` is production.
@MainActor
protocol LaunchControlXLInput: AnyObject {
    func start(
        sourceNameContains: [String],
        onMessages: @escaping ([MIDIControlChange]) -> Void,
        onSourcesChanged: @escaping ([String]) -> Void
    )
    func stop()
}

/// Never creates a MIDI client or port, so it reports no connected sources.
@MainActor
final class InertLaunchControlXLInput: LaunchControlXLInput {
    func start(
        sourceNameContains: [String],
        onMessages: @escaping ([MIDIControlChange]) -> Void,
        onSourcesChanged: @escaping ([String]) -> Void
    ) {}

    func stop() {}
}

/// Factories are invoked lazily, only when a service is actually requested.
struct HardwareServiceFactories: Sendable {
    /// Called on the first non-disabled Launch Control XL restart, not at init.
    var makeLaunchControlXLInput: @MainActor () -> any LaunchControlXLInput
    /// Reads/requests privacy permissions. Defaults to inert; only production queries the system.
    var makePermissionProbe: @MainActor () -> any PermissionProbe = { InertPermissionProbe() }
    /// Pre-flight Local Network check for `AppModel.connect`. Inert reports "no route" without a syscall.
    var localNetworkProbe: LocalNetworkProbe.Check = { _, _ in ENETUNREACH }
    /// Defaults to inert; production receives AppModel's evidence-aware Local Network probe.
    var makeWingTransport: @Sendable (UInt16, @escaping LocalNetworkProbe.Check) -> any WingTransporting = { _, _ in
        InertWingTransport()
    }
    /// Enumerates only when discovery scans. Defaults to no interfaces, without system calls.
    var wingDiscoveryBroadcastHosts: @Sendable () -> [String] = { [] }
    /// Startup-reconnect evidence (see `LocalNetworkGrantEvidence`).
    var localNetworkEvidence: LocalNetworkGrantEvidence = .current

    static let production = productionFactories(mirroring: nil)
    static let inert = HardwareServiceFactories(makeLaunchControlXLInput: { InertLaunchControlXLInput() })

    /// Observation is additive; callers cannot replace the global audit or the process-selected policy.
    static func productionFactories(mirroring audit: ProductionAccessAudit?) -> HardwareServiceFactories {
        HardwareServiceFactories(
            makeLaunchControlXLInput: {
                ProductionAccessAudit.shared.record(.attempted, for: .midiInput, mirroring: audit)
                guard !AppPersistence.isTesting else {
                    ProductionAccessAudit.shared.record(.denied, for: .midiInput, mirroring: audit)
                    return InertLaunchControlXLInput()
                }
                ProductionAccessAudit.shared.record(.factoryEvaluated, for: .midiInput, mirroring: audit)
                return CoreMIDIInput(mirroring: audit)
            },
            makePermissionProbe: {
                ProductionAccessAudit.shared.record(.attempted, for: .permissionProbe, mirroring: audit)
                guard !AppPersistence.isTesting else {
                    ProductionAccessAudit.shared.record(.denied, for: .permissionProbe, mirroring: audit)
                    return InertPermissionProbe()
                }
                ProductionAccessAudit.shared.record(.factoryEvaluated, for: .permissionProbe, mirroring: audit)
                return SystemPermissionProbe()
            },
            localNetworkProbe: LocalNetworkProbe.connectErrno,
            makeWingTransport: { port, probe in
                ProductionAccessAudit.shared.record(.attempted, for: .wingTransport, mirroring: audit)
                guard !AppPersistence.isTesting else {
                    ProductionAccessAudit.shared.record(.denied, for: .wingTransport, mirroring: audit)
                    return InertWingTransport()
                }
                ProductionAccessAudit.shared.record(.factoryEvaluated, for: .wingTransport, mirroring: audit)
                return WingTransport(remotePort: port, localNetworkProbe: probe, mirroring: audit)
            },
            wingDiscoveryBroadcastHosts: WingDiscovery.activeIPv4BroadcastHosts)
    }

    /// Selected once, alongside `AppPersistence.storage`.
    static let current = select(isTesting: AppPersistence.isTesting, production: .production)

    /// Production factories are an autoclosure: test selection never builds them.
    static func select(
        isTesting: Bool,
        production: @autoclosure () -> HardwareServiceFactories
    ) -> HardwareServiceFactories {
        isTesting ? .inert : production()
    }
}
