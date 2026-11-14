import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Support = PeerWireTestSupport

/// In-memory byte transport: scripted inbound deliveries, recorded sends.
private actor ScriptedPeerTransport: PeerByteTransport {
    private var inbound: [[UInt8]]
    private let failReceive: Bool
    private var sendFailuresLeft: Int
    private(set) var sent: [UInt8] = []
    private(set) var receiveCount = 0

    init(inbound: [[UInt8]], failReceive: Bool = false, failSends: Int = 0) {
        self.inbound = inbound
        self.failReceive = failReceive
        sendFailuresLeft = failSends
    }

    func send(_ bytes: [UInt8]) async throws(PeerTransportError) {
        if sendFailuresLeft > 0 {
            sendFailuresLeft -= 1
            throw .disconnected
        }
        sent += bytes
    }

    func receive(maximumLength: Int) async throws(PeerTransportError) -> [UInt8]? {
        receiveCount += 1
        if inbound.isEmpty, failReceive { throw .failed }
        return inbound.isEmpty ? nil : inbound.removeFirst()
    }
}

private let hostEpoch = Support.generation(7)
private let connectionEpoch = Support.generation(4)

private func declaration(
    _ offered: [String] = ["control", "status"], required: [String] = [], versions: ClosedRange<UInt16> = 1...1
) -> PeerHello {
    guard let hello = PeerHello(
        versions: versions, offered: Support.capabilities(offered), required: Support.capabilities(required)
    ) else { preconditionFailure("invalid test declaration") }
    return hello
}

private func makeAcceptor(
    _ hello: PeerHello = declaration(), availability: PeerAcceptorAvailability = .available
) -> PeerSessionNegotiator {
    let context = PeerSessionNegotiator.AcceptorContext(
        hostEpoch: hostEpoch, connectionEpoch: connectionEpoch, availability: availability
    )
    guard let acceptor = PeerSessionNegotiator.acceptor(declaring: hello, context: context) else {
        preconditionFailure("invalid acceptor")
    }
    return acceptor
}

private func makeInitiator(_ hello: PeerHello = declaration()) -> PeerSessionNegotiator {
    guard let initiator = PeerSessionNegotiator.initiator(declaring: hello) else {
        preconditionFailure("invalid initiator")
    }
    return initiator
}

/// Decodes `messages` as one inbound stream.
private func frames(_ messages: [PeerOutboundMessage]) -> [PeerFrame] {
    var decoder = PeerFrameDecoder()
    let delivery = decoder.feed(Support.stream(messages))
    if let failure = delivery.failure { preconditionFailure("decode: \(failure)") }
    return delivery.frames
}

private func helloMessage(_ payload: [UInt8]) -> PeerOutboundMessage {
    Support.message(.hello, payload: payload)
}

private func rawHello(lower: UInt16, upper: UInt16, offered: [String]) -> [UInt8] {
    var writer = PeerWireWriter()
    writer.append(lower)
    writer.append(upper)
    Support.capabilities(offered).encode(into: &writer)
    writer.append(UInt16(0))
    return writer.bytes
}

private func acceptPayload(version: UInt16 = 1, capabilities: [String] = ["control"]) -> [UInt8] {
    PeerHelloAccept(
        version: version, hostEpoch: hostEpoch, connectionEpoch: connectionEpoch,
        capabilities: Support.capabilities(capabilities)
    ).encoded()
}

private func isControl(_ event: PeerSessionEvent) -> Bool {
    if case .control = event { true } else { false }
}

private struct HostileSequence: Sendable, CustomTestStringConvertible {
    let name: String
    let messages: [PeerOutboundMessage]
    var testDescription: String { name }
}

private let validHello = helloMessage(declaration().encoded())
private let hostileSequences: [HostileSequence] = [
    .init(name: "control before hello", messages: [Support.message(.control, epoch: 4, payload: [1])]),
    .init(name: "close before hello", messages: [Support.message(.close, epoch: 4)]),
    .init(name: "hello carrying an epoch",
          messages: [Support.message(.hello, epoch: 4, payload: declaration().encoded())]),
    .init(name: "malformed hello", messages: [helloMessage([0, 1])]),
    .init(name: "accept sent to acceptor",
          messages: [Support.message(.helloAccept, epoch: 4, payload: acceptPayload())]),
    .init(name: "second hello", messages: [validHello, validHello]),
    .init(name: "stale connection epoch", messages: [validHello, Support.message(.control, epoch: 3, payload: [1])]),
    .init(name: "missing connection epoch", messages: [validHello, Support.message(.control, payload: [1])]),
    .init(name: "close with payload", messages: [validHello, Support.message(.close, epoch: 4, payload: [0])]),
    .init(name: "control after close", messages: [validHello, Support.message(.close, epoch: 4)])
]

@Suite("PeerTransportTests+Negotiation", .productionAccessAudit)
struct PeerTransportNegotiationTests {
    @Test("Hello negotiates version, shared capabilities and the host's epochs")
    func handshake() throws {
        var initiator = makeInitiator(declaration(["control", "status", "telemetry"], required: ["control"]))
        var acceptor = makeAcceptor(declaration(["control", "status"], required: ["status"]))
        let opening = initiator.start()
        let hello = try #require(opening)
        #expect(initiator.start() == nil)
        let answer = acceptor.receive(try #require(frames([hello]).first))
        let accept = try #require(answer.outbound)
        let expected = PeerNegotiatedSession(
            protocolVersion: 1, hostEpoch: hostEpoch, connectionEpoch: connectionEpoch,
            capabilities: Support.capabilities(["control", "status"])
        )
        #expect(answer.event == .negotiated(expected))
        #expect(initiator.receive(try #require(frames([accept]).first)).event == .negotiated(expected))

        let control = try initiator.control([0xC0, 0xDE])
        let inbound = frames([validHello, control])
        let candidate = PeerControlCandidate(connectionEpoch: connectionEpoch, sequence: 2, payload: [0xC0, 0xDE])
        var negotiated = makeAcceptorNegotiated()
        #expect(negotiated.receive(inbound[1]).event == .control(candidate))
    }

    @Test("Version ranges select the highest common version or refuse", arguments: [
        (UInt16(1), UInt16(9), true), (UInt16(2), UInt16(5), false), (UInt16(1), UInt16(1), true)
    ])
    func versionNegotiation(lower: UInt16, upper: UInt16, compatible: Bool) {
        var acceptor = makeAcceptor()
        let step = acceptor.receive(frames([helloMessage(rawHello(lower: lower, upper: upper, offered: []))])[0])
        if compatible {
            #expect(acceptor.negotiated?.protocolVersion == 1)
        } else {
            #expect(step.event == .refused(.incompatibleVersion))
            #expect(step.outbound?.payload == PeerRejectReason.incompatibleVersion.encoded)
        }
        #expect(PeerSessionNegotiator.initiator(declaring: declaration(versions: 1...2)) == nil)
    }

    @Test("Initiator refuses an accept it did not offer")
    func initiatorValidatesAccept() throws {
        let cases: [(PeerOutboundMessage, PeerRefusal)] = [
            (Support.message(.helloAccept, epoch: 4, payload: acceptPayload(version: 2)), .incompatibleVersion),
            (Support.message(.helloAccept, epoch: 4, payload: acceptPayload(capabilities: ["video"])),
             .missingRequiredCapability),
            (Support.message(.helloAccept, epoch: 5, payload: acceptPayload()), .epochMismatch),
            (Support.message(.helloAccept, payload: acceptPayload()), .epochMismatch),
            (Support.message(.helloAccept, epoch: 4, payload: acceptPayload() + [0]),
             .wire(.malformedPayload(.helloAccept))),
            (Support.message(.helloReject, payload: [9]), .wire(.malformedPayload(.helloReject))),
            (Support.message(.control, epoch: 4, payload: [1]), .unexpectedFrame(.control))
        ]
        for (message, refusal) in cases {
            var initiator = makeInitiator(declaration(["control"], required: ["control"]))
            let opening = initiator.start()
            let hello = try #require(opening)
            let inbound = frames([hello, message])[1]
            #expect(initiator.receive(inbound).event == .refused(refusal))
            #expect(initiator.negotiated == nil)
        }
    }

    @Test("Missing required capabilities, ineligible and denied hosts refuse clearly")
    func clearRefusals() throws {
        var lacking = makeAcceptor(declaration(["status"]))
        let required = helloMessage(declaration(["control"], required: ["control"]).encoded())
        let step = lacking.receive(frames([required])[0])
        #expect(step.event == .refused(.missingRequiredCapability))

        var initiator = makeInitiator(declaration(["control"], required: ["control"]))
        let opening = initiator.start()
        let hello = try #require(opening)
        let reject = try #require(step.outbound)
        let answered = initiator.receive(frames([hello, reject])[1])
        #expect(answered.event == .refused(.rejectedByPeer(.missingRequiredCapability)))

        let unavailable: [(PeerAcceptorAvailability, PeerRejectReason)] = [
            (.ineligible, .ineligible), (.denied, .denied)
        ]
        for (availability, reason) in unavailable {
            var acceptor = makeAcceptor(availability: availability)
            let refused = acceptor.receive(frames([validHello])[0])
            #expect(refused.event == .refused(.locallyUnavailable(reason)))
            #expect(refused.outbound == Support.message(.helloReject, payload: reason.encoded))
        }
    }

    @Test("A refused or closed session never admits control", arguments: hostileSequences)
    fileprivate func refusalNeverAuthorizes(_ sequence: HostileSequence) {
        var acceptor = makeAcceptor()
        // A fresh, valid hello and current-epoch control after the refusal must not revive the session.
        let followUp = [validHello, Support.message(.control, epoch: 4, payload: [0x01])]
        let events = frames(sequence.messages + followUp).map { acceptor.receive($0).event }
        #expect(events.allSatisfy { !isControl($0) })
        #expect(events.suffix(2).allSatisfy { if case .refused = $0 { true } else { false } })
        #expect(acceptor.negotiated == nil)
        #expect(throws: PeerSessionError.notNegotiated) { try acceptor.control([1]) }
    }

    @Test("Decoder and transport failures are terminal refusals")
    func failuresAreTerminal() {
        var acceptor = makeAcceptorNegotiated()
        #expect(acceptor.fail(.wire(.badMagic)).event == .refused(.wire(.badMagic)))
        #expect(acceptor.fail(.endOfStream).event == .refused(.wire(.badMagic)))
        let retry = frames([validHello, validHello, Support.message(.control, epoch: 4)])
        #expect(acceptor.receive(retry[1]).event == .refused(.wire(.badMagic)))
        #expect(acceptor.receive(retry[2]).event == .refused(.wire(.badMagic)))
    }

    @Test("Channel negotiates over split in-memory deliveries")
    func channelHandshake() async throws {
        var initiator = makeInitiator()
        let opening = initiator.start()
        let hello = Support.stream([try #require(opening)])
        let transport = ScriptedPeerTransport(inbound: hello.map { [$0] })
        var channel = PeerFramedChannel(transport: transport)
        var acceptor = makeAcceptor()
        #expect(await channel.negotiate(&acceptor) == .negotiated(try #require(acceptor.negotiated)))
        let reply = await transport.sent
        var decoder = PeerFrameDecoder()
        let decoded = try decoder.strictFeed(reply)
        let accept = try #require(decoded.first)
        #expect(initiator.receive(accept).event == acceptor.negotiated.map(PeerSessionEvent.negotiated))

        let back = ScriptedPeerTransport(inbound: [reply])
        var initiatorChannel = PeerFramedChannel(transport: back)
        var fresh = makeInitiator()
        #expect(await initiatorChannel.negotiate(&fresh) == .negotiated(try #require(acceptor.negotiated)))
        #expect(await back.sent == hello)
    }

    @Test("Channel refuses garbage, truncation, end of stream and transport failure")
    func channelRefusals() async {
        let hello = Support.stream([validHello])
        let cases: [(ScriptedPeerTransport, PeerRefusal)] = [
            (ScriptedPeerTransport(inbound: [Array("garbage that is long enough!".utf8)]), .wire(.badMagic)),
            (ScriptedPeerTransport(inbound: [Array(hello.dropLast())]),
             .wire(.truncated(bufferedBytes: hello.count - 1))),
            (ScriptedPeerTransport(inbound: []), .endOfStream),
            (ScriptedPeerTransport(inbound: [], failReceive: true), .transportFailed),
            (ScriptedPeerTransport(inbound: [Array(repeating: 0, count: 16_409)]), .transportFailed)
        ]
        for (transport, refusal) in cases {
            var channel = PeerFramedChannel(transport: transport)
            var acceptor = makeAcceptor()
            #expect(await channel.negotiate(&acceptor) == .refused(refusal))
            #expect(await transport.sent.isEmpty)
            #expect(acceptor.negotiated == nil)
        }
    }

    @Test("Control is admitted and sent only when the control capability was agreed")
    func controlRequiresCapability() throws {
        var acceptor = makeAcceptor()
        let statusOnly = helloMessage(declaration(["status"]).encoded())
        let inbound = frames([statusOnly, Support.message(.control, epoch: 4, payload: [1]), validHello])
        #expect(acceptor.receive(inbound[0]).event == .negotiated(PeerNegotiatedSession(
            protocolVersion: 1, hostEpoch: hostEpoch, connectionEpoch: connectionEpoch,
            capabilities: Support.capabilities(["status"])
        )))
        #expect(throws: PeerSessionError.controlNotNegotiated) { try acceptor.control([1]) }
        #expect(acceptor.receive(inbound[1]).event == .refused(.missingRequiredCapability))
        #expect(acceptor.receive(inbound[2]).event == .refused(.missingRequiredCapability))
        #expect(acceptor.negotiated == nil)

        var closing = makeAcceptor()
        _ = closing.receive(inbound[0])
        #expect(try closing.close() == Support.message(.close, epoch: 4))
    }

    @Test("Close is one-way: in-flight current-epoch frames drop, anything else refuses")
    func closeIsOneWay() throws {
        let inbound = frames([
            validHello, Support.message(.close, epoch: 4), Support.message(.control, epoch: 4, payload: [1]),
            Support.message(.close, epoch: 4), Support.message(.control, epoch: 3, payload: [1])
        ])
        var remote = makeAcceptorNegotiated()
        #expect(remote.receive(inbound[1]) == PeerSessionStep(outbound: nil, event: .closed))
        #expect(remote.receive(inbound[2]) == PeerSessionStep(outbound: nil, event: .closed))
        #expect(remote.receive(inbound[3]) == PeerSessionStep(outbound: nil, event: .closed))
        #expect(remote.fail(.endOfStream).event == .closed)
        #expect(throws: PeerSessionError.notNegotiated) { try remote.control([1]) }
        #expect(remote.receive(inbound[4]).event == .refused(.epochMismatch))

        var local = makeAcceptorNegotiated()
        _ = try local.close()
        #expect(throws: PeerSessionError.notNegotiated) { try local.close() }
        #expect(local.receive(inbound[2]).event == .closed)
        #expect(local.receive(inbound[0]).event == .refused(.unexpectedFrame(.hello)))
    }

    @Test("Simultaneous hello and a reject carrying an epoch refuse the initiator")
    func initiatorRefusesHelloAndEpochReject() throws {
        let reject = Support.message(.helloReject, epoch: 4, payload: PeerRejectReason.denied.encoded)
        for (message, refusal) in [(validHello, PeerRefusal.unexpectedFrame(.hello)), (reject, .epochMismatch)] {
            var initiator = makeInitiator()
            let opening = initiator.start()
            let hello = try #require(opening)
            #expect(initiator.receive(frames([hello, message])[1]).event == .refused(refusal))
            #expect(initiator.negotiated == nil)
        }
    }

    @Test("A pipelined control in the hello chunk stays queued and correct")
    func pipelinedControl() async throws {
        let chunk = Support.stream([validHello, Support.message(.control, epoch: 4, payload: [0xC0, 0xDE])])
        let transport = ScriptedPeerTransport(inbound: [chunk])
        var channel = PeerFramedChannel(transport: transport)
        var acceptor = makeAcceptor()
        guard case .negotiated = await channel.negotiate(&acceptor) else { throw PeerSessionError.notNegotiated }
        let queued = try #require(try await channel.receive())
        let candidate = PeerControlCandidate(connectionEpoch: connectionEpoch, sequence: 2, payload: [0xC0, 0xDE])
        #expect(acceptor.receive(queued).event == .control(candidate))
        #expect(await transport.receiveCount == 1)
    }

    @Test("A defect behind the hello or accept refuses and sends nothing")
    func latchedDefectBlocksNegotiation() async throws {
        let garbage = Support.rawHeader(magic: [0, 0, 0, 0], sequence: 2)
        let transport = ScriptedPeerTransport(inbound: [Support.stream([validHello]) + garbage])
        var channel = PeerFramedChannel(transport: transport)
        var acceptor = makeAcceptor()
        #expect(await channel.negotiate(&acceptor) == .refused(.wire(.badMagic)))
        #expect(acceptor.negotiated == nil)
        #expect(await transport.sent.isEmpty)
        await #expect(throws: PeerChannelError.wire(.badMagic)) { try await channel.send(validHello) }

        var initiator = makeInitiator()
        let opening = initiator.start()
        let hello = try #require(opening)
        var responder = makeAcceptor()
        let accept = try #require(responder.receive(frames([hello])[0]).outbound)
        let back = ScriptedPeerTransport(inbound: [Support.stream([accept]) + garbage])
        var initiatorChannel = PeerFramedChannel(transport: back)
        #expect(await initiatorChannel.negotiate(&initiator) == .refused(.wire(.badMagic)))
        #expect(initiator.negotiated == nil)
    }

    @Test("A frame before a defect is delivered, then the defect latches")
    func channelDeliversThenLatches() async throws {
        let control = Support.message(.control, epoch: 4, payload: [0xC0, 0xDE])
        let chunk = Array(Support.stream([validHello, control]).dropFirst(Support.stream([validHello]).count))
            + Support.rawHeader(magic: [0x46, 0x4B, 0x50, 0x00], sequence: 3)
        let transport = ScriptedPeerTransport(inbound: [Support.stream([validHello]), chunk, Support.stream([control])])
        var channel = PeerFramedChannel(transport: transport)
        var acceptor = makeAcceptor()
        guard case .negotiated = await channel.negotiate(&acceptor) else { throw PeerSessionError.notNegotiated }
        let frame = try #require(try await channel.receive())
        let candidate = PeerControlCandidate(connectionEpoch: connectionEpoch, sequence: 2, payload: [0xC0, 0xDE])
        #expect(acceptor.receive(frame).event == .control(candidate))
        for _ in 0..<3 {
            await #expect(throws: PeerChannelError.wire(.badMagic)) { try await channel.receive() }
        }
        #expect(await transport.receiveCount == 2)
    }

    @Test("A failed send latches: later sends and receives throw it and nothing more is written")
    func sendFailureLatches() async throws {
        let transport = ScriptedPeerTransport(inbound: [Support.stream([validHello])], failSends: 1)
        var channel = PeerFramedChannel(transport: transport)
        let control = Support.message(.control, epoch: 4, payload: [1])
        let latched = PeerChannelError.transport(.disconnected)
        await #expect(throws: latched) { try await channel.send(control) }
        await #expect(throws: latched) { try await channel.send(control) }
        await #expect(throws: latched) { try await channel.receive() }
        var acceptor = makeAcceptor()
        #expect(await channel.negotiate(&acceptor) == .refused(.transportFailed))
        #expect(await transport.sent.isEmpty)
        #expect(await transport.receiveCount == 0)
    }

    @Test("A negotiated session is failed by a later latched defect")
    func renegotiateAfterLatchedDefect() async throws {
        let transport = ScriptedPeerTransport(inbound: [Support.stream([validHello]), [0x46, 0x4B, 0x50, 0x00]])
        var channel = PeerFramedChannel(transport: transport)
        var acceptor = makeAcceptor()
        guard case .negotiated = await channel.negotiate(&acceptor) else { throw PeerSessionError.notNegotiated }
        await #expect(throws: PeerChannelError.wire(.badMagic)) { try await channel.receive() }
        #expect(await channel.negotiate(&acceptor) == .refused(.wire(.badMagic)))
        #expect(acceptor.negotiated == nil)
        #expect(throws: PeerSessionError.notNegotiated) { try acceptor.control([1]) }
        #expect(await channel.negotiate(&acceptor) == .refused(.wire(.badMagic)))
        #expect(await transport.receiveCount == 2)
    }

    @Test("One maximal delivery of empty control frames drains in FIFO order")
    func maximalDeliveryDrainsInOrder() async throws {
        let limits = try #require(PeerFrameLimits(maximumPayloadBytes: PeerFrameLimits.payloadCeiling))
        let count = limits.maximumFrameBytes / PeerWire.headerByteCount
        #expect(count == 43_691)
        let chunk = Support.stream(Array(repeating: Support.message(.control, epoch: 4), count: count), limits: limits)
        let transport = ScriptedPeerTransport(inbound: [chunk])
        var channel = PeerFramedChannel(transport: transport, limits: limits)
        var sequences: [UInt32] = []
        sequences.reserveCapacity(count)
        while let frame = try await channel.receive() { sequences.append(frame.sequence) }
        #expect(sequences == Array(1...UInt32(count)))
        #expect(await transport.receiveCount == 2)
    }

    @Test("Negotiating a refused or closed session returns without reading")
    func terminalNegotiate() async throws {
        let live = Support.stream([validHello, Support.message(.control, epoch: 4, payload: [1])])
        var refused = makeAcceptor()
        _ = refused.fail(.endOfStream)
        var closed = makeAcceptorNegotiated()
        _ = try closed.close()
        for (session, event) in [(refused, PeerSessionEvent.refused(.endOfStream)), (closed, .closed)] {
            var copy = session
            let transport = ScriptedPeerTransport(inbound: [live])
            var channel = PeerFramedChannel(transport: transport)
            #expect(await channel.negotiate(&copy) == event)
            #expect(copy.state == session.state)
            #expect(await transport.receiveCount == 0)
            #expect(await transport.sent.isEmpty)
        }
    }
}

private func makeAcceptorNegotiated() -> PeerSessionNegotiator {
    var acceptor = makeAcceptor()
    _ = acceptor.receive(frames([validHello])[0])
    return acceptor
}
