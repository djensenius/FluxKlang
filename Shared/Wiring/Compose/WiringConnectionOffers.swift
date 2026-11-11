//
//  WiringConnectionOffers.swift
//  FluxKlang
//
//  The labelled choices of the Add Connection conversion step (#101 WCO1;
//  phone-compact-routing.md "Add Connection flow", wiring.md "Connection
//  validation"). A channel-count mismatch becomes a fixed list of named channel
//  maps, and a wire that closes a cycle becomes exactly one feedback choice.
//  Nothing is preselected: a list has no default or recommended entry, and the
//  caller passes only the offer the user picked to `WiringConnectRequest`.
//  Pure and deterministic: fixed English labels, a fixed order, no graph access.
//

/// One named channel map for a pair whose channel counts differ. Built only by `WiringConnectionOffers`.
struct WiringConversionOffer: Hashable, Sendable {
    /// The fixed English label the picker shows; `conversion.label` carries the same text.
    private(set) var label: String
    /// One row per destination channel listing the source channels summed into it; an empty row is silent.
    private(set) var conversion: EdgeConversion

    fileprivate init(_ label: String, map: [[Int]]) {
        self.label = label
        conversion = EdgeConversion(map: map, label: label)
    }
}

/// The one feedback choice for a wire that closes a cycle. Built only by `WiringConnectionOffers`.
struct WiringFeedbackOffer: Hashable, Sendable {
    /// The fixed English label the picker shows.
    private(set) var label: String
    /// One render block of delay and a −6 dB loop gain ceiling.
    private(set) var feedback: EdgeFeedback

    fileprivate init(_ label: String, feedback: EdgeFeedback) {
        self.label = label
        self.feedback = feedback
    }
}

/// The conversion step's catalog. Pure: it reads only the counts or the class it is given.
enum WiringConnectionOffers {
    /// 1 → 2, in picker order.
    private static let monoToStereo = [
        WiringConversionOffer("Mono to both sides", map: [[0], [0]]),
        WiringConversionOffer("Left only", map: [[0], []]),
        WiringConversionOffer("Right only", map: [[], [0]])
    ]

    /// 2 → 1, in picker order. The sum is a plain sum: no gain compensation is applied or claimed.
    private static let stereoToMono = [
        WiringConversionOffer("Left only", map: [[0]]),
        WiringConversionOffer("Right only", map: [[1]]),
        WiringConversionOffer("Both sides summed", map: [[0, 1]])
    ]

    /// Labelled exactly as wiring.md "Connection validation" words it, with the same minus sign (U+2212).
    private static let feedbackOffer = WiringFeedbackOffer(
        "Feedback (1-block delay, ceiling −6 dB)", feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)
    )

    /// The named conversions from `sourceChannels` to `destinationChannels`, in picker order, none preselected.
    /// Refused, in this order: a count outside `GraphPort.channelRange` (`channelCountOutOfRange`), equal counts
    /// (`channelCountsMatch`), then any pair other than 1 → 2 and 2 → 1 (`unsupportedChannelCounts`).
    static func conversions(
        sourceChannels: Int, destinationChannels: Int
    ) throws(WiringConnectionOfferRefusal) -> [WiringConversionOffer] {
        guard GraphPort.channelRange.contains(sourceChannels), GraphPort.channelRange.contains(destinationChannels)
        else { throw .channelCountOutOfRange(source: sourceChannels, destination: destinationChannels) }
        guard sourceChannels != destinationChannels else { throw .channelCountsMatch(channels: sourceChannels) }
        switch (sourceChannels, destinationChannels) {
        case (1, 2): return monoToStereo
        case (2, 1): return stereoToMono
        default: throw .unsupportedChannelCounts(source: sourceChannels, destination: destinationChannels)
        }
    }

    /// The named conversions of a `needsConversion` pair (for example a `WiringDestinationList` candidate's
    /// `connection`), as `conversions(sourceChannels:destinationChannels:)` gives them. Any other class is
    /// refused with `conversionNotNeeded`.
    static func conversions(
        for connection: WiringConnection
    ) throws(WiringConnectionOfferRefusal) -> [WiringConversionOffer] {
        guard case .needsConversion(let source, let destination) = connection else {
            throw .conversionNotNeeded(WiringDestinationClass(connection))
        }
        return try conversions(sourceChannels: source, destinationChannels: destination)
    }

    /// The one feedback choice of a `feedbackOnly` wire, whatever its cycle. Any other class is refused with
    /// `feedbackNotNeeded`. A pair that needs a conversion and closes a cycle is `needsConversion` first: it is
    /// `feedbackOnly`, and offered feedback, once it is classified with the chosen conversion.
    static func feedback(for connection: WiringConnection) throws(WiringConnectionOfferRefusal) -> WiringFeedbackOffer {
        guard case .feedbackOnly = connection else { throw .feedbackNotNeeded(WiringDestinationClass(connection)) }
        return feedbackOffer
    }
}
