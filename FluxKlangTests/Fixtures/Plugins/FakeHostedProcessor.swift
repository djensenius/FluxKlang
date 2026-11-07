//
//  FakeHostedProcessor.swift
//  FluxKlangTests
//
//  A scripted, bounded stand-in for a hosted plugin: it answers negotiation from a script and counts what the dispatch
//  guard let through, including out-of-bounds attempts. It imports no audio framework and holds no threads, timers or
//  buffers. Counters saturate; the dispatch record keeps only the first `dispatchCapacity` block sizes.
//

#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// One scripted negotiation answer of `FakeHostedProcessor`.
enum FakeHostedStep: Hashable, Sendable {
    case accept
    case refuse(NegotiationRefusal)
}

struct FakeHostedProcessor: Sendable {
    static let dispatchCapacity = 256

    let capabilities: HostedRenderCapabilities
    let layout: PluginBusLayout
    private let script: [FakeHostedStep]
    private var nextStep = 0
    private(set) var dispatchedFrames: [Int] = []
    private(set) var droppedCalls = 0
    private(set) var outOfBoundsAttempts = 0
    private(set) var silencedCalls = 0
    private(set) var idleCalls = 0

    init(capabilities: HostedRenderCapabilities, layout: PluginBusLayout, script: [FakeHostedStep]) {
        self.capabilities = capabilities
        self.layout = layout
        self.script = script
    }

    /// Consumes one script step per call; an exhausted script behaves as `.accept`.
    mutating func negotiate(
        _ proposal: RenderResourceSpec, generation: CapabilityGeneration
    ) throws(NegotiationRefusal) -> NegotiatedRender {
        let step = nextStep < script.count ? script[nextStep] : .accept
        nextStep = Self.saturatingIncrement(nextStep)
        if case .refuse(let refusal) = step { throw refusal }
        return try RenderResourceNegotiator.negotiate(
            proposal, layout: layout, capabilities: capabilities, generation: generation)
    }

    /// Acts on a guard decision; `.dispatch` records its frames and counts a block outside `0...maximumFrames`.
    mutating func dispatch(_ decision: DispatchDecision, negotiated: NegotiatedRender) {
        switch decision {
        case .dispatch(let frames):
            if dispatchedFrames.count < Self.dispatchCapacity {
                dispatchedFrames.append(frames)
            } else {
                droppedCalls = Self.saturatingIncrement(droppedCalls)
            }
            if frames > negotiated.spec.maximumFrames || frames < 0 {
                outOfBoundsAttempts = Self.saturatingIncrement(outOfBoundsAttempts)
            }
        case .idle:
            idleCalls = Self.saturatingIncrement(idleCalls)
        case .silence:
            silencedCalls = Self.saturatingIncrement(silencedCalls)
        }
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? value : value + 1
    }
}
