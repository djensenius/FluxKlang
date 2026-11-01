// Control-plane ONLY: this boundary allocates and uses string identities.
// Supply an explicit, immutable prepare-time identity table. No ID is parsed
// into a slot; bindings preserve both identity and declared role. Do not mix
// values prepared with different tables/activation leases.
// Persist the control-plane forms, not these process-local runtime slots/stamps.

enum RuntimeStreamDirection: Hashable { case playback, capture }

/// Control-plane roles, never inferred from an ID's text or prefix.
enum RuntimeIdentity: Hashable {
    case sampleClock(ClockID), musicalClock(ClockID)
    case action(ActionID), trigger(TriggerID)
    case stream(StreamID, direction: RuntimeStreamDirection)
    case context(GenerationSubject), cancelScope(GenerationSubject)
}

enum RuntimePreparationError: Error, Equatable {
    case invalidMapping
    case unmappedIdentity(RuntimeIdentity)
    case undeclaredStream(StreamID)
    case invalidClockDeclarations
    case invalidMusicalStamp
    case invalidDiscontinuity
}

struct RuntimePreparation {
    private let slots: [RuntimeIdentity: UInt32]
    private let primaryClock: ClockID
    private let musicalClock: ClockID?

    /// Explicit bindings must be one-to-one and dense from zero. Repeated roles
    /// are rejected, not overwritten. A clock cannot be both sample and musical;
    /// a stream has one declared direction, per v1 streamRecord.
    init(primaryClock: ClockID, musicalClock: ClockID?,
         bindings: [(RuntimeIdentity, UInt32)]) throws(RuntimePreparationError) {
        guard primaryClock != musicalClock else { throw .invalidClockDeclarations }
        var slots: [RuntimeIdentity: UInt32] = [:]
        var used = Set<UInt32>()
        for (identity, slot) in bindings {
            guard slots[identity] == nil, used.insert(slot).inserted, UInt64(slot) < UInt64(bindings.count) else {
                throw .invalidMapping
            }
            slots[identity] = slot
        }
        self.slots = slots
        self.primaryClock = primaryClock
        self.musicalClock = musicalClock
        _ = try slot(for: .sampleClock(primaryClock))
        if let musicalClock { _ = try slot(for: .musicalClock(musicalClock)) }
        for identity in slots.keys {
            switch identity {
            case .musicalClock(let clock):
                guard clock == musicalClock, slots[.sampleClock(clock)] == nil else {
                    throw .invalidClockDeclarations
                }
            case .stream(let stream, direction: .capture):
                guard slots[.stream(stream, direction: .playback)] == nil else { throw .invalidMapping }
            default: break
            }
        }
    }

    func slot(for identity: RuntimeIdentity) throws(RuntimePreparationError) -> UInt32 {
        guard let slot = slots[identity] else { throw .unmappedIdentity(identity) }
        return slot
    }

    private func streamSlot(_ stream: StreamID) throws(RuntimePreparationError) -> UInt32 {
        guard let slot = slots[.stream(stream, direction: .playback)]
            ?? slots[.stream(stream, direction: .capture)] else {
            throw .undeclaredStream(stream)
        }
        return slot
    }

    func key(_ value: GenerationKey) throws -> RuntimeGenerationKey {
        let slot: UInt32
        // Retagging a validated subject preserves its text; the explicit kind
        // selects the required declared role, never a prefix-based guess.
        switch value.kind {
        case .sampleClock: slot = try self.slot(for: .sampleClock(ClockID(value.subject.rawValue)))
        case .transport, .musicalMap: slot = try self.slot(for: .musicalClock(ClockID(value.subject.rawValue)))
        case .source: slot = try streamSlot(StreamID(value.subject.rawValue))
        case .context: slot = try self.slot(for: .context(value.subject))
        case .cancelScope: slot = try self.slot(for: .cancelScope(value.subject))
        }
        return RuntimeGenerationKey(kind: value.kind, slot: slot)
    }

    func sample(_ value: SampleStamp) throws(RuntimePreparationError) -> RuntimeSampleStamp {
        try RuntimeSampleStamp(clock: slot(for: .sampleClock(value.clock)), generation: UInt64(value.generation.value),
                               frame: value.frame)
    }

    func anchor(_ value: ClockAnchor) throws -> RuntimeClockAnchor {
        if let musical = value.musical {
            guard musical.ticks >= 0 else { throw RuntimePreparationError.invalidMusicalStamp }
            guard musicalClock != nil else { throw RuntimePreparationError.invalidClockDeclarations }
        }
        let musical = value.musical.map {
            RuntimeMusicalStamp(transport: UInt64($0.transport.value), musicalMap: UInt64($0.musicalMap.value),
                                ticks: $0.ticks, loopIteration: $0.loopIteration)
        }
        return try RuntimeClockAnchor(sample: sample(value.sample), host: value.host, musical: musical)
    }

    /// Shape validation is separate from freshness: the scheduler still checks
    /// every captured generation at arrival and dispatch (M4).
    func trigger(_ value: TriggerStamp) throws -> RuntimeTriggerStamp {
        try value.validate(primaryClock: GenerationKey(.sampleClock, primaryClock), musicalClock: musicalClock)
        let requirements = try RuntimeRequirements(value.requires.map {
            try RuntimeGenerationRequirement(key: key($0.key), generation: UInt64($0.generation.value))
        })
        return try RuntimeTriggerStamp(
            id: slot(for: .trigger(value.id)), action: slot(for: .action(value.action)), originHost: value.originHost,
            horizonFrame: value.horizonFrame, requires: requirements, target: value.target,
            latePolicy: value.latePolicy, retroactiveMs: value.retroactiveMs,
            stoppedPolicy: value.stoppedPolicy, loopIteration: value.loopIteration
        )
    }

    func outcome(_ value: TriggerOutcome) throws -> RuntimeTriggerOutcome {
        try value.validateMediaShape()
        let stale: RuntimeStaleDependency?
        switch value.stale {
        case .none: stale = nil
        case .connectionEpoch: stale = .connectionEpoch
        case .hostEpoch: stale = .hostEpoch
        case .generation(let generationKey): stale = try .generation(key(generationKey))
        }
        return try RuntimeTriggerOutcome(
            trigger: slot(for: .trigger(value.trigger)), result: value.result, reason: value.reason, stale: stale,
            assignedFrame: value.assignedFrame, frame: value.frame, startOffsetFrames: value.startOffsetFrames,
            musicalMap: value.musicalMap.map { UInt64($0.value) }
        )
    }

    func discontinuity(_ kind: RuntimeDiscontinuityKind, sample stamp: SampleStamp,
                       frames: UInt32? = nil, stream: StreamID? = nil,
                       host: HostStamp? = nil) throws -> RuntimeDiscontinuity {
        guard frames != 0 else { throw RuntimePreparationError.invalidDiscontinuity }
        switch kind {
        case .clockRestart:
            guard host != nil else { throw RuntimePreparationError.invalidDiscontinuity }
        case .underrun, .overflow:
            guard frames != nil, let stream else { throw RuntimePreparationError.invalidDiscontinuity }
            let direction: RuntimeStreamDirection
            if case .underrun = kind { direction = .playback } else { direction = .capture }
            _ = try slot(for: .stream(stream, direction: direction))
        case .sourceLost, .sourceRestored, .formatChange, .captureStopped:
            guard stream != nil else { throw RuntimePreparationError.invalidDiscontinuity }
        case .sampleJump, .locate, .loopWrap: break
        }
        return try RuntimeDiscontinuity(kind: kind, sample: sample(stamp), frames: frames,
                                        stream: stream.map { try streamSlot($0) }, host: host)
    }
}
