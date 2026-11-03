import Foundation

/// Pure state consumed by the SDK owner. Permits establish return, never delivery.
@MainActor
final class UIAuditCaptureState {
    enum Outcome { case failed, incomplete, completedClean }
    enum Slot: Int { case entry, exit }
    enum Position: Int, CaseIterable {
        case entryPre, entryPost, exitPre, exitPost
        var slot: Slot { rawValue < 2 ? .entry : .exit }
        var isPost: Bool { rawValue % 2 == 1 }
    }
    enum Refusal: Equatable {
        case overlap, ordinalExhaustion, preflight(UIAuditRunPreflight.Refusal)
        case wrongOrder, closed, finishInFlight, invalidated
        case baseline(Position), post(Position)
    }
    enum Operation { case creation, sample(Slot), finish, rejection }
    enum Phase: Equatable {
        case creationIntent, creationOutcome, queryIntent(Position), read(Position)
        case observation(Position, raw: Bool), commandIntent(Slot), command(Slot)
        case refusal, finish, done
    }
    enum Boundary: CaseIterable { case construct, name, lifetime, add, read, command }
    enum Record: Hashable {
        case overlap, preflight, exhaustion, creationIntent, creationOutcome
        case query(Position), summary(Position), raw(Position), command(Slot)
        case entryRefusal, exitRefusal, misuse, finish
    }
    enum Consumption { case attempted, suppressed }
    struct Observation {
        var value: UIAuditSnapshotReader.Observation?
        var validation: UIAuditReceiptValidator.Result?
    }
    final class Launch {
        let ordinal: UInt64
        let configuration: UIAuditRunPreflight.ValidatedLaunchConfiguration
        fileprivate var validator: UIAuditReceiptValidator
        fileprivate(set) var observations = Array(repeating: Observation(), count: 4)
        fileprivate(set) var records: [Record: Consumption] = [:]
        fileprivate(set) var sampled: Set<Slot> = []
        fileprivate(set) var terminal: Outcome?
        fileprivate(set) var failed = false
        init(ordinal: UInt64, configuration: UIAuditRunPreflight.ValidatedLaunchConfiguration) {
            self.ordinal = ordinal
            self.configuration = configuration
            validator = UIAuditReceiptValidator(expectedRunID: configuration.runID)
        }
    }
    final class Token {
        let ordinal: UInt64
        let launch: Launch?
        let operation: Operation
        fileprivate(set) var phase: Phase
        fileprivate(set) var valid = true
        fileprivate(set) var inCall = false
        fileprivate(set) var boundary: Boundary?
        fileprivate(set) var refusal: Refusal?
        fileprivate var rejectionRecord: Record?
        fileprivate var provisional: Outcome?
        init(ordinal: UInt64, launch: Launch?, operation: Operation, phase: Phase) {
            self.ordinal = ordinal
            self.launch = launch
            self.operation = operation
            self.phase = phase
        }
    }
    enum Opening {
        case admitted(Launch, Token)
        case refused(Refusal, Token?)
    }
    enum Beginning {
        case admitted(Token)
        case refused(Refusal, Token?)
        case closed(Outcome)
    }
    struct Evidence {
        let name: String
        let text: String
    }

    private(set) var failed = false
    private(set) var priorIncomplete = false
    private(set) var lastOrdinal: UInt64
    private(set) var pendingOrdinal: UInt64?
    private(set) var active: Launch?
    private(set) var busy: Token?
    private(set) var runRecords: [Record: Consumption] = [:]
    private var hasFinished = false

    init(lastOrdinal: UInt64 = 0) { self.lastOrdinal = lastOrdinal }

    var outcome: Outcome {
        if failed { return .failed }
        if !hasFinished || priorIncomplete || pendingOrdinal != nil || active != nil || busy != nil {
            return .incomplete
        }
        return .completedClean
    }

    func open(runner: [String: String], app: [String: String], arguments: [String]) -> Opening {
        if pendingOrdinal != nil || active != nil || busy != nil {
            return .refused(.overlap, reject(.overlap, record: .overlap))
        }
        guard lastOrdinal < UInt64.max else {
            return .refused(.ordinalExhaustion, reject(.ordinalExhaustion, record: .exhaustion))
        }
        lastOrdinal += 1
        let ordinal = lastOrdinal
        pendingOrdinal = ordinal
        switch UIAuditRunPreflight.validate(runnerEnvironment: runner, appEnvironment: app, appArguments: arguments) {
        case .failure(let reason):
            if pendingOrdinal == ordinal { pendingOrdinal = nil }
            return .refused(.preflight(reason), reject(.preflight(reason), record: .preflight))
        case .success(let configuration):
            let launch = Launch(ordinal: ordinal, configuration: configuration)
            let token = Token(ordinal: ordinal, launch: launch, operation: .creation, phase: .creationIntent)
            busy = token
            return .admitted(launch, token)
        }
    }

    func begin(_ launch: Launch, slot: Slot) -> Beginning {
        let record: Record = slot == .entry ? .entryRefusal : .exitRefusal
        guard launch.terminal == nil else {
            return .refused(.closed, reject(.closed, record: .misuse, launch: launch))
        }
        guard busy == nil else {
            return .refused(.overlap, reject(.overlap, record: record, launch: launch))
        }
        guard active === launch, !launch.sampled.contains(slot),
              slot == .entry ? launch.records[.query(.entryPre)] == nil : launch.sampled.contains(.entry),
              slot == .entry || launch.records[.query(.exitPre)] == nil else {
            return .refused(.wrongOrder, reject(.wrongOrder, record: record, launch: launch))
        }
        let position: Position = slot == .entry ? .entryPre : .exitPre
        let token = Token(ordinal: launch.ordinal, launch: launch,
                          operation: .sample(slot), phase: .queryIntent(position))
        busy = token
        return .admitted(token)
    }

    func finish(_ launch: Launch) -> Beginning {
        if let terminal = launch.terminal { return .closed(terminal) }
        guard busy == nil else {
            return .refused(.finishInFlight, reject(.finishInFlight, record: .misuse, launch: launch))
        }
        guard active === launch else {
            return .refused(.wrongOrder, reject(.wrongOrder, record: .misuse, launch: launch))
        }
        let token = Token(ordinal: launch.ordinal, launch: launch, operation: .finish, phase: .finish)
        token.provisional = failed || launch.failed
            ? .failed : launch.sampled.count == 2 ? .completedClean : .incomplete
        busy = token
        nextFinishRecord(token)
        return .admitted(token)
    }

    /// Every rejection consumes a bounded position, including when effects must be suppressed.
    private func reject(_ reason: Refusal, record: Record, launch: Launch? = nil) -> Token? {
        failed = true
        launch?.failed = true
        if let busy {
            busy.valid = false
            consume(record, launch: launch, as: .suppressed)
            return nil
        }
        guard consume(record, launch: launch, as: .attempted) else { return nil }
        let token = Token(ordinal: launch?.ordinal ?? lastOrdinal, launch: launch,
                          operation: .rejection, phase: .refusal)
        token.refusal = reason
        token.rejectionRecord = record
        busy = token
        return token
    }

    @discardableResult
    private func consume(_ record: Record, launch: Launch?, as consumption: Consumption) -> Bool {
        if let launch {
            guard launch.records[record] == nil else { return false }
            launch.records[record] = consumption
        } else {
            guard runRecords[record] == nil else { return false }
            runRecords[record] = consumption
        }
        return true
    }

    private func owns(_ token: Token) -> Bool {
        guard busy === token else { return false }
        switch token.operation {
        case .creation: return pendingOrdinal == token.ordinal
        case .sample, .finish: return active === token.launch
        case .rejection: return true
        }
    }

    func permits(_ token: Token, phase: Phase) -> Bool {
        owns(token) && token.valid && token.phase == phase
    }

    /// Consumed before the attachment constructor; four guarded calls must then return.
    func evidence(_ token: Token, phase: Phase) -> Evidence? {
        guard permits(token, phase: phase), !token.inCall, token.boundary == nil,
              let record = record(for: token) else { return nil }
        if token.rejectionRecord == nil && !consume(record, launch: token.launch, as: .attempted) { return nil }
        token.boundary = .construct
        return Evidence(name: "ui-audit-launch-\(token.ordinal)-\(record)", text: text(for: token))
    }

    func start(_ token: Token, phase: Phase, boundary: Boundary) -> Bool {
        guard permits(token, phase: phase), !token.inCall else { return false }
        let expected: Boundary?
        switch phase {
        case .read: expected = .read
        case .command: expected = .command
        default: expected = token.boundary
        }
        guard expected == boundary else { return false }
        token.boundary = boundary
        token.inCall = true
        return true
    }

    func returned(_ token: Token, phase: Phase, boundary: Boundary) -> Bool {
        guard boundary != .read else { return false }
        guard owns(token), token.phase == phase, token.inCall, token.boundary == boundary else { return false }
        token.inCall = false
        guard token.valid else { return false }
        switch boundary {
        case .construct: token.boundary = .name
        case .name: token.boundary = .lifetime
        case .lifetime: token.boundary = .add
        case .add:
            token.boundary = nil
            advance(token)
        case .command:
            guard case .command(let slot) = phase else { return false }
            token.boundary = nil
            token.phase = .queryIntent(slot == .entry ? .entryPost : .exitPost)
        case .read: return false // Observations must use returnedObservation.
        }
        return true
    }

    /// Even an invalidated continuation can retain only its own already-returned observation.
    func returnedObservation(_ value: UIAuditSnapshotReader.Observation, token: Token, position: Position) -> Bool {
        guard owns(token), token.phase == .read(position), token.inCall, token.boundary == .read,
              let launch = token.launch,
              launch.observations[position.rawValue].value == nil else { return false }
        launch.observations[position.rawValue].value = value
        token.inCall = false
        guard token.valid else { return false }
        token.boundary = nil
        classify(value, position: position, token: token, launch: launch)
        token.phase = .observation(position, raw: false)
        return true
    }

    static func receiptsMatch(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }

    private func classify(
        _ value: UIAuditSnapshotReader.Observation, position: Position, token: Token, launch: Launch
    ) {
        var clean = false
        if position.isPost {
            switch value {
            case .receipt(let raw):
                let result = launch.validator.observe(raw)
                launch.observations[position.rawValue].validation = result
                clean = result.outcome == .clean
            case .missingValue:
                launch.observations[position.rawValue].validation = launch.validator.observe(nil)
            default: break
            }
        } else if position == .entryPre {
            clean = value == .missingValue
        } else if case .receipt(let raw) = value,
                  case .receipt(let entry) = launch.observations[Position.entryPost.rawValue].value {
            clean = Self.receiptsMatch(raw, entry)
        }
        if !clean {
            token.refusal = position.isPost ? .post(position) : .baseline(position)
            launch.failed = true
            failed = true
        }
    }

    /// Only matching identity cleanup; invalid creation remains pending.
    func settle(_ token: Token) -> Bool {
        guard owns(token), !token.inCall else { return false }
        let completed = token.valid && token.phase == .done && token.boundary == nil
        if !completed {
            failed = true
            token.launch?.failed = true
            token.valid = false
        }
        switch token.operation {
        case .creation where completed:
            active = token.launch
            pendingOrdinal = nil
        case .sample(let slot) where completed && token.refusal == nil:
            token.launch?.sampled.insert(slot)
        case .finish:
            if let launch = token.launch {
                let terminal: Outcome = completed && !launch.failed ? token.provisional ?? .incomplete : .failed
                launch.terminal = terminal
                priorIncomplete = priorIncomplete || terminal == .incomplete
                hasFinished = true
                active = nil
            }
        default: break
        }
        busy = nil
        return completed
    }
}

private extension UIAuditCaptureState {
    func record(for token: Token) -> Record? {
        switch token.phase {
        case .creationIntent: return .creationIntent
        case .creationOutcome: return .creationOutcome
        case .queryIntent(let position): return .query(position)
        case .observation(let position, let raw): return raw ? .raw(position) : .summary(position)
        case .commandIntent(let slot): return .command(slot)
        case .refusal:
            if let record = token.rejectionRecord { return record }
            if case .sample(let slot) = token.operation { return slot == .entry ? .entryRefusal : .exitRefusal }
            return .misuse
        case .finish: return .finish
        default: return nil
        }
    }

    func text(for token: Token) -> String {
        switch token.phase {
        case .observation(let position, let raw):
            let observation = token.launch?.observations[position.rawValue]
            if raw, case .receipt(let receipt) = observation?.value { return receipt }
            return "\(kind(observation?.value)); validation=\(String(describing: observation?.validation?.diagnostics))"
        case .refusal: return "refused: \(String(describing: token.refusal))"
        case .finish:
            return "provisional \(String(describing: token.provisional)); not committed; delivery unproven"
        case .creationOutcome: return "supplied-value preflight returned; launch/configuration delivery unproven"
        default: return "intent \(token.phase); no acknowledgement"
        }
    }

    func kind(_ value: UIAuditSnapshotReader.Observation?) -> String {
        switch value {
        case nil: return "notRead"
        case .snapshotUnavailable: return "snapshotUnavailable"
        case .observationIncomplete: return "observationIncomplete"
        case .absent: return "absent"
        case .ambiguous: return "ambiguous"
        case .missingValue: return "observedMissingValue"
        case .nonStringValue: return "nonStringValue"
        case .receipt: return "receipt"
        }
    }

    func advance(_ token: Token) {
        switch token.phase {
        case .creationIntent: token.phase = .creationOutcome
        case .creationOutcome, .refusal, .finish: token.phase = .done
        case .queryIntent(let position): token.phase = .read(position)
        case .commandIntent(let slot): token.phase = .command(slot)
        case .observation(let position, let raw):
            if !raw, case .receipt = token.launch?.observations[position.rawValue].value,
               token.launch?.records[.raw(position)] == nil {
                token.phase = .observation(position, raw: true)
            } else if case .finish = token.operation {
                nextFinishRecord(token)
            } else if token.refusal != nil {
                token.phase = .refusal
            } else if position.isPost {
                token.phase = .done
            } else {
                token.phase = .commandIntent(position.slot)
            }
        default: break
        }
    }

    func nextFinishRecord(_ token: Token) {
        guard let launch = token.launch else { return }
        for position in Position.allCases {
            if launch.records[.summary(position)] == nil {
                token.phase = .observation(position, raw: false)
                return
            }
            if case .receipt = launch.observations[position.rawValue].value, launch.records[.raw(position)] == nil {
                token.phase = .observation(position, raw: true)
                return
            }
        }
        token.phase = .finish
    }
}
