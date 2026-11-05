//
//  SpatialOutputMask.swift
//  FluxKlang
//
//  Post-law output masks (#115 M1): mute, solo and route loss. A mask only
//  ever removes energy; survivors are never boosted unless renormalisation is
//  explicitly enabled (and then only for mute/solo, capped).
//

import Foundation

/// How a speaker is masked by the user.
enum SpeakerMaskState: String, Codable, Sendable, CaseIterable {
    case muted
    /// While any speaker is soloed, every non-soloed speaker is masked.
    case soloed
}

/// One user mask on a layout speaker.
struct SpatialOutputMask: Hashable, Sendable, Codable {
    let speaker: SpeakerID
    let state: SpeakerMaskState
}

/// Why a speaker output is silent after the law.
enum SpeakerPass: Equatable, Sendable {
    case pass
    /// Muted, or not soloed while another speaker is. Takes precedence over `lost`.
    case masked
    /// Its route is missing on this host. Loss only zeroes; it never renormalises.
    case lost
}

/// A bounded, canonical set of user masks: a speaker may be both muted and
/// soloed (mute wins), but never carries the same state twice. Sorted by speaker
/// ID then state so permuted inputs compare equal.
struct SpatialMaskSet: Hashable, Sendable, Codable {
    /// One mute and one solo per speaker of a maximal layout.
    static let maximumMasks = 2 * SpatialLayout.maximumSpeakers
    static let none = Self(sorted: [], renormalizeSurvivors: false)

    let masks: [SpatialOutputMask]
    /// Opt-in: rescale survivors of a mute/solo toward unit power, capped at
    /// `SpatialRenderer.maximumRenormalizationBoost`. Off by default.
    let renormalizeSurvivors: Bool

    init(masks: [SpatialOutputMask] = [], renormalizeSurvivors: Bool = false) throws(SpatialRenderError) {
        guard masks.count <= Self.maximumMasks else { throw .tooManyMasks(masks.count) }
        var seen = Set<SpatialOutputMask>()
        for mask in masks where !seen.insert(mask).inserted {
            throw .duplicateMask(mask.speaker)
        }
        let sorted = masks.sorted {
            $0.speaker == $1.speaker ? $0.state.rawValue < $1.state.rawValue : $0.speaker < $1.speaker
        }
        self.init(sorted: sorted, renormalizeSurvivors: renormalizeSurvivors)
    }

    private init(sorted: [SpatialOutputMask], renormalizeSurvivors: Bool) {
        self.masks = sorted
        self.renormalizeSurvivors = renormalizeSurvivors
    }

    /// Refuses a mask naming a speaker that is not in `layout`.
    func validate(against layout: SpatialLayout) throws(SpatialRenderError) {
        let known = Set(layout.speakers.map(\.id))
        for mask in masks where !known.contains(mask.speaker) {
            throw .unknownMaskSpeaker(mask.speaker)
        }
    }

    /// The pass state of every speaker, aligned with `layout.speakers`. Mute wins
    /// over solo; if every soloed speaker is also muted the result is silence
    /// (no fallback to unsoloed speakers). With `availableRoutes == nil` route
    /// loss is not evaluated; otherwise a speaker whose route is unmapped or not
    /// available is `lost` (unless already masked).
    func passes(layout: SpatialLayout, availableRoutes: Set<RouteID>?) -> [SpeakerPass] {
        let muted = Set(masks.filter { $0.state == .muted }.map(\.speaker))
        let soloed = Set(masks.filter { $0.state == .soloed }.map(\.speaker))
        return layout.speakers.map { speaker -> SpeakerPass in
            if muted.contains(speaker.id) || (!soloed.isEmpty && !soloed.contains(speaker.id)) { return .masked }
            if let availableRoutes, layout.route(for: speaker.id, available: availableRoutes) == nil {
                return .lost
            }
            return .pass
        }
    }

    private enum CodingKeys: String, CodingKey { case masks, renormalizeSurvivors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let masks = try container.decodeIfPresent([SpatialOutputMask].self, forKey: .masks) ?? []
        let renormalize = try container.decodeIfPresent(Bool.self, forKey: .renormalizeSurvivors) ?? false
        do {
            try self.init(masks: masks, renormalizeSurvivors: renormalize)
        } catch {
            throw SpatialRenderDecoding.corrupted(decoder, error)
        }
    }
}
