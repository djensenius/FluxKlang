//
//  GenerationLedger.swift
//  FluxKlang
//
//  The live generation counters of one graph (media-contract.md §5.1–§5.4).
//  Generations start at 1, step by exactly 1 and compare by equality only (M2).
//  The ledger also tracks the clock-restart obligations of §5.3 and the
//  transport resume position that a locate or transport restart supersedes.
//

import Foundation

/// Why a counter change was refused. A refused change alters nothing.
enum GenerationLedgerError: Error, Equatable, Sendable {
    /// A transport or musical-map counter that is not the declared musical clock.
    case undeclaredMusicalClock(GenerationKey)
    /// A sample clock other than the primary one; v1 has one primary clock per graph.
    case undeclaredSampleClock(GenerationKey)
    /// The primary clock changed again before its restart record and transport bump existed.
    case restartObligationsPending
    case noPendingRestart
    case restartAlreadyRecorded
    case restartGenerationMismatch
    case reasonDoesNotMatchKind(GenerationKey)
    case overflow
    case invalidRate
    case aliasedClocks
    case undeclaredCounter(GenerationKey)
    case alreadyDeclared(GenerationKey)
}

/// Why a counter is bumped (§5.1).
enum GenerationBumpReason: Hashable, Sendable {
    case deviceRestart, rateChange(nominalRate: Int), configurationChange, wake
    case locate(ticks: Int64), clockRestart, transportRestart
    case tempoEdit, externalTempo
    case sourceLost, sourceReacquired
    case contextChange
    case userCancel

    var kind: GenerationKind {
        switch self {
        case .deviceRestart, .rateChange, .configurationChange, .wake: .sampleClock
        case .locate, .clockRestart, .transportRestart: .transport
        case .tempoEdit, .externalTempo: .musicalMap
        case .sourceLost, .sourceReacquired: .source
        case .contextChange: .context
        case .userCancel: .cancelScope
        }
    }
}

/// A `clockRestart` discontinuity: where the new generation starts and the end
/// of the frames rendered in the old one.
struct ClockRestartRecord: Hashable, Sendable {
    let start: SampleStamp
    let host: HostStamp
    let previousFrame: Int64
}

/// Where the transport resumes after its latest bump.
enum TransportResume: Hashable, Sendable {
    /// The musical position of the restart's `previousFrame` (§5.3 step 3).
    case afterRestart(previousFrame: Int64)
    /// A locate's target, which supersedes any pending restart position (§5.4).
    case locate(ticks: Int64)
}

struct GenerationLedger: Sendable {
    let primaryClock: GenerationKey
    let musicalClock: ClockID?
    private(set) var current: [GenerationKey: Generation] = [:]
    private(set) var pendingRestart: Generation?
    private(set) var restartRecord: ClockRestartRecord?
    private(set) var awaitingTransportBump = false
    private(set) var resume: TransportResume?
    private(set) var nominalRate: Int
    private var restartPositionSuperseded = false

    /// `musicalClock` is nil when the graph has no transport.
    /// The declared generation rate, not a hardware measurement. No implicit default.
    init(primaryClock: ClockID, musicalClock: ClockID?, nominalRate: Int,
         declaring counters: [GenerationKey] = []) throws(GenerationLedgerError) {
        guard MediaNominalRate.isValid(nominalRate) else { throw .invalidRate }
        guard primaryClock != musicalClock else { throw .aliasedClocks }
        self.primaryClock = GenerationKey(.sampleClock, primaryClock)
        self.musicalClock = musicalClock
        self.nominalRate = nominalRate
        current[self.primaryClock] = .initial
        if let musicalClock {
            current[GenerationKey(.transport, musicalClock)] = .initial
            current[GenerationKey(.musicalMap, musicalClock)] = .initial
        }
        for key in counters { try declare(key) }
    }

    /// Declare an owned counter once. There is deliberately no removal/reset API:
    /// redeclaration could make a stale generation current again (M2, M4).
    mutating func declare(_ key: GenerationKey) throws(GenerationLedgerError) {
        switch key.kind {
        case .sampleClock:
            guard key == primaryClock else { throw .undeclaredSampleClock(key) }
        case .transport, .musicalMap:
            guard let musicalClock, key == GenerationKey(key.kind, musicalClock) else {
                throw .undeclaredMusicalClock(key)
            }
        default: break
        }
        guard current[key] == nil else { throw .alreadyDeclared(key) }
        current[key] = .initial
    }

    /// Unknown counters have no generation, not an implicit generation 1.
    func generation(_ key: GenerationKey) -> Generation? {
        current[key]
    }

    /// True while a primary clock change still lacks its record or transport bump.
    var hasRestartObligations: Bool {
        pendingRestart != nil && (restartRecord == nil || awaitingTransportBump)
    }

    func isCurrent(_ requirement: GenerationRequirement) -> Bool {
        return generation(requirement.key) == requirement.generation
    }

    @discardableResult
    mutating func bump(_ key: GenerationKey, reason: GenerationBumpReason) throws(GenerationLedgerError) -> Generation {
        try validateBump(key, reason: reason)
        guard let previous = generation(key) else { throw .undeclaredCounter(key) }
        let next: Generation
        do { next = try previous.next() } catch { throw .overflow }
        current[key] = next
        if case .rateChange(let rate) = reason { nominalRate = rate }
        switch reason {
        case .clockRestart:
            awaitingTransportBump = false
        case .locate(let ticks):
            resume = .locate(ticks: ticks)
            restartPositionSuperseded = true
        case .transportRestart:
            resume = nil
            restartPositionSuperseded = true
        case _ where key.kind == .sampleClock:
            pendingRestart = next
            restartRecord = nil
            awaitingTransportBump = musicalClock != nil
            restartPositionSuperseded = false
        default: break
        }
        return next
    }

    private func validateBump(_ key: GenerationKey, reason: GenerationBumpReason) throws(GenerationLedgerError) {
        guard reason.kind == key.kind else { throw .reasonDoesNotMatchKind(key) }
        if case .rateChange(let rate) = reason, !MediaNominalRate.isValid(rate) { throw .invalidRate }
        switch key.kind {
        case .sampleClock:
            guard key == primaryClock else { throw .undeclaredSampleClock(key) }
            guard !hasRestartObligations else { throw .restartObligationsPending }
        case .transport, .musicalMap:
            guard let musicalClock, key == GenerationKey(key.kind, musicalClock) else {
                throw .undeclaredMusicalClock(key)
            }
            if reason == .clockRestart, !awaitingTransportBump { throw .noPendingRestart }
        default:
            break
        }
    }

    /// Records the `clockRestart` discontinuity of the pending primary change.
    mutating func recordClockRestart(_ record: ClockRestartRecord) throws(GenerationLedgerError) {
        guard let pendingRestart else { throw .noPendingRestart }
        guard restartRecord == nil else { throw .restartAlreadyRecorded }
        guard record.start.generation == pendingRestart,
              GenerationKey(.sampleClock, record.start.clock) == primaryClock else {
            throw .restartGenerationMismatch
        }
        restartRecord = record
        if musicalClock != nil, !restartPositionSuperseded {
            resume = .afterRestart(previousFrame: record.previousFrame)
        }
    }

    /// §5.3 step 4: the first anchor after a restart is not before the restart's
    /// `(frame, hostTicks)` and agrees with it at the new rate within the §5.2 bound.
    func acceptsFirstAnchor(_ anchor: ClockAnchor, nominalRate: Int, timebase: HostTimebase) -> Bool {
        guard let record = restartRecord else { return false }
        guard self.nominalRate == nominalRate else { return false }
        let origin = ClockAnchor(sample: record.start, host: record.host)
        guard let map = try? SampleClockMap(anchor: origin, nominalRate: nominalRate, timebase: timebase) else {
            return false
        }
        return map.agrees(anchor)
    }
}
