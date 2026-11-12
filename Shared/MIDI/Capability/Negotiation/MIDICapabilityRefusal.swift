/// The bounds of the capability resolver. Both are inclusive: a list of exactly this many entries is accepted and
/// one more is refused with the count it was given. Nothing is truncated.
///
/// `maximumProfiles` bounds the combined list of `MIDICapabilityCIAnswer.answered` (enabled and disabled ids
/// together). The decoder's bound, `MIDICIProfileMessage.maximumProfilesPerList`, is separate and applies to each
/// list of one Reply alone, so a Reply can decode cleanly and still exceed the combined bound.
/// `MIDICapabilityDiscovery` applies the bound to the ids it stores over every address and refuses the Reply that
/// would exceed it with `MIDICapabilityDiscoveryRefusal.tooManyProfiles` before building facts; the resolver's own
/// `tooManyProfiles` check stays for facts built any other way.
enum MIDICapabilityLimits {
    static let maximumFunctionBlocks = UMPStreamEndpointInfo.maximumFunctionBlocks
    static let maximumProfiles = 64
}

/// Every refusal from `MIDICapabilityProfileID.make` and `MIDICapabilityResolver.negotiate`. A refusal carries no
/// partial result.
///
/// `negotiate` reports the first of these defects, in this order:
/// 1. `tooManyFunctionBlocks`, 2. `tooManyProfiles` (both compare counts before any copy, sort or per-element work),
/// 3. `endpointInvalid`, 4. `functionBlocksWithoutEndpoint`, 5. `functionBlockCountMismatch`,
/// 6. `functionBlockInvalid`, 7. `duplicateFunctionBlockIndex`, 8. `overlappingFunctionBlockGroups`,
/// 9. `duplicateProfile`.
/// Checks 6 to 9 run over copies sorted by value, so any permutation of the inputs gives the same refusal. Every
/// check runs whatever the capability category bits say. `invalidProfileID` comes only from the profile factory.
enum MIDICapabilityRefusal: Error, Equatable, Sendable {
    /// More than `MIDICapabilityLimits.maximumFunctionBlocks` function blocks were supplied.
    case tooManyFunctionBlocks(count: Int)
    /// More than `MIDICapabilityLimits.maximumProfiles` profiles were supplied, counting the combined list (enabled
    /// and disabled ids together); see `MIDICapabilityLimits`.
    case tooManyProfiles(count: Int)
    /// `UMPStreamEndpointInfo.validate()` refused the endpoint.
    case endpointInvalid(UMPStreamRefusal)
    /// Function blocks were supplied but there is no endpoint that could have declared them.
    case functionBlocksWithoutEndpoint(count: Int)
    /// The endpoint declares a different number of function blocks than were supplied (a static or a dynamic list
    /// alike: discovery has to be complete).
    case functionBlockCountMismatch(declared: Int, supplied: Int)
    /// `UMPStreamFunctionBlockInfo.validate()` refused the block with this own index (it may be out of range). The
    /// refused block is the first one in index order.
    case functionBlockInvalid(index: Int, UMPStreamRefusal)
    /// Two blocks carry this index; it is the smallest repeated index.
    case duplicateFunctionBlockIndex(Int)
    /// The groups of these two blocks (named by their indices) overlap, whether the blocks are active or not.
    /// The pair is the first one found with the first index ascending, then the second index ascending.
    case overlappingFunctionBlockGroups(first: Int, second: Int)
    /// Two equal profile identifiers were supplied; this is the smallest repeated one.
    case duplicateProfile(MIDICapabilityProfileID)
    /// A profile identifier is not five bytes (`offset` is 0) or has a byte above 0x7F (`offset` is the position of
    /// the first such byte). `count` is the number of bytes given.
    case invalidProfileID(count: Int, offset: Int)
}
