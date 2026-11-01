//
//  TriggerScheduler.swift
//  FluxKlang
//
//  The contract-level trigger lifecycle (media-contract.md §6): synchronous
//  `capacity` refusal with outcome-slot reservation (M5), precedence
//  stale → cancelled → notReady → timing (§6.4), lateness judged against the
//  horizon at commit (§6.1), the stopped-transport policy (§6.2) and the late
//  policies (§6.3). A model of the rules, not a render-thread queue (#64, #107).
//

import Foundation

enum SubmitRefusal: Hashable, Sendable {
    /// No free outcome slot: nothing is accepted and no outcome is emitted (M5).
    case capacity
    case duplicateTrigger
    case invalid(TriggerValidationError)
    /// A ready grid target needs its origin map to freeze the quantized occurrence.
    case musicalContextRequired
    case invalidMusicalContext
}

enum SubmitResult: Hashable, Sendable {
    case accepted
    case refused(SubmitRefusal)
}

enum CommitError: Error, Equatable, Sendable {
    case unknownTrigger(TriggerID)
    /// The horizon is not on the primary clock's current generation.
    case staleHorizon
    /// The horizon moved back within one primary generation: frames before the
    /// floor are already rendered.
    case horizonRegressed(floor: Int64, found: Int64)
    case invalidRate
}

/// The latency-inclusive horizon at commit, on the primary sample clock.
struct CommitHorizon: Hashable, Sendable {
    let generation: Generation
    let frame: Int64
    let nominalRate: Int
}

/// The musical state a commit resolves musical targets against (M6).
struct MusicalContext: Sendable {
    /// Generation's first sample anchor (or restart point), so observation tolerance never accumulates.
    let sample: SampleClockMap
    let map: MusicalClockMap
    var loop: LoopRange?
    var isRunning = true
    /// Running resume observation at the stopped origin position, before the current pass.
    /// Required for an older-pass target submitted while stopped; never infer it from a stopped anchor.
    var resumeAnchor: ClockAnchor?
}

enum CommitDecision: Hashable, Sendable {
    /// Stopped transport with the `wait` policy: still pending.
    case waitForTransport
    /// Stopped transport with `startTransport`: start it, then this outcome.
    case startTransport(TriggerOutcome)
    case resolved(TriggerOutcome)
}

private struct MusicalOccurrence: Sendable {
    let pass: Int128
    let ticks: Int64
}

private struct PreparedMusicalTarget: Sendable {
    let occurrence: MusicalOccurrence?
    let anchor: ClockAnchor
    let stoppedAt: HostStamp?
}

struct TriggerScheduler: Sendable {
    let outcomeCapacity: Int
    private(set) var pending: [TriggerID: (stamp: TriggerStamp, readyEntry: Int?)] = [:]
    private(set) var outcomes: [TriggerOutcome] = []
    private var seen = Set<TriggerID>()
    private var horizonFloor: (generation: Generation, frame: Int64)?
    private var musicalTargets: [TriggerID: PreparedMusicalTarget] = [:]

    init(outcomeCapacity: Int) {
        self.outcomeCapacity = min(max(outcomeCapacity, 0), 4096)
    }

    /// Slots held by pending triggers and undrained outcomes.
    var reservedSlots: Int { pending.count + outcomes.count }

    mutating func submit(_ stamp: TriggerStamp, ledger: GenerationLedger, readiness: ActionReadiness,
                         musical: MusicalContext? = nil) -> SubmitResult {
        do {
            try stamp.validate(primaryClock: ledger.primaryClock, musicalClock: ledger.musicalClock)
        } catch { return .refused(.invalid(error)) }
        guard !seen.contains(stamp.id) else { return .refused(.duplicateTrigger) }
        guard reservedSlots < outcomeCapacity, seen.count < 65_536 else { return .refused(.capacity) }
        guard let primaryGeneration = ledger.generation(ledger.primaryClock) else {
            return .refused(.invalid(.missingPrimaryClock))
        }
        let stale = stamp.requires.first(where: { !ledger.isCurrent($0) })
        let readyEntry = readiness.isCurrent(stamp.action, ledger: ledger) ? readiness.readyEntry(stamp.action) : nil
        if stale == nil, readyEntry != nil, stamp.target.isMusical {
            let horizon = CommitHorizon(generation: primaryGeneration, frame: stamp.horizonFrame,
                                        nominalRate: ledger.nominalRate)
            if let refusal = prepareMusicalTarget(stamp, ledger: ledger, horizon: horizon, musical: musical) {
                return .refused(refusal)
            }
        }
        seen.insert(stamp.id)
        if stamp.requires.contains(where: { $0.key == ledger.primaryClock && ledger.isCurrent($0) }) {
            raiseFloor(generation: primaryGeneration, frame: stamp.horizonFrame)
        }
        if let stale {
            outcomes.append(TriggerOutcome(trigger: stamp.id, result: .rejectedStale, stale: .generation(stale.key)))
        } else {
            pending[stamp.id] = (stamp, readyEntry)
        }
        return .accepted
    }

    private mutating func prepareMusicalTarget(_ stamp: TriggerStamp, ledger: GenerationLedger,
                                               horizon: CommitHorizon, musical: MusicalContext?) -> SubmitRefusal? {
        guard let musical else {
            if case .grid = stamp.target { return .musicalContextRequired }
            return nil
        }
        guard Self.isCurrent(musical, ledger: ledger, horizon: horizon) else { return .invalidMusicalContext }
        do {
            musicalTargets[stamp.id] = PreparedMusicalTarget(
                occurrence: try Self.targetOccurrence(stamp, musical: musical, horizon: horizon),
                anchor: musical.map.anchor, stoppedAt: musical.isRunning ? nil : stamp.originHost
            )
        } catch { return .invalidMusicalContext }
        return nil
    }

    /// Hands outcomes to the consumer and frees their slots.
    mutating func drainOutcomes() -> [TriggerOutcome] {
        defer { outcomes.removeAll() }
        return outcomes
    }

    /// Cancels every pending trigger whose required generation changed (M4).
    @discardableResult
    mutating func cancelStale(ledger: GenerationLedger) -> [TriggerOutcome] {
        pending.keys.sorted().compactMap { id in
            guard let stale = pending[id]?.stamp.requires.first(where: { !ledger.isCurrent($0) }) else { return nil }
            return finish(TriggerOutcome(trigger: id, result: .cancelled, stale: .generation(stale.key)))
        }
    }

    mutating func commit(_ id: TriggerID, at horizon: CommitHorizon, ledger: GenerationLedger,
                         readiness: ActionReadiness, musical: MusicalContext?) throws(CommitError) -> CommitDecision {
        guard let entry = pending[id] else { throw .unknownTrigger(id) }
        let stamp = entry.stamp
        guard MediaNominalRate.isValid(horizon.nominalRate),
              ledger.nominalRate == horizon.nominalRate else { throw .invalidRate }
        guard horizon.generation == ledger.generation(ledger.primaryClock) else { throw .staleHorizon }
        if let floor = horizonFloor, floor.generation == horizon.generation, horizon.frame < floor.frame {
            throw .horizonRegressed(floor: floor.frame, found: horizon.frame)
        }
        raiseFloor(generation: horizon.generation, frame: horizon.frame)
        if let stale = stamp.requires.first(where: { !ledger.isCurrent($0) }) {
            return .resolved(finish(TriggerOutcome(trigger: id, result: .cancelled, stale: .generation(stale.key))))
        }
        guard let readyEntry = entry.readyEntry, readiness.readyEntry(stamp.action) == readyEntry,
              readiness.isCurrent(stamp.action, ledger: ledger) else {
            return .resolved(finish(TriggerOutcome(trigger: id, result: .dropped, reason: .notReady)))
        }
        if Self.usesMusicalContext(stamp, horizon: horizon), let musical,
           !Self.isCurrent(musical, ledger: ledger, horizon: horizon) || !matchesOriginPass(stamp, musical: musical) {
            return .resolved(finish(TriggerOutcome(trigger: id, result: .dropped, reason: .invalidTiming)))
        }
        return timingDecision(stamp, horizon: horizon, musical: musical)
    }

    private func matchesOriginPass(_ stamp: TriggerStamp, musical: MusicalContext) -> Bool {
        guard stamp.target.isMusical else { return true }
        if let origin = musicalTargets[stamp.id]?.anchor.musical {
            return origin.loopIteration <= musical.map.musical.loopIteration
        }
        return stamp.loopIteration == musical.map.musical.loopIteration
    }

    private static func usesMusicalContext(_ stamp: TriggerStamp, horizon: CommitHorizon) -> Bool {
        if stamp.target.isMusical { return true }
        if case .sample(let frame) = stamp.target, case .nextBoundary = stamp.latePolicy {
            return frame < horizon.frame
        }
        return false
    }

    private static func isCurrent(_ musical: MusicalContext, ledger: GenerationLedger,
                                  horizon: CommitHorizon) -> Bool {
        musical.map.map.clock == ledger.musicalClock
            && GenerationKey(.sampleClock, musical.map.anchor.sample.clock) == ledger.primaryClock
            && GenerationKey(.sampleClock, musical.sample.anchor.sample.clock) == ledger.primaryClock
            && musical.map.anchor.sample.generation == horizon.generation
            && musical.sample.anchor.sample.generation == horizon.generation
            && musical.map.musical.transport == ledger.generation(GenerationKey(.transport, musical.map.map.clock))
            && musical.map.map.revision == ledger.generation(GenerationKey(.musicalMap, musical.map.map.clock))
            && musical.map.nominalRate == horizon.nominalRate
            && musical.sample.nominalRate == horizon.nominalRate
    }

    private mutating func timingDecision(_ stamp: TriggerStamp, horizon: CommitHorizon,
                                         musical: MusicalContext?) -> CommitDecision {
        let id = stamp.id
        if stamp.target.isMusical, musical?.isRunning != true {
            switch stamp.stoppedPolicy {
            case .wait: return .waitForTransport
            case .immediate: return .resolved(finish(fired(id, at: horizon.frame)))
            case .startTransport: return .startTransport(finish(fired(id, at: horizon.frame)))
            }
        }
        do {
            return .resolved(finish(try resolveTiming(stamp, horizon: horizon, musical: musical)))
        } catch {
            return .resolved(finish(TriggerOutcome(trigger: id, result: .dropped, reason: .invalidTiming)))
        }
    }

    private func fired(_ id: TriggerID, at frame: Int64) -> TriggerOutcome {
        TriggerOutcome(trigger: id, result: .fired, assignedFrame: frame, frame: frame)
    }

    private func resolveTiming(_ stamp: TriggerStamp, horizon: CommitHorizon,
                               musical: MusicalContext?) throws -> TriggerOutcome {
        var outcome = TriggerOutcome(trigger: stamp.id, result: .fired)
        let assigned: Int64
        switch stamp.target {
        case .asap:
            assigned = horizon.frame
        case .sample(let frame):
            assigned = frame
        case .musical, .grid:
            guard let musical else { throw ClockMapError.noMusicalAnchor }
            let occurrence = try occurrence(for: stamp)
            outcome.musicalMap = musical.map.map.revision
            guard let occurrence, musical.loop?.admits(ticks: occurrence.ticks) ?? true else {
                outcome.result = .dropped
                outcome.reason = .outsideLoop
                return outcome
            }
            assigned = try Self.frame(of: occurrence, musical: musical, origin: musicalTargets[stamp.id]?.anchor,
                                      stoppedAt: musicalTargets[stamp.id]?.stoppedAt)
        }
        outcome.assignedFrame = assigned
        guard assigned < horizon.frame else {
            outcome.frame = assigned
            return outcome
        }
        let lateness = Int128(horizon.frame) - Int128(assigned)
        switch stamp.latePolicy {
        case .fireLate(let limit) where Self.within(lateness, limit, horizon.nominalRate):
            outcome.result = .firedLate
            outcome.frame = horizon.frame
        case .joinInProgress(let limit) where Self.within(lateness, limit, horizon.nominalRate):
            outcome.result = .joined
            outcome.frame = horizon.frame
            outcome.startOffsetFrames = try ExactMath.int64(lateness)
        case .nextBoundary:
            return try Self.nextBoundary(stamp, outcome: outcome, horizon: horizon, musical: musical)
        default:
            outcome.result = .dropped
            outcome.reason = .late
        }
        return outcome
    }

    private func occurrence(for stamp: TriggerStamp) throws -> MusicalOccurrence? {
        if let prepared = musicalTargets[stamp.id] { return prepared.occurrence }
        if case .musical(let ticks) = stamp.target {
            return MusicalOccurrence(pass: Int128(stamp.loopIteration), ticks: ticks)
        }
        throw ClockMapError.noMusicalAnchor
    }

    private static func targetOccurrence(_ stamp: TriggerStamp, musical: MusicalContext,
                                         horizon: CommitHorizon) throws -> MusicalOccurrence? {
        guard musical.map.musical.loopIteration == stamp.loopIteration else { throw ClockMapError.noMusicalAnchor }
        let pass = Int128(stamp.loopIteration)
        switch stamp.target {
        case .musical(let ticks):
            return MusicalOccurrence(pass: pass, ticks: ticks)
        case .grid(let grid):
            // While stopped, host/sample time advances but the anchored musical position does not.
            let origin = try musical.isRunning
                ? musical.sample.frame(atHost: stamp.originHost, current: horizon.generation)
                : musical.map.anchor.sample.frame
            if musical.isRunning, let loop = musical.loop, musical.map.musical.ticks <= loop.endTicks,
               Int128(origin) >= wrapFrame(musical.map, loop: loop) {
                throw ClockMapError.noMusicalAnchor
            }
            if stamp.retroactiveMs > 0 {
                let exact = musical.map.exactTicks(atFrame: origin)
                let prior = ExactMath.floorDiv(exact.numerator, exact.denominator * Int128(grid)) * Int128(grid)
                if let ticks = Int64(exactly: prior), let previousFrame = try? musical.map.frame(atTicks: ticks) {
                    let elapsed = Int128(origin) - Int128(previousFrame)
                    if elapsed >= 0, elapsed * 1000 <= Int128(stamp.retroactiveMs) * Int128(horizon.nominalRate) {
                        return MusicalOccurrence(pass: pass, ticks: ticks)
                    }
                }
            }
            return try gridOccurrence(musical, at: origin, grid: grid)
        case .sample, .asap:
            return nil
        }
    }

    /// `nextBoundary`: the first fallback-grid boundary at or after the commit
    /// horizon, inside an active loop, naming the map revision used (§6.3, §5.5).
    private static func nextBoundary(_ stamp: TriggerStamp, outcome: TriggerOutcome, horizon: CommitHorizon,
                                     musical: MusicalContext?) throws -> TriggerOutcome {
        var outcome = outcome
        guard let musical, musical.isRunning, let grid = stamp.fallbackGrid else {
            outcome.result = .dropped
            outcome.reason = .late
            return outcome
        }
        outcome.musicalMap = musical.map.map.revision
        guard let occurrence = try gridOccurrence(musical, at: horizon.frame, grid: grid),
              musical.loop?.admits(ticks: occurrence.ticks) ?? true else {
            outcome.result = .dropped
            outcome.reason = .outsideLoop
            return outcome
        }
        let frame = try frame(of: occurrence, musical: musical)
        outcome.assignedFrame = frame
        outcome.frame = frame
        return outcome
    }

    /// Skip whole virtual passes arithmetically, then search only this pass's grid.
    /// Fractional loop lengths stay exact; only the final occurrence is rounded.
    private static func gridOccurrence(_ musical: MusicalContext, at horizon: Int64,
                                       grid: Int64) throws -> MusicalOccurrence? {
        let map = musical.map
        let iteration = Int128(map.musical.loopIteration)
        guard let loop = musical.loop else {
            return try MusicalOccurrence(pass: iteration, ticks: map.boundary(atOrAfterFrame: horizon, grid: grid))
        }
        let wrap = wrapFrame(map, loop: loop)
        if Int128(horizon) < wrap || map.musical.ticks > loop.endTicks {
            let ticks = try map.boundary(atOrAfterFrame: horizon, grid: grid)
            if loop.admits(ticks: ticks) { return MusicalOccurrence(pass: iteration, ticks: ticks) }
            if ticks < loop.startTicks || map.musical.ticks > loop.endTicks { return nil }
        }
        let first = ExactMath.ceilDiv(Int128(loop.startTicks), Int128(grid))
        let last = ExactMath.floorDiv(Int128(loop.endTicks), Int128(grid))
        guard first <= last else { return nil }
        let length = loopUnits(map, from: loop.startTicks, to: loop.endTicks)
        let elapsed = (Int128(horizon) - wrap) * unitsPerFrame
        var pass = max(0, ExactMath.floorDiv(elapsed, length))
        let start = wrap * unitsPerFrame + pass * length
        var lower = first
        var upper = last + 1
        // At most 64 bisections over the Int64 tick range; no per-pass walk.
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let ticks = try ExactMath.int64(middle * Int128(grid))
            let frame = start + loopUnits(map, from: loop.startTicks, to: ticks)
            if frame < Int128(horizon) * unitsPerFrame { lower = middle + 1 } else { upper = middle }
        }
        if lower > last {
            pass += 1
            lower = first
        }
        let ticks = try ExactMath.int64(lower * Int128(grid))
        return MusicalOccurrence(pass: iteration + 1 + pass, ticks: ticks)
    }

    private static let unitsPerFrame = Int128(MusicalTime.ticksPerQuarter) * ExactMath.microsPerSecond

    /// A distant wrap need not fit Int64 for a current-pass target to be valid.
    private static func wrapFrame(_ map: MusicalClockMap, loop: LoopRange) -> Int128 {
        Int128(map.anchor.sample.frame)
            + ExactMath.roundHalfUp(loopUnits(map, from: map.musical.ticks, to: loop.endTicks), unitsPerFrame)
    }

    /// Re-resolve the frozen occurrence, never re-quantize its origin on a new map.
    private static func frame(of occurrence: MusicalOccurrence, musical: MusicalContext,
                              origin: ClockAnchor? = nil, stoppedAt: HostStamp? = nil) throws -> Int64 {
        var pass = occurrence.pass
        var ticks = occurrence.ticks
        if let loop = musical.loop, ticks == loop.endTicks { pass += 1; ticks = loop.startTicks }
        var map = musical.map
        if pass < Int128(map.musical.loopIteration) {
            let origin = try stoppedAt.map { try resumeAnchor(musical, after: $0, origin: origin) } ?? origin
            guard let origin, let position = origin.musical, Int128(position.loopIteration) <= pass else {
                throw ClockMapError.noMusicalAnchor
            }
            map = try MusicalClockMap(anchor: origin, map: map.map, nominalRate: map.nominalRate,
                                      currentSample: map.anchor.sample.generation,
                                      currentTransport: map.musical.transport)
        }
        if pass == Int128(map.musical.loopIteration) { return try map.frame(atTicks: ticks) }
        guard let loop = musical.loop, map.musical.ticks <= loop.endTicks else { throw ClockMapError.noMusicalAnchor }
        let length = loopUnits(map, from: loop.startTicks, to: loop.endTicks)
        let passes = pass - Int128(map.musical.loopIteration) - 1
        let (elapsed, productOverflow) = passes.multipliedReportingOverflow(by: length)
        let (start, startOverflow) = (wrapFrame(map, loop: loop) * unitsPerFrame).addingReportingOverflow(elapsed)
        let offset = loopUnits(map, from: loop.startTicks, to: ticks)
        let (position, positionOverflow) = start.addingReportingOverflow(offset)
        guard !productOverflow, !startOverflow, !positionOverflow else { throw ClockMapError.overflow }
        // Round only the bounded remainder, so half-up rounding cannot double an overflowing numerator.
        return try ExactMath.int64(position / unitsPerFrame
            + ExactMath.roundHalfUp(position % unitsPerFrame, unitsPerFrame))
    }

    private static func resumeAnchor(_ musical: MusicalContext, after stoppedAt: HostStamp,
                                     origin: ClockAnchor?) throws -> ClockAnchor {
        guard let origin, let stopped = origin.musical,
              let resume = musical.resumeAnchor, let position = resume.musical,
              resume.sample.clock == musical.map.anchor.sample.clock,
              resume.sample.generation == musical.map.anchor.sample.generation,
              position.transport == musical.map.musical.transport,
              position.loopIteration == stopped.loopIteration, position.ticks == stopped.ticks,
              resume.host.ticks >= max(stoppedAt.ticks, origin.host.ticks),
              resume.host.ticks <= musical.map.anchor.host.ticks,
              resume.sample.frame >= origin.sample.frame,
              resume.sample.frame <= musical.map.anchor.sample.frame,
              musical.sample.agrees(resume) else {
            throw ClockMapError.noMusicalAnchor
        }
        return resume
    }

    /// Exact signed tempo integral in the clock map's common frame units.
    private static func loopUnits(_ map: MusicalClockMap, from start: Int64, to end: Int64) -> Int128 {
        if end < start { return -loopUnits(map, from: end, to: start) }
        var units: Int128 = 0
        for (index, segment) in map.map.segments.enumerated() {
            let lower = index == 0 ? start : max(start, segment.atTicks)
            let upper = index + 1 < map.map.segments.count ? min(end, map.map.segments[index + 1].atTicks) : end
            if upper > lower {
                units += (Int128(upper) - Int128(lower)) * Int128(segment.microsPerQuarter) * Int128(map.nominalRate)
            }
        }
        return units
    }

    /// `lateness ≤ maxLatenessMs`, exactly: `lateness · 1000 ≤ ms · rate`.
    private static func within(_ lateness: Int128, _ milliseconds: Int, _ rate: Int) -> Bool {
        lateness * 1000 <= Int128(milliseconds) * Int128(rate)
    }

    private mutating func raiseFloor(generation: Generation, frame: Int64) {
        if let floor = horizonFloor, floor.generation == generation, floor.frame >= frame { return }
        horizonFloor = (generation, frame)
    }

    private mutating func finish(_ outcome: TriggerOutcome) -> TriggerOutcome {
        pending.removeValue(forKey: outcome.trigger)
        musicalTargets.removeValue(forKey: outcome.trigger)
        outcomes.append(outcome)
        return outcome
    }
}
