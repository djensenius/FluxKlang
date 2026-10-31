import Foundation

enum ParameterTag: ContractIDTag {}
typealias ParameterID = ContractID<ParameterTag>

enum ParameterUnit: String, Codable, Sendable {
    case decibels, normalized, percent, pan, index, boolean
}

enum ParameterCurve: String, Codable, Sendable { case faderTaper, linear, stepped }
enum ControlClass: String, Codable, Sendable, CaseIterable { case live, structural, hazardous, safety, proposal }

struct ParameterRampFields: ControlFields {
    enum Kind: String, Codable, Sendable { case step, linear }
    static let knownKeys: Set<String> = ["kind", "minimumMilliseconds", "maximumMilliseconds"]
    let kind: Kind
    let minimumMilliseconds: Int
    let maximumMilliseconds: Int

    func validate() throws {
        guard (0...60_000).contains(minimumMilliseconds),
              (minimumMilliseconds...60_000).contains(maximumMilliseconds),
              kind != .step || maximumMilliseconds == 0 else {
            throw ControlValidationError.invalid("Ramp duration must be bounded to 0...60000 ms; step is zero")
        }
    }
}
typealias ParameterRamp = ControlRecord<ParameterRampFields>

extension ControlRecord where Fields == ParameterRampFields {
    static var step: Self {
        // A fixed, validated catalog value; not an external-input path.
        do {
            return try Self(.init(kind: .step, minimumMilliseconds: 0, maximumMilliseconds: 0))
        } catch { preconditionFailure("Invalid built-in step ramp") }
    }
}

struct ParameterValue: Hashable, Sendable, Codable {
    let value: Double
    let unit: ParameterUnit
}

enum ParameterValueError: Error, Hashable, Sendable {
    case nonFinite
    case invalidDescriptor
    case invalidRamp
    case unitMismatch(expected: ParameterUnit, found: ParameterUnit)
    case notIntegral(Double)
    case outOfRange(Double, lower: Double, upper: Double)
    case aboveCeiling(Double, ceiling: Double)
}

struct ParameterFields: ControlFields {
    static let knownKeys: Set<String> = [
        "id", "node", "unit", "lower", "upper", "defaultValue", "ceiling", "curve", "ramp",
        "controlClass", "verification"
    ]
    let id: ParameterID
    var node: NodeID?
    let unit: ParameterUnit
    let lower: Double
    let upper: Double
    let defaultValue: Double
    let ceiling: Double?
    let curve: ParameterCurve
    let ramp: ParameterRamp
    let controlClass: ControlClass
    let verification: MeasurementStatus

    func validate() throws {
        guard lower.isFinite, upper.isFinite, lower <= upper, defaultValue.isFinite,
              ceiling.map({ $0.isFinite && $0 >= lower && $0 <= upper }) ?? true,
              (lower...upper).contains(defaultValue), defaultValue <= (ceiling ?? upper),
              [.live, .structural, .hazardous].contains(controlClass) else {
            throw ControlValidationError.invalid("Invalid parameter bounds, default, ceiling or class")
        }
        try validateUnit()
        guard curve != .stepped || (defaultValue.rounded() == defaultValue && ramp.kind == .step) else {
            throw ControlValidationError.invalid("Stepped parameters require integral defaults and step ramps")
        }
    }

    private func validateUnit() throws {
        switch unit {
        case .boolean:
            guard lower == 0, upper == 1, curve == .stepped else {
                throw ControlValidationError.invalid("Boolean parameter requires stepped 0...1")
            }
        case .normalized:
            guard lower >= 0, upper <= 1 else { throw ControlValidationError.invalid("Normalized bounds") }
        case .percent:
            guard lower >= 0, upper <= 100 else { throw ControlValidationError.invalid("Percent bounds") }
        case .index:
            guard curve == .stepped, lower.rounded() == lower, upper.rounded() == upper else {
                throw ControlValidationError.invalid("Index parameter requires integral stepped bounds")
            }
        default: break
        }
    }
}
typealias ParameterDescriptor = ControlRecord<ParameterFields>

extension ControlRecord where Fields == ParameterFields {
    func check(_ candidate: ParameterValue, ceiling extra: Double? = nil,
               rampMilliseconds: Int? = nil) throws(ParameterValueError) {
        guard candidate.value.isFinite, extra.map(\.isFinite) ?? true else { throw .nonFinite }
        guard candidate.unit == fields.unit else { throw .unitMismatch(expected: fields.unit, found: candidate.unit) }
        let value = candidate.value
        if fields.curve == .stepped, value.rounded() != value { throw .notIntegral(value) }
        guard (fields.lower...fields.upper).contains(value) else {
            throw .outOfRange(value, lower: fields.lower, upper: fields.upper)
        }
        let limit = min(fields.ceiling ?? fields.upper, extra ?? fields.upper)
        if value > limit { throw .aboveCeiling(value, ceiling: limit) }
        if let duration = rampMilliseconds,
           !(fields.ramp.minimumMilliseconds...fields.ramp.maximumMilliseconds).contains(duration) {
            throw .invalidRamp
        }
    }
}

struct ParameterCatalog: ControlPayload {
    static let contract = "fluxklang.parameters"
    let parameters: [ParameterDescriptor]
    var unknownFields: [String: JSONValue] = [:]

    init(_ parameters: [ParameterDescriptor]) throws {
        self.parameters = parameters
        try validate()
    }

    subscript(id: ParameterID) -> ParameterDescriptor? { parameters.first { $0.id == id } }

    func validate() throws {
        guard parameters.count <= 4096 else { throw ControlValidationError.invalid("Parameter catalog too large") }
        try ContractUniqueness.require(parameters.map(\.id))
        for descriptor in parameters { try descriptor.fields.validate() }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        try self.init(container.decode([ParameterDescriptor].self, forKey: DynamicCodingKey("parameters")))
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: ["parameters"])
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(parameters, forKey: DynamicCodingKey("parameters"))
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: ["parameters"])
    }

    static let wingFaderDecibels = ParameterID(validated: "wing.fader.db")
    static let wingMute = ParameterID(validated: "wing.mute")
    static let wingPan = ParameterID(validated: "wing.pan")
    static let wingColour = ParameterID(validated: "wing.colour")
    static let wingSendDecibels = ParameterID(validated: "wing.send.db")

    static var wing: ParameterCatalog {
        do {
            return try ParameterCatalog([
                wingParameter(wingFaderDecibels, unit: .decibels,
                              range: Double(FaderMath.minimumDecibels)...Double(FaderMath.maximumDecibels),
                              curve: .faderTaper, verification: .reported),
                wingParameter(wingMute, unit: .boolean, range: 0...1, curve: .stepped, verification: .reported),
                wingParameter(wingPan, unit: .pan, range: -100...100, curve: .linear, verification: .unverified),
                wingParameter(wingColour, unit: .index, range: 1...12, curve: .stepped, verification: .unverified),
                wingParameter(wingSendDecibels, unit: .decibels, range: -90...10,
                              curve: .faderTaper, verification: .unverified)
            ])
        } catch { preconditionFailure("Invalid built-in parameter catalog: \(error)") }
    }

    private static func wingParameter(
        _ id: ParameterID, unit: ParameterUnit, range: ClosedRange<Double>,
        curve: ParameterCurve, verification: MeasurementStatus
    ) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
            ceiling: nil, curve: curve, ramp: .step, controlClass: .live, verification: verification
        ))
    }
}
typealias ParameterCatalogDocument = ControlEnvelope<ParameterCatalog>
