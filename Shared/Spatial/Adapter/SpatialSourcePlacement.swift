//
//  SpatialSourcePlacement.swift
//  FluxKlang
//
//  A source placed in the neutral spatial plane (#114).
//

import Foundation

/// A source placed in the neutral plane. A stereo source (`channelCount == 2`)
/// spreads its channels horizontally around `position` by `width`.
struct SpatialSourcePlacement: Hashable, Sendable, Codable {
    /// Distance floor in neutral units (legacy `0.15` doubled).
    static let defaultBlur = 0.30
    /// Horizontal channel offset per unit of width (legacy `0.25` doubled).
    static let widthOffsetFactor = 0.5
    static let channelCounts: ClosedRange<Int> = 1...2

    let sourceID: SpatialSourceID
    let name: String?
    let position: NeutralPoint
    /// Positive, finite distance floor.
    let blur: Double
    /// Stereo spread in `0…1`.
    let width: Double
    let channelCount: Int
    /// Opaque legacy evidence, at most one per channel; never used to route.
    let evidence: [String]

    init(
        sourceID: SpatialSourceID,
        name: String? = nil,
        position: NeutralPoint,
        blur: Double = defaultBlur,
        width: Double = 0.5,
        channelCount: Int = 1,
        evidence: [String] = []
    ) throws(SpatialLayoutError) {
        guard blur.isFinite, blur > 0 else { throw .invalidBlur }
        guard width.isFinite, (0...1).contains(width) else { throw .invalidWidth }
        guard Self.channelCounts.contains(channelCount) else { throw .invalidChannelCount(channelCount) }
        guard evidence.count <= channelCount else { throw .tooMuchEvidence(evidence.count) }
        for item in evidence { try SpatialEvidence.validate(item) }
        self.sourceID = sourceID
        self.name = SpatialName.normalize(name)
        self.position = position
        self.blur = blur
        self.width = width
        self.channelCount = channelCount
        self.evidence = evidence
    }

    /// One point per channel: the position for mono; for stereo, left and right
    /// offset by `width × widthOffsetFactor` and clamped to the plane.
    ///
    /// Difference from legacy `channelPlacements()`: legacy clamped only the
    /// stereo x and passed y through, so a legacy y outside `0…1` stayed out of
    /// range. Here `position` (and so y) is always within `−1…1`; results match
    /// legacy exactly for in-range legacy positions.
    func channelPositions() -> [NeutralPoint] {
        guard channelCount == 2 else { return [position] }
        let offset = width * Self.widthOffsetFactor
        return [
            NeutralPoint(clampingFinite: position.x - offset, y: position.y),
            NeutralPoint(clampingFinite: position.x + offset, y: position.y)
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, name, position, blur, width, channelCount, evidence
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceID = try container.decode(SpatialSourceID.self, forKey: .sourceID)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let position = try container.decode(NeutralPoint.self, forKey: .position)
        let blur = try container.decode(Double.self, forKey: .blur)
        let width = try container.decode(Double.self, forKey: .width)
        let channelCount = try container.decode(Int.self, forKey: .channelCount)
        let evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        do {
            try self.init(sourceID: sourceID, name: name, position: position, blur: blur, width: width,
                          channelCount: channelCount, evidence: evidence)
        } catch {
            throw SpatialDecoding.corrupted(decoder, error)
        }
    }
}
