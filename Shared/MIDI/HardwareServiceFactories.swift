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
    /// Builds the live WING transport; `probe` is AppModel's evidence-aware wrapper of `localNetworkProbe`.
    var makeWingTransport: @Sendable (UInt16, @escaping LocalNetworkProbe.Check) -> any WingTransporting = {
        WingTransport(remotePort: $0, localNetworkProbe: $1)
    }
    /// Startup-reconnect evidence (see `LocalNetworkGrantEvidence`).
    var localNetworkEvidence: LocalNetworkGrantEvidence = .current

    static let production = HardwareServiceFactories(
        makeLaunchControlXLInput: { CoreMIDIInput() }, makePermissionProbe: { SystemPermissionProbe() },
        localNetworkProbe: LocalNetworkProbe.connectErrno)
    static let inert = HardwareServiceFactories(makeLaunchControlXLInput: { InertLaunchControlXLInput() })

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
