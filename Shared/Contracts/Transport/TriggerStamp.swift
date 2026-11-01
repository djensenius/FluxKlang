//
//  TriggerStamp.swift
//  FluxKlang
//
//  A stamped request to perform a prepared action (media-contract.md §3, §6).
//  Validation enforces the trigger-shape rules: at most 8 requirements, no
//  musical-map dependency (M3), a context dependency on every trigger (§5.8),
//  `nextBoundary` always requiring the transport
//  (§6.3) and the retroactive window bounds.
//

import Foundation

/// Where a trigger lands (§6.2).
enum TriggerTarget: Hashable, Sendable, BitwiseCopyable {
    /// The next `gridTicks` boundary at or after the origin.
    case grid(ticks: Int64)
    case musical(atTicks: Int64)
    case sample(atFrame: Int64)
    case asap

    var isMusical: Bool {
        switch self {
        case .grid, .musical: true
        case .sample, .asap: false
        }
    }
}

enum TriggerValidationError: Error, Hashable, Sendable {
    case tooManyRequirements(Int)
    case duplicateRequirement(GenerationKey)
    /// Musical-map revisions are never dependencies (M3).
    case musicalMapDependency
    /// `nextBoundary` must require the declared musical clock's transport (§6.3).
    case nextBoundaryWithoutTransport
    case missingGrid
    case invalidGrid(Int64)
    case invalidRetroactive(Int)
    case invalidLateness(Int)
    case missingPrimaryClock
    case missingTransport
    case missingContext
    case invalidMusicalTicks(Int64)
    case undeclaredClock(GenerationKey)
    case invalidPrimaryClock(GenerationKey)
    case aliasedClocks
}

/// Control-plane request, not a render-thread value; prepare a RuntimeTriggerStamp for the kernel.
struct TriggerStamp: Hashable, Sendable {
    static let maximumRequirements = 8
    static let maximumRetroactiveMs = 120

    let id: TriggerID
    let action: ActionID
    let originHost: HostStamp
    /// The horizon at arrival; lateness is judged against the horizon at commit.
    let horizonFrame: Int64
    let requires: [GenerationRequirement]
    let target: TriggerTarget
    let latePolicy: LatePolicy
    var retroactiveMs = 0
    var stoppedPolicy = StoppedPolicy.wait
    /// Origin occurrence, not the loop pass current at delivery.
    var loopIteration: UInt32 = 0

    /// The trigger grid overrides the prepared action's fallback grid (§6.3).
    var fallbackGrid: Int64? {
        guard case .nextBoundary(let grid) = latePolicy else { return nil }
        if case .grid(let ticks) = target { return ticks }
        return grid
    }

    func validate(primaryClock: GenerationKey, musicalClock: ClockID?) throws(TriggerValidationError) {
        try validateClockDeclarations(primaryClock: primaryClock, musicalClock: musicalClock)
        guard requires.count <= Self.maximumRequirements else { throw .tooManyRequirements(requires.count) }
        var keys = Set<GenerationKey>()
        for requirement in requires {
            guard requirement.key.kind != .musicalMap else { throw .musicalMapDependency }
            guard keys.insert(requirement.key).inserted else { throw .duplicateRequirement(requirement.key) }
            if requirement.key.kind == .sampleClock, requirement.key != primaryClock {
                throw .undeclaredClock(requirement.key)
            }
            if requirement.key.kind == .transport,
               musicalClock.map({ GenerationKey(.transport, $0) }) != requirement.key {
                throw .undeclaredClock(requirement.key)
            }
        }
        guard keys.contains(primaryClock) else { throw .missingPrimaryClock }
        guard keys.contains(where: { $0.kind == .context }) else { throw .missingContext }
        if target.isMusical {
            guard let musicalClock, keys.contains(GenerationKey(.transport, musicalClock)) else {
                throw .missingTransport
            }
        }
        try validateTiming(keys: keys, musicalClock: musicalClock)
    }

    private func validateClockDeclarations(primaryClock: GenerationKey,
                                           musicalClock: ClockID?) throws(TriggerValidationError) {
        guard primaryClock.kind == .sampleClock else { throw .invalidPrimaryClock(primaryClock) }
        if let musicalClock, primaryClock.subject == GenerationKey(.transport, musicalClock).subject {
            throw .aliasedClocks
        }
    }

    private func validateTiming(keys: Set<GenerationKey>, musicalClock: ClockID?) throws(TriggerValidationError) {
        if case .grid(let ticks) = target, ticks <= 0 { throw .invalidGrid(ticks) }
        if case .musical(let ticks) = target, ticks < 0 { throw .invalidMusicalTicks(ticks) }
        if case .nextBoundary = latePolicy {
            guard let musicalClock, keys.contains(GenerationKey(.transport, musicalClock)) else {
                throw .nextBoundaryWithoutTransport
            }
            guard let grid = fallbackGrid else { throw .missingGrid }
            guard grid > 0 else { throw .invalidGrid(grid) }
        }
        if let maximum = latePolicy.maxLatenessMs, !(0...1_000).contains(maximum) {
            throw .invalidLateness(maximum)
        }
        guard retroactiveMs == 0 || ((0...Self.maximumRetroactiveMs).contains(retroactiveMs)
            && retroactiveMs <= latePolicy.maxLatenessMs ?? -1) else {
            throw .invalidRetroactive(retroactiveMs)
        }
    }
}

/// How a capture stamp relates to the current generations (§9.2). Captures
/// stamped before a clock restart or a transport change but delivered after it
/// are unsupported in v1: they are reported, never remapped and never lossless.
enum CaptureDelivery: Hashable, Sendable {
    case current
    case stampedBeforeClockRestart
    case stampedBeforeTransportChange
    case undeclaredTransport

    var isSupported: Bool { self == .current }
    var mayRemap: Bool { isSupported }
    var mayClaimLossless: Bool { isSupported }
}

extension GenerationLedger {
    func classifyCapture(sample: SampleStamp, transport: Generation?) -> CaptureDelivery {
        guard GenerationKey(.sampleClock, sample.clock) == primaryClock,
              sample.generation == generation(primaryClock) else { return .stampedBeforeClockRestart }
        if let transport {
            guard let musicalClock else { return .undeclaredTransport }
            if transport != generation(GenerationKey(.transport, musicalClock)) {
                return .stampedBeforeTransportChange
            }
        }
        return .current
    }
}
