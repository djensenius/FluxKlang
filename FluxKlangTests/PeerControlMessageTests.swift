import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The control message codec (#95, slice S2): golden bytes, hostile bytes, round trips and the command sections.
#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct PeerControlMessageTests {
    typealias Outcome<Value> = Result<Value, PeerControlMessageError>

    enum Fixture {
        static let host = HostID(validated: "h")
        static let connection = ConnectionID(validated: "c")
        static let standard = PeerSyncLimits.standard
        static let wide = frameLimits(1 << 20)

        static func frameLimits(_ bytes: Int) -> PeerFrameLimits {
            guard let limits = PeerFrameLimits(maximumPayloadBytes: bytes) else {
                preconditionFailure("invalid frame limits \(bytes)")
            }
            return limits
        }

        static func syncLimits(snapshot: Int, delta: Int) -> PeerSyncLimits {
            guard let limits = PeerSyncLimits(maximumSnapshotValues: snapshot, maximumDeltaChanges: delta) else {
                preconditionFailure("invalid sync limits \(snapshot) \(delta)")
            }
            return limits
        }

        static func gen(_ value: Int) -> Generation {
            do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
        }

        static func seq(_ value: Int) -> PeerSequence {
            do { return try PeerSequence(value) } catch { preconditionFailure("invalid sequence \(value)") }
        }

        static func rev(_ value: Int) -> ContractRevision {
            do { return try ContractRevision(value) } catch { preconditionFailure("invalid revision \(value)") }
        }

        static let revisions = CommandRevisions(patch: rev(1), capability: rev(2), permission: rev(3),
                                                parameter: rev(4), graph: rev(5))

        static func session(host hostGeneration: Int = 1, connection connectionGeneration: Int = 2,
                            hostID: HostID = host, connectionID: ConnectionID = connection) -> PeerSyncSession {
            let hostEpoch = HostEpoch(host: hostID, generation: gen(hostGeneration))
            let connectionEpoch = ConnectionEpoch(connection: connectionID, host: hostID,
                                                  generation: gen(connectionGeneration))
            guard let session = PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: connectionEpoch) else {
                preconditionFailure("session hosts differ")
            }
            return session
        }

        static func ident<Tag: ContractIDTag>(_ raw: String, _ type: ContractID<Tag>.Type = ContractID<Tag>.self)
            -> ContractID<Tag> {
            guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("invalid id \(raw)") }
            return id
        }

        static func pid(_ raw: String) -> ParameterID { ident(raw) }
        static func cid(_ raw: String) -> CommandID { ident(raw) }

        static func generationKey(_ kind: GenerationKind, _ raw: String) -> GenerationKey {
            guard let subject = GenerationSubject(rawValue: raw) else { preconditionFailure("invalid subject \(raw)") }
            return GenerationKey(kind: kind, subject: subject)
        }

        static func value(_ number: Double, _ unit: ParameterUnit = .normalized) -> ParameterValue {
            ParameterValue(value: number, unit: unit)
        }

        static func snapshot(
            _ values: [ParameterID: ParameterValue], sequence: Int = 5, session: PeerSyncSession = session()
        ) -> PeerControlMessage {
            .snapshot(PeerSyncSnapshot(session: session, sequence: seq(sequence), revisions: revisions,
                                       values: values))
        }

        static func delta(
            updates: [ParameterID: ParameterValue] = [:], removals: Set<ParameterID> = [],
            sequence: Int = 6, session: PeerSyncSession = session()
        ) -> PeerControlMessage {
            .delta(PeerSyncDelta(session: session, sequence: seq(sequence), revisions: revisions,
                                 updates: updates, removals: removals))
        }

        static func resync(_ reason: PeerResyncWireReason, lastApplied: Int = 4) -> PeerControlMessage {
            .resync(PeerResyncWireRequest(session: session(), lastApplied: seq(lastApplied), reason: reason))
        }

        static func intent(
            operation: CommandOperation = .set(pid("p"), value(0.25)),
            commandClass: CommandClass = .live, origin: CommandOrigin = .controller,
            connection: Bool = true, permission: String = "perm", unknownFields: [String: JSONValue] = [:]
        ) -> CommandIntent {
            let hostEpoch = HostEpoch(host: host, generation: gen(1))
            let connectionEpoch = connection
                ? ConnectionEpoch(connection: Self.connection, host: host, generation: gen(2)) : nil
            let fields = CommandIntentFields(
                id: cid("cmd"), commandClass: commandClass, origin: origin, hostEpoch: hostEpoch,
                connectionEpoch: connectionEpoch, revisions: revisions, operation: operation,
                permission: PermissionFingerprint(rawValue: permission))
            do { return try CommandIntent(fields, unknownFields: unknownFields) } catch {
                preconditionFailure("invalid intent \(error)")
            }
        }

        static func command(_ intent: CommandIntent = intent(), sequence: Int = 1) -> PeerControlMessage {
            .command(PeerCommandEnvelope(sequence: seq(sequence), intent: intent))
        }

        static func result(_ outcome: PeerCommandOutcome, sequence: Int = 1) -> PeerControlMessage {
            .result(PeerCommandResult(sequence: seq(sequence), command: cid("cmd"), outcome: outcome))
        }

        static func encode(
            _ message: PeerControlMessage, limits: PeerSyncLimits = standard, frame: PeerFrameLimits = wide
        ) -> Outcome<[UInt8]> {
            do { return .success(try PeerControlMessage.encode(message, limits: limits, frameLimits: frame)) } catch {
                return .failure(error)
            }
        }

        static func decode(
            _ bytes: [UInt8], session: PeerSyncSession = session(), limits: PeerSyncLimits = standard,
            frame: PeerFrameLimits = wide
        ) -> Outcome<PeerControlMessage> {
            do {
                return .success(try PeerControlMessage.decode(bytes, expecting: session, limits: limits,
                                                              frameLimits: frame))
            } catch { return .failure(error) }
        }

        /// The bytes of `message`, or an empty array when it does not encode (the caller asserts on the round trip).
        static func bytes(_ message: PeerControlMessage, limits: PeerSyncLimits = standard) -> [UInt8] {
            (try? encode(message, limits: limits).get()) ?? []
        }

        /// One byte of the encoding of `message`, or nil when it does not encode or is too short.
        static func byte(_ message: PeerControlMessage, at index: Int) -> UInt8? {
            let encoded = bytes(message)
            return encoded.indices.contains(index) ? encoded[index] : nil
        }

        // MARK: Independent byte builders (they do not use the production writer)
        static func big(_ value: UInt64, _ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (count - 1 - $0))) }
        }

        static func u64(_ value: UInt64) -> [UInt8] { big(value, 8) }
        static func u32(_ value: UInt64) -> [UInt8] { big(value, 4) }
        static func idBytes(_ raw: String) -> [UInt8] { [UInt8(raw.utf8.count)] + Array(raw.utf8) }
        static func valueBytes(_ number: Double, _ unit: UInt8 = 2) -> [UInt8] { u64(number.bitPattern) + [unit] }

        static func entry(_ raw: String, _ number: Double = 0.5) -> [UInt8] { idBytes(raw) + valueBytes(number) }

        static let sessionBytes = idBytes("h") + u64(1) + idBytes("c") + u64(2)
        static let revisionBytes = [1, 2, 3, 4, 5].flatMap { u64(UInt64($0)) }

        /// A snapshot head up to and including the count, for hand-built hostile payloads.
        static func snapshotHead(
            count: UInt64, sequence: UInt64 = 5, session: [UInt8] = sessionBytes, revisions: [UInt8] = revisionBytes
        ) -> [UInt8] {
            [1] + session + u64(sequence) + revisions + u32(count)
        }

        static func deltaHead(
            updates: UInt64, removals: UInt64, sequence: UInt64 = 6, session: [UInt8] = sessionBytes
        ) -> [UInt8] {
            [2] + session + u64(sequence) + revisionBytes + u32(updates) + u32(removals)
        }
    }
}
