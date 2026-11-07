/// A recorded negotiation outcome: the accepted spec and the capability generation it was negotiated at.
///
/// It can be built only by `RenderResourceNegotiator.negotiate` (the initialiser is `fileprivate`). The spec's
/// scratch requirement excludes alignment padding and plugin-internal allocations.
struct NegotiatedRender: Hashable, Sendable {
    let spec: RenderResourceSpec
    let generation: CapabilityGeneration

    var requiredScratchBytes: Int { spec.requiredScratchBytes }

    fileprivate init(spec: RenderResourceSpec, generation: CapabilityGeneration) {
        self.spec = spec
        self.generation = generation
    }
}

extension RenderResourceNegotiator {
    /// Accepts `proposal` against the plugin's reported `layout` and `capabilities`, or throws the first refusal.
    ///
    /// Pure: no argument is mutated, no clock or global is read. `generation` is recorded unchanged in the result;
    /// the negotiator does not validate it against any live value (the dispatch guard does that per callback).
    static func negotiate(
        _ proposal: RenderResourceSpec, layout: PluginBusLayout, capabilities: HostedRenderCapabilities,
        generation: CapabilityGeneration
    ) throws(NegotiationRefusal) -> NegotiatedRender {
        try check(proposal, layout: layout, capabilities: capabilities)
        return NegotiatedRender(spec: proposal, generation: generation)
    }
}
