import Foundation

enum ActionTag: ContractIDTag {}
typealias ActionID = ContractID<ActionTag>
enum ActionMedia: String, Codable, Hashable, Sendable { case audio, midi, state, transport }
enum MediaTimePolicy: String, Codable, Hashable, Sendable { case fixedRate, timeStretch, tempoFollowing }

enum LatePolicy: Hashable, Sendable, Codable, BitwiseCopyable {
    case drop
    case fireLate(maxLatenessMs: Int)
    case joinInProgress(maxLatenessMs: Int)
    case nextBoundary(gridTicks: Int64?)

    var maxLatenessMs: Int? {
        switch self {
        case .fireLate(let value), .joinInProgress(let value): value
        case .drop, .nextBoundary: nil
        }
    }
}

enum StoppedPolicy: String, Codable, Sendable, BitwiseCopyable { case wait, immediate, startTransport }

/// Portable policy only; never proof that an action is loaded, authorized or active.
struct ActionPolicy: Hashable, Sendable, Codable {
    let media: ActionMedia
    let timePolicy: MediaTimePolicy?
    let latePolicy: LatePolicy
    let gridTicks: Int64?
    let retroactiveMs: Int
    let stoppedPolicy: StoppedPolicy
    var unknownFields: [String: JSONValue] = [:]
    var extensions: [String: JSONValue]?
    private var latePolicyUnknownFields: [String: JSONValue] = [:]
    var hasUnknownFields: Bool { !unknownFields.isEmpty || !latePolicyUnknownFields.isEmpty }

    init(media: ActionMedia, timePolicy: MediaTimePolicy?, latePolicy: LatePolicy,
         gridTicks: Int64? = nil, retroactiveMs: Int = 0, stoppedPolicy: StoppedPolicy = .wait) throws {
        self.media = media
        self.timePolicy = timePolicy
        self.latePolicy = latePolicy
        self.gridTicks = gridTicks
        self.retroactiveMs = retroactiveMs
        self.stoppedPolicy = stoppedPolicy
        try validate()
    }

    func validate() throws {
        let allowed: Bool
        switch media {
        case .audio: allowed = timePolicy == .fixedRate || timePolicy == .timeStretch
        case .midi: allowed = timePolicy == .fixedRate || timePolicy == .tempoFollowing
        case .state, .transport: allowed = timePolicy == nil
        }
        guard allowed, gridTicks.map({ $0 > 0 }) ?? true,
              latePolicy.maxLatenessMs.map({ (0...1_000).contains($0) }) ?? true,
              (0...120).contains(retroactiveMs),
              retroactiveMs == 0 || retroactiveMs <= (latePolicy.maxLatenessMs ?? -1) else {
            throw ControlValidationError.invalid("Unsupported media timing policy")
        }
        if case .nextBoundary(let policyGrid) = latePolicy {
            guard let grid = policyGrid ?? gridTicks, grid > 0 else {
                throw ControlValidationError.invalid("nextBoundary requires a bounded positive grid")
            }
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case media, timePolicy, latePolicy, gridTicks, retroactiveMs, stoppedPolicy, extensions
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(media: fields.decode(ActionMedia.self, forKey: .media),
                      timePolicy: fields.decodeIfPresent(MediaTimePolicy.self, forKey: .timePolicy),
                      latePolicy: fields.decode(LatePolicy.self, forKey: .latePolicy),
                      gridTicks: fields.decodeIfPresent(Int64.self, forKey: .gridTicks),
                      retroactiveMs: fields.decode(Int.self, forKey: .retroactiveMs),
                      stoppedPolicy: fields.decode(StoppedPolicy.self, forKey: .stoppedPolicy))
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
        extensions = try fields.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        latePolicyUnknownFields = try ControlJSON.unknown(
            in: fields.decode(JSONValue.self, forKey: .latePolicy), comparedTo: ControlJSON.value(latePolicy)
        )
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(media, forKey: .media)
        try fields.encodeIfPresent(timePolicy, forKey: .timePolicy)
        try fields.encode(ControlJSON.merging(ControlJSON.value(latePolicy), unknown: latePolicyUnknownFields),
                          forKey: .latePolicy)
        try fields.encodeIfPresent(gridTicks, forKey: .gridTicks)
        try fields.encode(retroactiveMs, forKey: .retroactiveMs)
        try fields.encode(stoppedPolicy, forKey: .stoppedPolicy)
        try fields.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
