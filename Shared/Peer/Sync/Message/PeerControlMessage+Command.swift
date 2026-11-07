//
//  PeerControlMessage+Command.swift
//  FluxKlang
//
//  The command intent and command result sections of the control codec (#95,
//  slice S2).
//
//      intent    = id commandClass:u8 origin:u8 hostEpoch:(id u64) connection revs operation permission
//      connection = 0 | 1 id u64             (its host is the intent's host epoch host)
//      operation = 1 set id value | 2 ramp id value milliseconds:u32 | 3 bind id | 4 recall id
//                | 5 trigger id | 6 start | 7 stop | 8 locate ticks:u64 | 9 panic | 10 safeMute
//                | 11 propose id | 12 editDraft id
//      permission = length:u16 (1...256) utf8 bytes
//      outcome   = 1 admitted | 2 inFlight | 3 replayed completion | 4 refused refusal
//      completion = 1 applied revs | 2 refused commandResult
//      refusal   = 1 command commandResult | 2 sessionRetired stale | 3 outOfSequence expected:u64 found:u64
//                | 4 sessionFailed | 5 conflictingReuse | 6 ledgerFull capacity:u32
//      commandResult = 1 applied | 2 rejected rejection | 3 stale stale      (4 is reserved for trigger)
//      stale     = 1 connectionEpoch | 2 hostEpoch | 3 generation kind:u8 id
//      rejection = 1 permissionDenied | 2 permissionChanged | 3 staleRevision expected:u64 found:u64
//                | 4 unknownParameter id | 5 missingValue | 6 invalidValue valueError | 7 scopeDenied
//                | 8 classMismatch | 9 unsupportedOperation | 10 revisionChanged
//      valueError = 1 nonFinite | 2 invalidDescriptor | 3 invalidRamp | 4 unitMismatch expected:u8 found:u8
//                | 5 notIntegral double | 6 outOfRange double lower upper | 7 aboveCeiling double ceiling
//
//  An intent with unknown fields and a trigger outcome are not encodable here.
//

import Foundation

extension PeerControlMessage {
    // MARK: Command

    static func writeCommand(
        _ envelope: PeerCommandEnvelope,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        let intent = envelope.intent
        guard intent.unknownFields.isEmpty else { throw .unencodable(.unknownFields) }
        writeSequence(envelope.sequence, into: &writer)
        try writeID(intent.id, into: &writer)
        writer.append(intent.commandClass.wireCode)
        writer.append(intent.origin.wireCode)
        try writeID(intent.hostEpoch.host, into: &writer)
        writeGeneration(intent.hostEpoch.generation, into: &writer)
        if let connection = intent.connectionEpoch {
            writer.append(UInt8(1))
            try writeID(connection.connection, into: &writer)
            writeGeneration(connection.generation, into: &writer)
        } else {
            writer.append(UInt8(0))
        }
        writeRevisions(intent.revisions, into: &writer)
        try writeOperation(intent.operation, into: &writer)
        try writeText(intent.permission.rawValue, bounds: PermissionFingerprint.utf8Bounds, wide: true,
                      into: &writer)
    }

    static func readCommand(_ cursor: inout PeerControlCursor) throws(PeerControlMessageError) -> PeerCommandEnvelope {
        let sequence = try cursor.readSequence()
        let intentStart = cursor.offset
        let id = try cursor.readID(CommandID.self)
        let commandClass = try cursor.readCoded(ControlClass.self)
        let origin = try cursor.readCoded(CommandOrigin.self)
        let host = try cursor.readID(HostID.self)
        let hostEpoch = HostEpoch(host: host, generation: try cursor.readGeneration())
        let connectionEpoch = try readConnectionEpoch(&cursor, host: host)
        let revisions = try cursor.readRevisions()
        let operation = try readOperation(&cursor)
        let permission = try cursor.readFingerprint()
        let fields = CommandIntentFields(id: id, commandClass: commandClass, origin: origin, hostEpoch: hostEpoch,
                                         connectionEpoch: connectionEpoch, revisions: revisions,
                                         operation: operation, permission: permission)
        do {
            return PeerCommandEnvelope(sequence: sequence, intent: try CommandIntent(fields))
        } catch {
            throw .malformed(offset: intentStart)
        }
    }

    private static func readConnectionEpoch(
        _ cursor: inout PeerControlCursor,
        host: HostID
    ) throws(PeerControlMessageError) -> ConnectionEpoch? {
        let start = cursor.offset
        switch try cursor.readUInt8() {
        case 0: return nil
        case 1:
            let connection = try cursor.readID(ConnectionID.self)
            return ConnectionEpoch(connection: connection, host: host, generation: try cursor.readGeneration())
        default: throw .malformed(offset: start)
        }
    }

    private static func writeOperation(
        _ operation: CommandOperation,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        writer.append(operation.wireCode)
        switch operation {
        case .set(let id, let value):
            try writeID(id, into: &writer)
            try writeValue(value, into: &writer)
        case .ramp(let id, let value, let milliseconds):
            try writeID(id, into: &writer)
            try writeValue(value, into: &writer)
            writer.append(try wireUInt32(milliseconds))
        case .bind(let id): try writeID(id, into: &writer)
        case .recall(let id): try writeID(id, into: &writer)
        case .trigger(let id): try writeID(id, into: &writer)
        case .propose(let id), .editDraft(let id): try writeID(id, into: &writer)
        case .locate(let ticks): writer.append(UInt64(bitPattern: ticks))
        case .start, .stop, .panic, .safeMute: break
        }
    }

    private static let bareOperations: [CommandOperation] = [.start, .stop, .panic, .safeMute]

    private static func readOperation(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> CommandOperation {
        let start = cursor.offset
        let code = try cursor.readUInt8()
        switch code {
        case 1, 2:
            let id = try cursor.readID(ParameterID.self)
            let value = try cursor.readValue()
            guard code == 2 else { return .set(id, value) }
            return .ramp(id, value, milliseconds: Int(try cursor.readUInt32()))
        case 3, 4, 5, 11, 12: return try readIdentifiedOperation(&cursor, code: code)
        case 8: return .locate(ticks: Int64(bitPattern: try cursor.readUInt64()))
        default:
            guard let bare = bareOperations.first(where: { $0.wireCode == code }) else {
                throw .malformed(offset: start)
            }
            return bare
        }
    }

    private static func readIdentifiedOperation(
        _ cursor: inout PeerControlCursor,
        code: UInt8
    ) throws(PeerControlMessageError) -> CommandOperation {
        switch code {
        case 3: return .bind(try cursor.readID(RouteID.self))
        case 4: return .recall(try cursor.readID(PatchID.self))
        case 5: return .trigger(try cursor.readID(ActionID.self))
        case 11: return .propose(try cursor.readID(DraftID.self))
        default: return .editDraft(try cursor.readID(DraftID.self))
        }
    }

    // MARK: Result

    static func writeResult(
        _ result: PeerCommandResult,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        writeSequence(result.sequence, into: &writer)
        try writeID(result.command, into: &writer)
        switch result.outcome {
        case .admitted: writer.append(UInt8(1))
        case .inFlight: writer.append(UInt8(2))
        case .replayed(let completion):
            writer.append(UInt8(3))
            switch completion {
            case .applied(let revisions):
                writer.append(UInt8(1))
                writeRevisions(revisions, into: &writer)
            case .refused(let commandResult):
                writer.append(UInt8(2))
                try writeCommandResult(commandResult, into: &writer)
            }
        case .refused(let refusal):
            writer.append(UInt8(4))
            try writeRefusal(refusal, into: &writer)
        }
    }

    static func readResult(_ cursor: inout PeerControlCursor) throws(PeerControlMessageError) -> PeerCommandResult {
        let sequence = try cursor.readSequence()
        let command = try cursor.readID(CommandID.self)
        let start = cursor.offset
        let outcome: PeerCommandOutcome
        switch try cursor.readUInt8() {
        case 1: outcome = .admitted
        case 2: outcome = .inFlight
        case 3: outcome = .replayed(try readCompletion(&cursor))
        case 4: outcome = .refused(try readRefusal(&cursor))
        default: throw .malformed(offset: start)
        }
        return PeerCommandResult(sequence: sequence, command: command, outcome: outcome)
    }

    private static func readCompletion(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> PeerCommandCompletion {
        let start = cursor.offset
        switch try cursor.readUInt8() {
        case 1: return .applied(revisions: try cursor.readRevisions())
        case 2: return .refused(try readCommandResult(&cursor))
        default: throw .malformed(offset: start)
        }
    }

    private static func writeRefusal(
        _ refusal: PeerCommandRefusal,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        switch refusal {
        case .command(let result):
            writer.append(UInt8(1))
            try writeCommandResult(result, into: &writer)
        case .sessionRetired(let dependency):
            writer.append(UInt8(2))
            try writeStale(dependency, into: &writer)
        case .outOfSequence(let expected, let found):
            writer.append(UInt8(3))
            writeSequence(expected, into: &writer)
            writeSequence(found, into: &writer)
        case .sessionFailed: writer.append(UInt8(4))
        case .conflictingReuse: writer.append(UInt8(5))
        case .ledgerFull(let capacity):
            writer.append(UInt8(6))
            writer.append(try wireUInt32(capacity))
        }
    }

    private static func readRefusal(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> PeerCommandRefusal {
        let start = cursor.offset
        switch try cursor.readUInt8() {
        case 1: return .command(try readCommandResult(&cursor))
        case 2: return .sessionRetired(try readStale(&cursor))
        case 3: return .outOfSequence(expected: try cursor.readSequence(), found: try cursor.readSequence())
        case 4: return .sessionFailed
        case 5: return .conflictingReuse
        case 6: return .ledgerFull(capacity: Int(try cursor.readUInt32()))
        default: throw .malformed(offset: start)
        }
    }

    private static func writeCommandResult(
        _ result: CommandResult,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        switch result {
        case .applied: writer.append(UInt8(1))
        case .rejected(let rejection):
            writer.append(UInt8(2))
            try writeRejection(rejection, into: &writer)
        case .stale(let dependency):
            writer.append(UInt8(3))
            try writeStale(dependency, into: &writer)
        case .trigger: throw .unencodable(.trigger)
        }
    }

    private static func readCommandResult(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> CommandResult {
        let start = cursor.offset
        switch try cursor.readUInt8() {
        case 1: return .applied
        case 2: return .rejected(try readRejection(&cursor))
        case 3: return .stale(try readStale(&cursor))
        default: throw .malformed(offset: start)
        }
    }

    private static func writeStale(
        _ dependency: StaleDependency,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        switch dependency {
        case .connectionEpoch: writer.append(UInt8(1))
        case .hostEpoch: writer.append(UInt8(2))
        case .generation(let key):
            writer.append(UInt8(3))
            writer.append(key.kind.wireCode)
            try writeID(key.subject, into: &writer)
        }
    }

    private static func readStale(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> StaleDependency {
        let start = cursor.offset
        switch try cursor.readUInt8() {
        case 1: return .connectionEpoch
        case 2: return .hostEpoch
        case 3:
            let kind = try cursor.readCoded(GenerationKind.self)
            return .generation(GenerationKey(kind: kind, subject: try cursor.readID(GenerationSubject.self)))
        default: throw .malformed(offset: start)
        }
    }

    // MARK: Rejection

    private static let bareRejections: [CommandRejection] = [
        .permissionDenied, .permissionChanged, .missingValue, .scopeDenied, .classMismatch,
        .unsupportedOperation, .revisionChanged
    ]

    private static func writeRejection(
        _ rejection: CommandRejection,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        writer.append(rejection.wireCode)
        switch rejection {
        case .staleRevision(let expected, let found):
            writer.append(UInt64(expected.value))
            writer.append(UInt64(found.value))
        case .unknownParameter(let id): try writeID(id, into: &writer)
        case .invalidValue(let error): try writeValueError(error, into: &writer)
        default: break
        }
    }

    private static func readRejection(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> CommandRejection {
        let start = cursor.offset
        let code = try cursor.readUInt8()
        switch code {
        case 3: return .staleRevision(expected: try cursor.readRevision(), found: try cursor.readRevision())
        case 4: return .unknownParameter(try cursor.readID(ParameterID.self))
        case 6: return .invalidValue(try readValueError(&cursor))
        default:
            guard let bare = bareRejections.first(where: { $0.wireCode == code }) else {
                throw .malformed(offset: start)
            }
            return bare
        }
    }

    private static let bareValueErrors: [ParameterValueError] = [.nonFinite, .invalidDescriptor, .invalidRamp]

    private static func writeValueError(
        _ error: ParameterValueError,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        writer.append(error.wireCode)
        switch error {
        case .unitMismatch(let expected, let found):
            writer.append(expected.wireCode)
            writer.append(found.wireCode)
        case .notIntegral(let value): try writeDouble(value, into: &writer)
        case .outOfRange(let value, let lower, let upper):
            try writeDouble(value, into: &writer)
            try writeDouble(lower, into: &writer)
            try writeDouble(upper, into: &writer)
        case .aboveCeiling(let value, let ceiling):
            try writeDouble(value, into: &writer)
            try writeDouble(ceiling, into: &writer)
        default: break
        }
    }

    private static func readValueError(
        _ cursor: inout PeerControlCursor
    ) throws(PeerControlMessageError) -> ParameterValueError {
        let start = cursor.offset
        let code = try cursor.readUInt8()
        switch code {
        case 4:
            return .unitMismatch(expected: try cursor.readCoded(ParameterUnit.self),
                                 found: try cursor.readCoded(ParameterUnit.self))
        case 5: return .notIntegral(try cursor.readDouble())
        case 6:
            return .outOfRange(try cursor.readDouble(), lower: try cursor.readDouble(),
                               upper: try cursor.readDouble())
        case 7: return .aboveCeiling(try cursor.readDouble(), ceiling: try cursor.readDouble())
        default:
            guard let bare = bareValueErrors.first(where: { $0.wireCode == code }) else {
                throw .malformed(offset: start)
            }
            return bare
        }
    }

    private static func wireUInt32(_ value: Int) throws(PeerControlMessageError) -> UInt32 {
        guard let wire = UInt32(exactly: value) else { throw .unencodable(.integerOutOfRange(value)) }
        return wire
    }
}

extension CommandOperation {
    fileprivate var wireCode: UInt8 {
        switch self {
        case .set: 1
        case .ramp: 2
        case .bind: 3
        case .recall: 4
        case .trigger: 5
        case .start: 6
        case .stop: 7
        case .locate: 8
        case .panic: 9
        case .safeMute: 10
        case .propose: 11
        case .editDraft: 12
        }
    }
}

extension CommandRejection {
    fileprivate var wireCode: UInt8 {
        switch self {
        case .permissionDenied: 1
        case .permissionChanged: 2
        case .staleRevision: 3
        case .unknownParameter: 4
        case .missingValue: 5
        case .invalidValue: 6
        case .scopeDenied: 7
        case .classMismatch: 8
        case .unsupportedOperation: 9
        case .revisionChanged: 10
        }
    }
}

extension ParameterValueError {
    fileprivate var wireCode: UInt8 {
        switch self {
        case .nonFinite: 1
        case .invalidDescriptor: 2
        case .invalidRamp: 3
        case .unitMismatch: 4
        case .notIntegral: 5
        case .outOfRange: 6
        case .aboveCeiling: 7
        }
    }
}
