//
//  WiringConnectionOfferRefusal.swift
//  FluxKlang
//
//  Why the Add Connection conversion step has no offer for a pair (#101 WCO1). A
//  refusal offers nothing and picks nothing: there is never a default to fall back on.
//

/// Why `WiringConnectionOffers` gives no conversion or feedback choice. Each entry point checks in the order its
/// documentation lists; the first failing check is the one reported.
enum WiringConnectionOfferRefusal: Error, Hashable, Sendable {
    /// A channel count outside `GraphPort.channelRange` (1...64), which the graph contract never routes.
    case channelCountOutOfRange(source: Int, destination: Int)
    /// Equal channel counts connect directly; a map here is one the composer refuses as `conversionNotNeeded`.
    case channelCountsMatch(channels: Int)
    /// Different, valid counts without a named choice (anything but 1 → 2 and 2 → 1), left to a numeric
    /// channel-map editor.
    case unsupportedChannelCounts(source: Int, destination: Int)
    /// The pair's class is not `needsConversion`, so it takes no conversion.
    case conversionNotNeeded(WiringDestinationClass)
    /// The pair's class is not `feedbackOnly` (the bare wire closes no cycle), so it takes no feedback.
    case feedbackNotNeeded(WiringDestinationClass)
}
