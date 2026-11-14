import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
@MainActor
struct SystemPermissionProbeIsolationTests {
    enum Access: CaseIterable, Sendable {
        case microphoneStatus, microphoneRequest, microphoneState
        case localNetworkStatus, localNetworkRequest
    }

    @Test(arguments: Access.allCases)
    func isolatedAccessIsUnknownWithoutQueryingOrRequesting(_ access: Access) async throws {
        try requireIsolatedStartupProcess()
        let audit = ProductionAccessAudit()
        let probe = SystemPermissionProbe(mirroring: audit)
        let before = audit.snapshot()
        #expect(before.count(.passiveConstruction, for: .permissionProbe) == 1)
        #expect(before.count(.factoryEvaluated, for: .permissionProbe) == 0)
        #expect(before.count(.attempted, for: .permissionProbe) == 0)
        #expect(before.count(.denied, for: .permissionProbe) == 0)
        #expect(before.count(.apiEntered, for: .permissionProbe) == 0)

        let status: PermissionStatus
        switch access {
        case .microphoneStatus:
            status = probe.status(of: .microphone)
        case .microphoneRequest:
            status = await probe.request(.microphone)
        case .microphoneState:
            let state = probe.state(of: .microphone)
            #expect(state.capability == .microphone)
            status = state.status
        case .localNetworkStatus:
            status = probe.status(of: .localNetwork)
        case .localNetworkRequest:
            status = await probe.request(.localNetwork)
        }
        #expect(status == .unknown)
        let after = audit.snapshot()
        #expect(after.count(.attempted, for: .permissionProbe) == 1)
        #expect(after.count(.denied, for: .permissionProbe) == 1)
        #expect(after.count(.apiEntered, for: .permissionProbe) == 0)
    }

    @Test(arguments: [PermissionCapability.multicast, .bluetooth])
    func pureCapabilitiesPreserveTheirStatusWithoutProductionAccess(_ capability: PermissionCapability) async throws {
        try requireIsolatedStartupProcess()
        let audit = ProductionAccessAudit()
        let probe = SystemPermissionProbe(mirroring: audit)
        let expected: PermissionStatus = capability == .bluetooth
            ? .unsupported : LocalNetworkAccess.currentBroadcastDiscovery.status
        #expect(probe.status(of: capability) == expected)
        #expect(await probe.request(capability) == expected)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .permissionProbe) == 0)
        #expect(snapshot.count(.denied, for: .permissionProbe) == 0)
        #expect(snapshot.count(.apiEntered, for: .permissionProbe) == 0)
    }
}
