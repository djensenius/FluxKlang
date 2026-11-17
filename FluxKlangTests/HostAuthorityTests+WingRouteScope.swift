import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"
private let scope = WingDirectSendScope()
private let applyScope = CommandScope.route(WingDirectSendScope.applyRoute)

private func admits(_ address: String, under commandScope: CommandScope = applyScope) -> Bool {
    scope.admits(DirectSendTarget(address), under: commandScope)
}

private let strips = WingNodeKind.allCases.flatMap { kind in (1...kind.count).map { (kind, $0) } }
private let connectors = WingOutputConnectorBank.allCases.flatMap { bank in
    bank.connectorRange.map { WingOutputConnector(bank: bank, index: $0) }
}

/// Every address `WingAddress` builds for `routeClass`, over the full index ranges.
private func builderOutputs(_ routeClass: WingRouteAddressClass) -> [String] {
    let buses = 1...WingNodeKind.bus.count
    let mains = 1...WingNodeKind.main.count
    switch routeClass {
    case .name: return strips.map { WingAddress.name($0, $1) }
    case .fader: return strips.map { WingAddress.fader($0, $1) }
    case .mute: return strips.map { WingAddress.mute($0, $1) }
    case .sendOn: return strips.flatMap { kind, index in buses.map { WingAddress.sendOn(kind, index, toBus: $0) } }
    case .sendLevel:
        return strips.flatMap { kind, index in buses.map { WingAddress.sendLevel(kind, index, toBus: $0) } }
    case .mainOn: return strips.flatMap { kind, index in mains.map { WingAddress.mainOn(kind, index, toMain: $0) } }
    case .mainLevel:
        return strips.flatMap { kind, index in mains.map { WingAddress.mainLevel(kind, index, toMain: $0) } }
    case .channelSourceGroup, .channelSourceIndex, .outputSourceGroup, .outputSourceIndex:
        return sourceOutputs(routeClass)
    }
}

/// The source-patch classes' builder outputs; empty for any other class.
private func sourceOutputs(_ routeClass: WingRouteAddressClass) -> [String] {
    let channels = 1...WingNodeKind.channel.count
    let localOutputs = 1...WingAddress.localOutputCount
    switch routeClass {
    case .channelSourceGroup: return channels.map { WingAddress.channelSourceGroup($0) }
    case .channelSourceIndex: return channels.map { WingAddress.channelSourceIndex($0) }
    case .outputSourceGroup:
        return connectors.map { WingAddress.outputSourceGroup($0) }
            + localOutputs.map { WingAddress.outputSourceGroup($0) }
    case .outputSourceIndex:
        return connectors.map { WingAddress.outputSourceIndex($0) }
            + localOutputs.map { WingAddress.outputSourceIndex($0) }
    default: return []
    }
}

private let routeAddresses = WingRouteAddressClass.allCases.flatMap(builderOutputs)

/// Builder outputs Studio apply never sends.
private let panAndColour = strips.flatMap { [WingAddress.pan($0, $1), WingAddress.color($0, $1)] }

private func port(_ node: StudioNode, _ side: StudioPortSide) -> StudioPortRef {
    StudioPortRef(nodeID: node.id, side: side, port: 0)
}

/// A compiled Studio apply touching every route class: a stereo synth to a Final
/// Mix stem, a placed Space stem (through a reverb patched on AES50-B) and a
/// custom stem on AES50-C, with the standard quad speakers. Safety settings are
/// the stems' faders and mutes, as `AppModel.applyStudio` picks them.
private func studioApply() throws -> (settings: [WingSetting], safety: [WingSetting]) {
    let synth = Equipment(name: "Synth", outputs: ["Out L", "Out R"], isStereo: true)
    let reverbGear = Equipment(name: "Reverb", inputs: ["In L", "In R"], outputs: ["Out L", "Out R"], isStereo: true)
    let reverb = Effect(name: "Reverb", equipmentID: reverbGear.id)
    let dry = StudioEndpoint(name: "Dry", destination: .finalMix)
    let wet = StudioEndpoint(name: "Wet", destination: .space, placement: VoicePlacement())
    let desk = StudioEndpoint(name: "Desk", destination: .custom, outputConnectors: [
        WingOutputConnector(bank: .aes50C, index: 15), WingOutputConnector(bank: .aes50C, index: 16)
    ])
    let synthNode = StudioNode(kind: .instrument(synth.id), title: synth.name)
    let reverbNode = StudioNode(kind: .effect(reverb.id), title: reverb.name)
    let stems = [dry, wet, desk].map { StudioNode(kind: .endpoint($0.id), title: $0.name) }
    var graph = StudioGraph(nodes: [synthNode, reverbNode] + stems)
    let dryNode = try #require(stems.first)
    let wetNode = try #require(stems.dropFirst().first)
    let deskNode = try #require(stems.last)
    graph.connect(from: port(synthNode, .output), to: port(dryNode, .input))
    graph.connect(from: port(synthNode, .output), to: port(reverbNode, .input))
    graph.connect(from: port(reverbNode, .output), to: port(wetNode, .input))
    graph.connect(from: port(synthNode, .output), to: port(deskNode, .input))
    let connections = GlobalStudioConnections(home: StudioHomeConnections(
        inputs: [
            StudioInputConnection(connector: 11, equipmentID: synth.id, outputPort: 0),
            StudioInputConnection(connector: 12, equipmentID: synth.id, outputPort: 1),
            StudioInputConnection(connector: 21, equipmentID: reverbGear.id, outputPort: 0),
            StudioInputConnection(connector: 22, equipmentID: reverbGear.id, outputPort: 1)
        ],
        outputs: [
            StudioOutputConnection(connector: 1, destinationName: "Main Speakers L"),
            StudioOutputConnection(connector: 2, destinationName: "Main Speakers R"),
            StudioOutputConnection(bank: .aes50B, connector: 15, equipmentID: reverbGear.id, inputPort: 0),
            StudioOutputConnection(bank: .aes50B, connector: 16, equipmentID: reverbGear.id, inputPort: 1)
        ]
    ))
    let compiled = StudioSignalCompiler.compile(StudioCompilationInput(
        graph: graph, endpoints: [dry, wet, desk], effects: [reverb], connections: connections,
        equipment: [synth, reverbGear], speakers: SpeakerArray.standardQuad.speakers
    ))
    #expect(!compiled.hasErrors)
    #expect(compiled.resourcePlan.allocations.count == 3)
    let stemNodes = compiled.resourcePlan.allocations.flatMap { [$0.controlNode, $0.rightControlNode] }
    let safetyAddresses = Set(stemNodes.compactMap { $0 }.flatMap { node in
        [WingAddress.fader(node.kind, node.index), WingAddress.mute(node.kind, node.index)]
    })
    return (compiled.settings, compiled.settings.filter { safetyAddresses.contains($0.address) })
}

extension HostAuthorityTests {
    /// AU7a: `WingDirectSendScope` admits a Studio apply's addresses under the one
    /// reserved route, `.route(applyRoute)`, parsed strictly, and nothing under any
    /// other route. Fakes only; nothing reaches a socket.
    @MainActor
    struct WingRouteScope {
        @Test func applyRouteIsAValidRouteID() throws {
            let route = WingDirectSendScope.applyRoute
            #expect(route.rawValue == "wing.apply")
            #expect(try RouteID(route.rawValue) == route)
        }

        @Test func routeScopeAdmitsEveryStudioApplyAddress() throws {
            for routeClass in WingRouteAddressClass.allCases {
                for address in builderOutputs(routeClass) {
                    #expect(WingRouteAddressClass(address: address) == routeClass, "\(address)")
                    #expect(admits(address), "\(address)")
                }
            }
            let longest = try #require(routeAddresses.map(\.utf8.count).max())
            #expect(longest == WingRouteAddressClass.maximumByteCount)

            let (settings, safety) = try studioApply()
            let classes = settings.compactMap { WingRouteAddressClass(address: $0.address) }
            #expect(classes.count == settings.count)
            #expect(Set(classes) == Set(WingRouteAddressClass.allCases))
            #expect(settings.allSatisfy { admits($0.address) })
            #expect(Set(safety.compactMap { WingRouteAddressClass(address: $0.address) }) == [.fader, .mute])
        }

        @Test(arguments: [
            "/bus/05/name", "/bus/0/fdr", "/ch/41/mute", "/dca/17/name", "/main/5/fdr", "/ch/+1/name", "/ch/-1/mute",
            "/ch/1/send/0/on", "/ch/1/send/17/lvl", "/ch/1/send/01/on", "/ch/1/main/0/on", "/ch/1/main/5/lvl",
            "/ch/1/main/01/lvl", "/ch/0/in/conn/grp", "/ch/41/in/conn/in", "/bus/1/in/conn/grp", "/aux/1/in/conn/in",
            "/io/out/LCL/0/grp", "/io/out/LCL/9/grp", "/io/out/LCL/01/in", "/io/out/A/17/in", "/io/out/C/0/grp",
            "/io/out/D/1/grp", "/io/out/lcl/1/grp", "/io/out/USB/1/in", "/io/in/LCL/1/name", "/io/in/LCL/1/grp",
            "/io/LCL/1/grp", "/io/out/LCL/1", "/io/out/LCL/1/grp/x", "/io/out/LCL/1/name", "/io/out/LCL/1/on",
            "/xyz/1/name", "/CH/1/name", "/ch/1/NAME", "/ch/1/Send/1/on", "/ch/1/send/1/LVL", "/IO/out/LCL/1/grp",
            "/ch/1", "/ch/1/name/x", "/ch/1/send/1", "/ch/1/send/1/on/x", "/ch/1/main/1", "/ch/1/main/1/x",
            "/ch/1/send/1/level", "/ch/1/in/conn", "/ch/1/in/conn/grp/x", "/ch/1/in/grp", "/ch/1/pan", "/ch/1/col",
            "", "/", "ch/1/name", "/ch/1/name/", "//ch/1/name", "/ch//name", "/ch/1 /name", "/ch/\u{0661}/name",
            "/ch/\u{FF11}/mute", "/ch/99999999999999999999/mute", WingAddress.node(.bus, 1), WingAddress.inputName(1),
            WingAddress.subscribe, WingAddress.info
        ])
        func routeScopeRefusesMalformedAndUnknownShapes(_ address: String) {
            #expect(WingRouteAddressClass(address: address) == nil)
            #expect(!admits(address))
        }

        @Test func routeScopeRefusesPanColourAndOverlongAddresses() {
            for address in panAndColour {
                #expect(WingRouteAddressClass(address: address) == nil, "\(address)")
                #expect(!admits(address), "\(address)")
            }
            let overlong = "/" + String(repeating: "x", count: 100_000) + "/1/mute"
            let separators = WingAddress.name(.channel, 1) + String(repeating: "/", count: 200_000)
            let oneOver = "/bus/16/send/16/lvl/"
            #expect(oneOver.utf8.count == WingRouteAddressClass.maximumByteCount + 1)
            for address in [overlong, separators, oneOver] {
                #expect(WingRouteAddressClass(address: address) == nil)
                #expect(!admits(address))
            }
        }

        @Test(arguments: ["wing.apply2", "wing", "Wing.apply", "wing.apply.x", "route.main"])
        func otherRouteIDsAdmitNothing(_ raw: String) async throws {
            let route = try RouteID(raw)
            let studio = try studioApply().settings.map(\.address)
            for address in routeAddresses + studio {
                #expect(!admits(address, under: .route(route)), "\(address)")
            }

            let authority = try await AuthorityBench.makeAuthority(sendScope: WingDirectSendScope())
            let ticket = try await DirectSendBench.ticket(authority, route: route)
            let refused = await authority.authorizeDirectSend(ticket, targets: studio.map { DirectSendTarget($0) })
            #expect(DirectSendBench.refusal(refused) == .outOfScope)
            #expect(await authority.outstandingDirectSendCount() == 0)
        }

        @Test(arguments: [
            CommandScope.safety, .draft(DraftID(validated: "draft.main")), .transport,
            .patch(PatchID(validated: "patch.main")), .action(ActionID(validated: "action.main"))
        ])
        func safetyAndDraftScopesStillAdmitNothing(_ commandScope: CommandScope) {
            for address in routeAddresses {
                #expect(!admits(address, under: commandScope), "\(address)")
            }
        }

        /// Under a `.parameter` scope, only that parameter's `WingAddressClass`
        /// passes; every routing-only class is still refused.
        @Test func parameterScopesStillRefuseRouting() {
            let routingOnly: [WingRouteAddressClass] = [
                .name, .sendOn, .mainOn, .mainLevel, .channelSourceGroup, .channelSourceIndex, .outputSourceGroup,
                .outputSourceIndex
            ]
            for parameter in WingDirectSendScope.parameterClasses.keys {
                for address in routingOnly.flatMap(builderOutputs) {
                    #expect(!admits(address, under: .parameter(parameter)), "\(parameter) \(address)")
                }
            }
        }

        /// One safety and one routing write are dropped once, so all four phases
        /// mint a `.bind(applyRoute)` grant against the real scope.
        @Test func gatedStudioApplyVerifiesUnderRouteScope() async throws {
            let (settings, safety) = try studioApply()
            let safeFader = try #require(safety.first { WingRouteAddressClass(address: $0.address) == .fader })
            let routing = try #require(settings.first { WingRouteAddressClass(address: $0.address) == .sendOn })
            let authority = try await AuthorityBench.makeAuthority(sendScope: WingDirectSendScope())
            let minter = GatedApplyMinter(authority, route: WingDirectSendScope.applyRoute)
            let transport = EchoingDirectTransport()
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            let session = try #require(controller.sessionID)
            await transport.drop(safeFader.address, times: 1)
            await transport.drop(routing.address, times: 1)

            let result = await controller.applyAndVerify(settings, safetySettings: safety,
                                                         session: session, minting: minter)
            #expect(result.state == .verified)
            #expect(result.confirmedCount == settings.count)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == WingDirectApplyPhase.allCases)
            #expect(mints.allSatisfy { $0.outstandingBefore == 0 })
            #expect(mints.allSatisfy { DirectSendBench.refusal($0.result) == nil })
            let safetyTargets = Set(safety.map { DirectSendTarget($0.address) })
            #expect(mints.first?.targets == safetyTargets)
            #expect(mints.dropFirst(2).first?.targets
                == Set(settings.map { DirectSendTarget($0.address) }).subtracting(safetyTargets))
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await transport.directWrites.count == settings.count + 2)
            #expect(await transport.legacyWrites.isEmpty)
            #expect(settings.allSatisfy { controller.confirmedValues[$0.address] == $0.value })
            await controller.disconnect()
        }
    }
}
