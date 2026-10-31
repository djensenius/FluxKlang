//
//  PermissionStateTests.swift
//  FluxKlangTests
//
//  Truthful permission states, prompt-free startup gating, and Local Network
//  denial reporting for the manual-IP WING path. No test opens a socket,
//  sends traffic, or queries/requests a system permission.
//

import Darwin
import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct PermissionStateTests {
    @Test func onlyGrantedStatesAreUsableAndDenialsExplainTheFix() {
        let denied = PermissionState(capability: .localNetwork, status: .denied)
        #expect(!denied.isUsable)
        #expect(denied.reason.contains("Privacy & Security › Local Network"))
        #expect(PermissionState(capability: .microphone, status: .granted).isUsable)
        for status in [PermissionStatus.notDetermined, .denied, .restricted, .unknown, .unsupported] {
            for capability in PermissionCapability.allCases {
                let state = PermissionState(capability: capability, status: status)
                #expect(!state.isUsable)
                #expect(!state.reason.contains("allowed."), "\(capability) \(status) must not claim access")
            }
        }
    }

    @Test func connectErrnoMapsToInferredLocalNetworkStatus() {
        #expect(LocalNetworkAccess.status(afterConnectErrno: nil) == .granted)
        #expect(LocalNetworkAccess.status(afterConnectErrno: EHOSTUNREACH) == .denied)
        #expect(LocalNetworkAccess.status(afterConnectErrno: EPERM) == .denied)
        #expect(LocalNetworkAccess.status(afterConnectErrno: ECONNREFUSED) == .unknown)
    }

    @Test func iOSBroadcastDiscoveryIsUnsupportedWithoutTheMulticastEntitlement() {
        func status(iOS: Bool, entitled: Bool) -> PermissionStatus {
            LocalNetworkAccess.broadcastDiscovery(isIOS: iOS, hasMulticastEntitlement: entitled).status
        }
        #expect(status(iOS: true, entitled: false) == .unsupported)
        #expect(status(iOS: true, entitled: true) == .unknown)
        #expect(status(iOS: false, entitled: false) == .unknown)
        #expect(!LocalNetworkAccess.hasMulticastEntitlement)
        #if os(iOS)
        #expect(LocalNetworkAccess.currentBroadcastDiscovery.status == .unsupported)
        #endif
    }

    @Test func startupReconnectRequiresOnDeviceGrantEvidence() {
        func allowed(testing: Bool = false, uiTesting: Bool = false, connected: Bool = false,
                     lastHost: Bool = true, grant: Bool = true) -> Bool {
            StartupReconnectPolicy.shouldReconnect(
                isTesting: testing, isUITesting: uiTesting, isConnected: connected,
                hasLastHost: lastHost, hasLocalNetworkGrant: grant)
        }
        #expect(allowed())
        #expect(!allowed(grant: false), "A synced/restored host without a grant would prompt at launch")
        #expect(!allowed(testing: true))
        #expect(!allowed(uiTesting: true))
        #expect(!allowed(connected: true))
        #expect(!allowed(lastHost: false))
        #expect(!AppModel(hardware: .inert).allowsStartupReconnect)
    }

    @Test func grantEvidenceIsHostAndBuildScopedAndExcludedFromBackup() throws {
        let directory = AppPersistence.directory.appendingPathComponent("permission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("local-network-grant")
        let evidence = LocalNetworkGrantEvidence(fileURL: file, buildFingerprint: "1.0-7")
        #expect(!evidence.hasGrant)
        #expect(!evidence.hasGrant(for: "192.0.2.10"))

        evidence.recordGrant(for: "192.0.2.10")

        #expect(evidence.hasGrant)
        #expect(evidence.hasGrant(for: "192.0.2.10"))
        #expect(!evidence.hasGrant(for: "192.0.2.11"))
        let newBuild = LocalNetworkGrantEvidence(fileURL: file, buildFingerprint: "1.0-8")
        #expect(!newBuild.hasGrant(for: "192.0.2.10"))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        evidence.clear()
        #expect(!evidence.hasGrant)
    }

    @Test func manualIPConnectReportsLocalNetworkDenialInsteadOfConnecting() async {
        let transport = WingTransport(localNetworkProbe: { _, _ in EHOSTUNREACH })
        let controller = WingController(transport: transport)

        await controller.connect(host: "192.0.2.10")

        guard case .failed(let reason) = controller.connection else {
            Issue.record("Expected a truthful failure, got \(controller.connection)")
            return
        }
        #expect(reason == PermissionState(capability: .localNetwork, status: .denied).reason)
        #expect(controller.transportWriteCount == 0)
        #expect(await transport.sessionID == nil, "No socket may open after a blocked probe")
    }

    @Test func blockedProbeThrowsBeforeAnySocketOpens() async {
        let transport = WingTransport(localNetworkProbe: { _, _ in ECONNREFUSED })
        await #expect(throws: WingTransportError.localNetworkBlocked(errno: ECONNREFUSED)) {
            try await transport.start(remoteHost: "192.0.2.10", localPort: nil, broadcast: false)
        }
        let message = WingTransportError.localNetworkBlocked(errno: ECONNREFUSED).localizedDescription
        #expect(message.hasPrefix("Couldn't open a network path to the WING"))
    }

    @Test func unentitledDiscoveryExplainsItselfWithoutScanning() async {
        let unsupported = LocalNetworkAccess.broadcastDiscovery(isIOS: true, hasMulticastEntitlement: false)
        let discovery = WingDiscovery(broadcastPermission: unsupported)

        await discovery.scan(duration: .zero)

        #expect(discovery.unavailableReason == unsupported.reason)
        #expect(discovery.responders.isEmpty)
        #expect(!discovery.isScanning)
    }

    @Test func testHostsGetAnInertPermissionProbe() async {
        let probe = HardwareServiceFactories.current.makePermissionProbe()
        #expect(probe is InertPermissionProbe)
        #expect(HardwareServiceFactories.inert.makePermissionProbe() is InertPermissionProbe)
        #expect(HardwareServiceFactories.production.makePermissionProbe() is SystemPermissionProbe)
        #expect(probe.state(of: .microphone).status == .unknown)
        let inert = InertPermissionProbe()
        _ = await inert.request(.microphone)
        #expect(inert.requests == [.microphone])
    }
}
