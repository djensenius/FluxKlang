import Foundation

enum CommandScope: Hashable, Sendable, Codable {
    case parameter(ParameterID), route(RouteID), patch(PatchID), action(ActionID), draft(DraftID)
    case transport, safety
}

enum CommandOperation: Hashable, Sendable, Codable {
    /// Absolute setters use the descriptor's minimum ramp; explicit ramps choose a validated duration.
    case set(ParameterID, ParameterValue)
    case ramp(ParameterID, ParameterValue, milliseconds: Int)
    case bind(RouteID)
    case recall(PatchID)
    case trigger(ActionID)
    case start, stop, locate(ticks: Int64)
    case panic, safeMute
    case propose(DraftID), editDraft(DraftID)

    var scope: CommandScope {
        switch self {
        case .set(let id, _), .ramp(let id, _, _): .parameter(id)
        case .bind(let id): .route(id)
        case .recall(let id): .patch(id)
        case .trigger(let id): .action(id)
        case .propose(let id), .editDraft(let id): .draft(id)
        case .start, .stop, .locate: .transport
        case .panic, .safeMute: .safety
        }
    }

    var controlClass: ControlClass? {
        switch self {
        case .set, .ramp: nil
        case .bind, .recall, .editDraft: .structural
        case .propose: .proposal
        case .panic, .safeMute: .safety
        case .trigger, .start, .stop, .locate: .live
        }
    }
}

struct CommandRevisions: Hashable, Sendable, Codable {
    var patch: ContractRevision = .initial
    var capability: ContractRevision = .initial
    var permission: ContractRevision = .initial
    var parameter: ContractRevision = .initial
    var graph: ContractRevision = .initial
}

struct CommandIntentFields: ControlFields {
    static let knownKeys: Set<String> = [
        "id", "commandClass", "origin", "hostEpoch", "connectionEpoch", "revisions", "operation", "permission"
    ]
    let id: CommandID
    let commandClass: CommandClass
    let origin: CommandOrigin
    let hostEpoch: HostEpoch
    let connectionEpoch: ConnectionEpoch?
    let revisions: CommandRevisions
    let operation: CommandOperation
    let permission: PermissionFingerprint

    func validate() throws {
        guard connectionEpoch.map({ $0.host == hostEpoch.host }) ?? true, permission.isWellFormed else {
            throw ControlValidationError.invalid("Command connection or permission identity is invalid")
        }
        switch operation {
        case .set(_, let value), .ramp(_, let value, _):
            guard value.value.isFinite else { throw ParameterValueError.nonFinite }
        case .locate(let ticks):
            guard ticks >= 0 else { throw ControlValidationError.invalid("Command locate ticks must be nonnegative") }
        default: break
        }
        if case .ramp(_, _, let duration) = operation, !(0...60_000).contains(duration) {
            throw ParameterValueError.invalidRamp
        }
    }
}
typealias CommandIntent = ControlRecord<CommandIntentFields>

struct CommandPayload: ControlPayload {
    static let contract = "fluxklang.commands"
    let intent: CommandIntent
    var unknownFields: [String: JSONValue] = [:]

    init(intent: CommandIntent) { self.intent = intent }
    func validate() throws { try intent.fields.validate() }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: DynamicCodingKey.self)
        intent = try fields.decode(CommandIntent.self, forKey: DynamicCodingKey("intent"))
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: ["intent"])
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: DynamicCodingKey.self)
        try fields.encode(intent, forKey: DynamicCodingKey("intent"))
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: ["intent"])
    }
}
typealias CommandDocument = ControlEnvelope<CommandPayload>

struct AdmissionContext: Sendable {
    let hostEpoch: HostEpoch
    let connectionEpoch: ConnectionEpoch?
    let revisions: CommandRevisions
    let permission: PermissionFingerprint?
    let allowedScopes: Set<CommandScope>
    let allowedClasses: Set<CommandClass>
    let catalog: ParameterCatalog
    var ceiling: Double?
}

enum AdmissionDecision: Hashable, Sendable {
    /// Validated intent only: does not grant activation, an engine lease or perform a write.
    case admitted
    case refused(CommandResult)
}

enum CommandAdmission {
    static func admit(_ intent: CommandIntent, in context: AdmissionContext) -> AdmissionDecision {
        guard intent.hostEpoch == context.hostEpoch else { return .refused(.stale(.hostEpoch)) }
        guard intent.connectionEpoch == context.connectionEpoch else { return .refused(.stale(.connectionEpoch)) }
        guard let permission = context.permission, permission.isWellFormed else {
            return .refused(.rejected(.permissionDenied))
        }
        guard permission == intent.permission else { return .refused(.rejected(.permissionChanged)) }
        guard intent.revisions == context.revisions else { return .refused(.rejected(.revisionChanged)) }
        guard context.allowedScopes.contains(intent.operation.scope) else { return .refused(.rejected(.scopeDenied)) }
        guard context.allowedClasses.contains(intent.commandClass),
              intent.origin != .assistant || intent.commandClass == .proposal else {
            return .refused(.rejected(.permissionDenied))
        }
        if let required = intent.operation.controlClass {
            return required == intent.commandClass ? .admitted : .refused(.rejected(.classMismatch))
        }
        return validateParameter(intent, context: context)
    }

    private static func validateParameter(_ intent: CommandIntent, context: AdmissionContext) -> AdmissionDecision {
        let parameter: ParameterID
        let value: ParameterValue
        let duration: Int?
        switch intent.operation {
        case .set(let id, let candidate): (parameter, value, duration) = (id, candidate, nil)
        case .ramp(let id, let candidate, let milliseconds):
            (parameter, value, duration) = (id, candidate, milliseconds)
        default: return .refused(.rejected(.unsupportedOperation))
        }
        guard let descriptor = context.catalog[parameter] else {
            return .refused(.rejected(.unknownParameter(parameter)))
        }
        guard descriptor.controlClass == intent.commandClass else { return .refused(.rejected(.classMismatch)) }
        do {
            try descriptor.check(value, ceiling: context.ceiling, rampMilliseconds: duration)
        } catch { return .refused(.rejected(.invalidValue(error))) }
        return .admitted
    }
}
