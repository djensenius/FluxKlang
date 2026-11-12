//
//  DiscontinuityV1Record+Runtime.swift
//  FluxKlang
//
//  The one bridge from a run-time `RuntimeDiscontinuity` (slots and counts, no names) to the media contract
//  v1 `discontinuityRecord` (#109, #110). Pure and stateless: it proves every name the caller supplies is the
//  one the runtime slot stands for, then builds the record through `DiscontinuityV1Record.make`.
//

extension DiscontinuityV1Record {
    /// Builds the record for `discontinuity`, or throws the first offence in the order
    /// `DiscontinuityV1RuntimeRefusal` documents. The generation and the frame come from `discontinuity.sample`.
    ///
    /// `sampleClock` must be the preparation's sample clock for the stamp's slot, and `stream` the name the
    /// preparation binds to the discontinuity's stream slot, in a direction the kind accepts (`underrun`
    /// playback; `overflow` and `captureStopped` capture; every other kind either). A stream slot always needs
    /// its name. `clockRestart`, `sampleJump`, `locate` and `loopWrap` carry no stream in the v1 record: a slot
    /// on them (`BackingClipVoice` emits `locate` and `loopWrap` with one) is checked and then not recorded.
    /// `frames` is required on `underrun` and `overflow` and refused elsewhere; `host` is required on
    /// `clockRestart` and ignored elsewhere (the v1 record keeps host ticks only there). A `frames` of 0 is
    /// passed on so the record's own range check refuses it; a `UInt32` cannot exceed the schema maximum.
    /// Trace-level rules (the generation is current, a stream is declared in the trace) stay the caller's.
    static func make(_ discontinuity: RuntimeDiscontinuity, preparation: RuntimePreparation, sampleClock: ClockID,
                     stream: StreamID?, seq: Int, note: String? = nil) throws(DiscontinuityV1RuntimeRefusal)
        -> DiscontinuityV1Record {
        let sample = discontinuity.sample
        let kind = discontinuity.kind
        guard let mappedClock = try? preparation.slot(for: .sampleClock(sampleClock)) else {
            throw .sampleClockNotMapped(sampleClock)
        }
        guard mappedClock == sample.clock else {
            throw .sampleClockSlotMismatch(runtime: sample.clock, mapped: mappedClock)
        }
        guard let rawGeneration = Int(exactly: sample.generation), let generation = try? Generation(rawGeneration)
        else { throw .generationOutOfRange(sample.generation) }
        let name = try checkedStream(kind, slot: discontinuity.stream, name: stream, preparation: preparation)
        let frames = try checkedFrames(kind, frames: discontinuity.frames)
        let event = try mappedEvent(kind, stream: name, frames: frames, host: discontinuity.host)
        do {
            return try make(event, sampleClock: sampleClock, generation: generation, frame: sample.frame, seq: seq,
                            note: note)
        } catch {
            throw .record(error)
        }
    }

    /// Check 5 and the exhaustive kind mapping; no `default`, so a new kind fails to compile.
    private static func mappedEvent(_ kind: RuntimeDiscontinuityKind, stream name: StreamID?, frames: Int64,
                                    host: HostStamp?) throws(DiscontinuityV1RuntimeRefusal) -> Event {
        if let event = try streamlessEvent(kind, host: host) { return event }
        guard let name, let event = streamEvent(kind, name, frames: frames) else {
            throw .streamRequired(type: kind.contractV1Type)
        }
        return event
    }

    /// The kinds whose v1 record has no stream; `nil` for the others.
    private static func streamlessEvent(_ kind: RuntimeDiscontinuityKind,
                                        host: HostStamp?) throws(DiscontinuityV1RuntimeRefusal) -> Event? {
        switch kind {
        case .clockRestart(let previousFrame):
            guard let host else { throw .hostMissing }
            return .clockRestart(hostTicks: host.ticks, previousFrame: previousFrame)
        case .sampleJump: return .sampleJump
        case .locate: return .locate
        case .loopWrap: return .loopWrap
        case .underrun, .overflow, .sourceLost, .sourceRestored, .formatChange, .captureStopped: return nil
        }
    }

    /// The kinds whose v1 record carries `name`; `nil` for the others.
    private static func streamEvent(_ kind: RuntimeDiscontinuityKind, _ name: StreamID, frames: Int64) -> Event? {
        switch kind {
        case .underrun: .underrun(name, frames: frames)
        case .overflow: .overflow(name, frames: frames)
        case .sourceLost: .sourceLost(name)
        case .sourceRestored: .sourceRestored(name)
        case .formatChange: .formatChange(name)
        case .captureStopped(.diskFull): .captureStopped(name, reason: .diskFull)
        case .captureStopped(.deviceLost): .captureStopped(name, reason: .deviceLost)
        case .clockRestart, .sampleJump, .locate, .loopWrap: nil
        }
    }

    /// Check 3: the caller's name and the runtime slot agree, and the preparation binds the name to that slot.
    private static func checkedStream(_ kind: RuntimeDiscontinuityKind, slot: UInt32?, name: StreamID?,
                                      preparation: RuntimePreparation) throws(DiscontinuityV1RuntimeRefusal)
        -> StreamID? {
        switch (slot, name) {
        case (nil, nil):
            if kind.recordsStream { throw .streamRequired(type: kind.contractV1Type) }
            return nil
        case (let slot?, nil): throw .streamNameMissing(slot: slot)
        case (nil, let name?): throw .streamSlotMissing(name)
        case (let slot?, let name?):
            let mapped = kind.streamDirections.lazy
                .compactMap { try? preparation.slot(for: .stream(name, direction: $0)) }.first
            guard let mapped else { throw .streamNotDeclared(name) }
            guard mapped == slot else { throw .streamSlotMismatch(name, runtime: slot, mapped: mapped) }
            return kind.recordsStream ? name : nil
        }
    }

    /// Check 4: `underrun` and `overflow` need a count, every other kind has none.
    private static func checkedFrames(_ kind: RuntimeDiscontinuityKind,
                                      frames: UInt32?) throws(DiscontinuityV1RuntimeRefusal) -> Int64 {
        switch (kind.needsFrames, frames) {
        case (true, let frames?): return Int64(frames)
        case (true, nil): throw .framesMissing(type: kind.contractV1Type)
        case (false, let frames?): throw .framesUnexpected(type: kind.contractV1Type, frames: frames)
        case (false, nil): return 0
        }
    }
}

private extension RuntimeDiscontinuityKind {
    /// The schema's `type`; no `default`, so a new kind fails to compile here.
    var contractV1Type: String {
        switch self {
        case .clockRestart: "clockRestart"
        case .sampleJump: "sampleJump"
        case .underrun: "underrun"
        case .overflow: "overflow"
        case .sourceLost: "sourceLost"
        case .sourceRestored: "sourceRestored"
        case .locate: "locate"
        case .loopWrap: "loopWrap"
        case .formatChange: "formatChange"
        case .captureStopped: "captureStopped"
        }
    }

    /// Whether the v1 record carries a stream for this kind.
    var recordsStream: Bool {
        switch self {
        case .underrun, .overflow, .sourceLost, .sourceRestored, .formatChange, .captureStopped: true
        case .clockRestart, .sampleJump, .locate, .loopWrap: false
        }
    }

    var needsFrames: Bool {
        switch self {
        case .underrun, .overflow: true
        case .clockRestart, .sampleJump, .sourceLost, .sourceRestored, .locate, .loopWrap, .formatChange,
             .captureStopped: false
        }
    }

    /// The directions the preparation may declare the stream in.
    var streamDirections: [RuntimeStreamDirection] {
        switch self {
        case .underrun: [.playback]
        case .overflow, .captureStopped: [.capture]
        case .clockRestart, .sampleJump, .sourceLost, .sourceRestored, .locate, .loopWrap, .formatChange:
            [.playback, .capture]
        }
    }
}
