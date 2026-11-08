/// Why a quarter-frame emit plan was not built. A refusal builds nothing.
///
/// When a request has several defects, the first matching case in declaration order is reported:
/// `frameCountTooLarge`, `frameCountTooSmall`, `frameCountNotWholeSequences`, `invalidTimebase`,
/// `timebaseTooCoarse`, `tickOverflow`.
enum MTCEmitRefusal: Error, Equatable, Sendable {
    /// More frames than `MTCEmitPlan.maximumFrames`; carries the requested count.
    case frameCountTooLarge(Int)
    /// Fewer frames than `MTCEmitPlan.minimumFrames` (zero and negative counts included).
    case frameCountTooSmall(Int)
    /// An odd count within range, which would end in the middle of an eight-piece sequence.
    case frameCountNotWholeSequences(Int)
    /// A timebase whose numerator or denominator is zero.
    case invalidTimebase
    /// A timebase so coarse that one quarter-frame period is shorter than one host tick.
    case timebaseTooCoarse
    /// An entry whose host tick does not fit in `UInt64`, or an intermediate product does not fit in `Int128`.
    case tickOverflow
}
