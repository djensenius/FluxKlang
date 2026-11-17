import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"

/// The five WING parameters and, written out here rather than read from
/// `WingDirectSendScope`, the one address class each may write.
private let wingParameters = [
    ParameterCatalog.wingFaderDecibels, ParameterCatalog.wingMute, ParameterCatalog.wingPan,
    ParameterCatalog.wingColour, ParameterCatalog.wingSendDecibels
]
private let wingClasses: [WingAddressClass] = [.fader, .mute, .pan, .colour, .sendLevel]
private let allClasses: [WingAddressClass] = [.fader, .mute, .pan, .colour, .sendLevel]

/// `WingAddress`-built samples of `addressClass` on every strip kind, at the first
/// and last index (and, for sends, the first and last bus).
private func samples(_ addressClass: WingAddressClass) -> [String] {
    WingNodeKind.allCases.flatMap { kind -> [String] in
        [1, kind.count].flatMap { index -> [String] in
            switch addressClass {
            case .fader: [WingAddress.fader(kind, index)]
            case .mute: [WingAddress.mute(kind, index)]
            case .pan: [WingAddress.pan(kind, index)]
            case .colour: [WingAddress.color(kind, index)]
            case .sendLevel: [1, WingNodeKind.bus.count].map { WingAddress.sendLevel(kind, index, toBus: $0) }
            }
        }
    }
}

/// `WingAddress`-built nodes outside every direct-send class.
private let unclassified = [
    WingAddress.name(.channel, 1), WingAddress.sendOn(.channel, 1, toBus: 1),
    WingAddress.mainOn(.channel, 1, toMain: 1), WingAddress.mainLevel(.channel, 1, toMain: 1),
    WingAddress.channelSourceGroup(1), WingAddress.channelSourceIndex(1), WingAddress.outputSourceGroup(1),
    WingAddress.outputSourceIndex(1), WingAddress.inputName(1), WingAddress.node(.channel, 1),
    WingAddress.subscribe, WingAddress.info
]

private let scope = WingDirectSendScope()

private func admits(_ address: String, _ parameter: ParameterID) -> Bool {
    scope.admits(DirectSendTarget(address), under: .parameter(parameter))
}

extension HostAuthorityTests {
    /// AU5: `WingDirectSendScope` admits, under each WING parameter, only that
    /// parameter's address class, parsed strictly. Fakes only; nothing reaches a socket.
    @MainActor
    struct WingDirectScope {
        @Test(arguments: zip(wingParameters, wingClasses))
        func eachWingParameterAdmitsOnlyItsAddressClass(_ parameter: ParameterID,
                                                        _ admitted: WingAddressClass) {
            for addressClass in allClasses {
                for address in samples(addressClass) {
                    #expect(WingAddressClass(address: address) == addressClass, "\(address)")
                    #expect(admits(address, parameter) == (addressClass == admitted), "\(address)")
                }
            }
            for address in unclassified {
                #expect(WingAddressClass(address: address) == nil, "\(address)")
                #expect(!admits(address, parameter), "\(address)")
            }
        }

        @Test(arguments: [
            "/ch/0/mute", "/ch/41/mute", "/ch/01/mute", "/ch/+1/mute", "/ch/-1/mute", "/ch/1/mute/x",
            "/CH/1/mute", "/ch/1/MUTE", "/ch/1/send/17/lvl", "/ch/1/send/0/lvl", "/ch/1/send/01/lvl",
            "/ch/1/send/+1/lvl", "", "/ch/\u{0661}/mute", "/main/1/lvl", "/main/5/fdr", "/dca/17/fdr",
            "ch/1/mute", "/ch/1/mute/", "/ch//mute", "//ch/1/mute", "/x/ch/1/mute", "/ch/1/send/1/lvl/x",
            "/ch/1/send/1", "/ch/1 /fdr", "/ch/1/fdr ", "/ch/99999999999999999999/fdr",
            "x/ch/1/mute", "wing/ch/1/fdr", "/ch//1/mute", "/ch/\u{FF11}/mute", "/ch/1/main/1/lvl",
            "/ch/1/send/1/lvl/x/y", "/ch/1/mute////"
        ])
        func malformedOrOutOfRangeAddressesAreRefused(_ address: String) {
            #expect(WingAddressClass(address: address) == nil)
            for parameter in wingParameters {
                #expect(!admits(address, parameter), "\(parameter)")
            }
        }

        @Test func aTargetWithManySeparatorsIsRefused() {
            let address = "/ch/1/mute" + String(repeating: "/", count: 200_000)
            #expect(WingAddressClass(address: address) == nil)
            #expect(!admits(address, ParameterCatalog.wingMute))
        }

        @Test(arguments: [
            CommandScope.route(RouteID(validated: "route.main")), .patch(PatchID(validated: "patch.main")),
            .action(ActionID(validated: "action.main")), .transport, .safety, .draft(DraftID(validated: "draft.main")),
            .parameter(ParameterID(validated: "wing.name")), .parameter(DirectSendBench.liveParameter)
        ])
        func nonParameterScopesAdmitNothing(_ commandScope: CommandScope) {
            for address in allClasses.flatMap(samples) {
                #expect(!scope.admits(DirectSendTarget(address), under: commandScope), "\(address)")
            }
        }

        @Test func aScopedGrantDrivesTheControllerWithoutOutOfScopeWrites() async throws {
            let authority = try await AuthorityBench.makeAuthority(sendScope: WingDirectSendScope())
            let transport = DirectSendRecordingTransport()
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            let session = try #require(controller.sessionID)
            let mute = WingSetting(address: WingAddress.mute(.channel, 3), value: .int(1))
            let fader = WingSetting(address: WingAddress.fader(.channel, 3), value: .float(0.5))

            let widened = try await DirectSendBench.ticket(authority, parameter: ParameterCatalog.wingMute)
            let refused = await authority.authorizeDirectSend(
                widened, targets: [mute, fader].map { DirectSendTarget($0.address) })
            #expect(DirectSendBench.refusal(refused) == .outOfScope)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directCalls == 0)
            #expect(await transport.directWrites.isEmpty)

            let issued = try await DirectSendBench.grant(authority, settings: [mute],
                                                         parameter: ParameterCatalog.wingMute)
            #expect(await controller.setDirect(mute, session: session, authorization: issued))
            #expect(await transport.directCalls == 1)
            #expect(await transport.directWrites == [mute])
            #expect(controller.values[fader.address] == nil)
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }
    }
}
