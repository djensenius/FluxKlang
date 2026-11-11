//
//  MIDIClipPlacement.swift
//  FluxKlang
//
//  A clip placed on the musical timeline (#112 CL1), with an optional clip
//  loop, and its pure frame-window query. Positions stay in musical ticks; frames
//  come only from `MusicalClockMap.frame(atTicks:)`, which integrates the tempo
//  map and rounds half-up (`floor(x + ½)`) once at the final frame (§5.2), so
//  playback follows every tempo change and no rounding accumulates.
//
//  Passes: pass 0 plays clip ticks `[0, E)`, where `E` is the loop end (or the
//  clip length without a loop). Pass k ≥ 1 replays the loop `[S, E)` shifted by
//  `k · (E − S)` ticks. A note crossing the loop end is cut: its Note Off is at
//  the loop end, never wrapped. Items at or after `E` do not play while looping.
//

/// One scheduled point of a pass, in clip ticks.
struct MIDIClipPoint: Equatable, Sendable {
    /// Same-frame order: Note Off, then Note On and other events (each by pass, onset tick, authoring order).
    enum Kind: Int, Sendable { case noteOff = 0, onset = 1 }

    let ticks: Int64
    let kind: Kind
    let item: Int
    /// The note's onset tick in the same pass (equal to `ticks` for an onset).
    let onsetTicks: Int64
    let message: MIDI1Semantic

    fileprivate init(ticks: Int64, kind: Kind, item: Int, onsetTicks: Int64, message: MIDI1Semantic) {
        self.ticks = ticks
        self.kind = kind
        self.item = item
        self.onsetTicks = onsetTicks
        self.message = message
    }
}

/// One emitted clip event: `pass` is the clip loop iteration, `item` the authoring index.
struct MIDIClipEvent: Equatable, Sendable {
    let frame: Int64
    let pass: Int64
    let item: Int
    let message: MIDI1Semantic
}

/// The live generations a clock map must match before it is used. Mirrors `ClockGenerationSnapshot`, which the
/// metronome takes directly since #108 GU1b-1; replacing this mirror with it is a follow-up (GU1b-2).
struct MIDIClipGenerations: Hashable, Sendable {
    let sample: Generation
    let transport: Generation
    let musicalMap: Generation
}

struct MIDIClipPlacement: Equatable, Sendable {
    /// The longest window one query covers, in frames.
    static let maximumWindowFrames: Int64 = 1 << 20
    /// The most events one query returns; a fuller window is refused, never truncated.
    static let maximumEvents = 4096

    private(set) var clip: MIDIClip
    /// The timeline tick of clip tick 0.
    private(set) var startTicks: Int64
    /// The clip loop in clip ticks, if any.
    private(set) var loop: LoopRange?
    private(set) var firstPass: [MIDIClipPoint]
    private(set) var repeatPass: [MIDIClipPoint]

    private init(clip: MIDIClip, startTicks: Int64, loop: LoopRange?) {
        self.clip = clip
        self.startTicks = startTicks
        self.loop = loop
        let passEnd = loop?.endTicks ?? clip.lengthTicks
        firstPass = Self.points(of: clip, from: 0, to: passEnd)
        repeatPass = loop.map { Self.points(of: clip, from: $0.startTicks, to: $0.endTicks) } ?? []
    }

    /// Places `clip` with tick 0 at timeline `startTicks`, looping `[loop.startTicks, loop.endTicks)` if given.
    static func make(clip: MIDIClip, startTicks: Int64, loop: LoopRange? = nil,
                     timePolicy: MediaTimePolicy = .tempoFollowing) throws(MIDIClipRefusal) -> MIDIClipPlacement {
        guard timePolicy == .tempoFollowing else { throw .unsupportedTimePolicy(timePolicy) }
        guard startTicks >= 0, startTicks <= Int64.max - clip.lengthTicks else { throw .startOutOfRange(startTicks) }
        if let loop, loop.endTicks > clip.lengthTicks {
            throw .loopOutsideClip(startTicks: loop.startTicks, endTicks: loop.endTicks,
                                   lengthTicks: clip.lengthTicks)
        }
        return MIDIClipPlacement(clip: clip, startTicks: startTicks, loop: loop)
    }

    /// Onsets in `[from, to)` and their Note Offs, cut at `to`, sorted by tick.
    private static func points(of clip: MIDIClip, from: Int64, to: Int64) -> [MIDIClipPoint] {
        var points: [MIDIClipPoint] = []
        for (index, item) in clip.items.enumerated() {
            switch item {
            case .note(let note):
                guard note.startTicks >= from, note.startTicks < to else { continue }
                points.append(MIDIClipPoint(
                    ticks: note.startTicks, kind: .onset, item: index, onsetTicks: note.startTicks,
                    message: .noteOn(channel: note.channel, note: note.note, velocity: note.velocity)
                ))
                points.append(MIDIClipPoint(
                    ticks: min(note.endTicks, to), kind: .noteOff, item: index, onsetTicks: note.startTicks,
                    message: .noteOff(channel: note.channel, note: note.note, velocity: note.releaseVelocity)
                ))
            case let .event(ticks, message):
                guard ticks >= from, ticks < to else { continue }
                points.append(MIDIClipPoint(ticks: ticks, kind: .onset, item: index, onsetTicks: ticks,
                                            message: message))
            }
        }
        return points.sorted { ($0.ticks, $0.kind.rawValue, $0.item) < ($1.ticks, $1.kind.rawValue, $1.item) }
    }

    /// Refuses a clock map whose sample, transport or tempo map generation is not live.
    static func validate(_ clock: MusicalClockMap, current: MIDIClipGenerations) throws(MIDIClipRefusal) {
        guard clock.anchor.sample.generation == current.sample else { throw .clock(.staleSampleGeneration) }
        guard clock.musical.transport == current.transport else { throw .clock(.staleTransport) }
        guard clock.map.revision == current.musicalMap else { throw .staleMusicalMap }
    }

    /// Every scheduled event whose frame lies in `[start, end)` through `clock`, ordered by frame, then Note Offs
    /// before Note Ons and other events, then pass, onset tick and authoring order. A note whose On and Off round
    /// to one frame has its Off right after its own On, before any later-starting note in that frame. Adjacent
    /// windows on one map split the events exactly. Nothing is cached. With a `floor`, events of timeline ticks
    /// below it are left out before the event limit is checked (a rebound scheduler's already-played ticks, #112
    /// CL3); the default `nil` leaves out nothing.
    func events(from start: Int64, to end: Int64, clock: MusicalClockMap, current: MIDIClipGenerations,
                floor: Int64? = nil) throws(MIDIClipRefusal) -> [MIDIClipEvent] {
        guard start <= end else { throw .invalidWindow(start: start, end: end) }
        let (span, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, span <= Self.maximumWindowFrames else {
            throw .windowTooLong(start: start, end: end, limit: Self.maximumWindowFrames)
        }
        try Self.validate(clock, current: current)
        guard start < end else { return [] }
        return try mapped { () throws(ClockMapError) in try collect(from: start, to: end, floor: floor, clock: clock) }
    }

    private func collect(from start: Int64, to end: Int64, floor: Int64?,
                         clock: MusicalClockMap) throws(ClockMapError) -> [MIDIClipEvent]? {
        // By monotonicity, a tick's frame lies in [start, end) exactly when the tick lies in [low, high). The floor
        // raises `low`, so ticks below it are never collected and never count toward the event limit.
        var low = Int128(try Self.firstTick(atOrAfterFrame: start, clock: clock))
        if let floor { low = max(low, Int128(floor)) }
        let high = Int128(try Self.firstTick(atOrAfterFrame: end, clock: clock))
        guard let passes = passes(from: low - Int128(startTicks), to: high - Int128(startTicks)) else { return [] }
        var ranked: [Ranked] = []
        for pass in passes {
            let points = pass == 0 ? firstPass : repeatPass
            let offset = Int128(startTicks) + Int128(pass) * Int128(loopLength)
            var index = points.partitioningIndex { offset + Int128($0.ticks) >= low }
            while index < points.count, offset + Int128(points[index].ticks) < high {
                guard ranked.count < Self.maximumEvents else { return nil }
                let point = points[index]
                let frame = try clock.frame(atTicks: ExactMath.int64(offset + Int128(point.ticks)))
                // A note whose On and Off round to one frame keeps its Off right after its own On.
                var collapsed = false
                if point.kind == .noteOff {
                    collapsed = try clock.frame(atTicks: ExactMath.int64(offset + Int128(point.onsetTicks))) == frame
                }
                let rank = collapsed ? MIDIClipPoint.Kind.onset.rawValue : point.kind.rawValue
                ranked.append(Ranked(rank: rank, onset: point.onsetTicks, after: collapsed, event: MIDIClipEvent(
                    frame: frame, pass: pass, item: point.item, message: point.message
                )))
                index += 1
            }
        }
        return ranked.sorted { lhs, rhs in
            (lhs.event.frame, lhs.rank, lhs.event.pass, lhs.onset, lhs.event.item, lhs.after ? 1 : 0)
                < (rhs.event.frame, rhs.rank, rhs.event.pass, rhs.onset, rhs.event.item, rhs.after ? 1 : 0)
        }.map(\.event)
    }

    /// An event with its same-frame rank and its note's onset tick in the pass; `after` puts a collapsed note's
    /// Off right after its own On.
    private struct Ranked {
        let rank: Int
        let onset: Int64
        let after: Bool
        let event: MIDIClipEvent
    }

    private var loopLength: Int64 { loop.map { $0.endTicks - $0.startTicks } ?? 0 }

    /// The passes with a point in clip-relative ticks `[low, high)`. Pass k ≥ 1 holds points in
    /// `[S + kL, E + kL]`, pass 0 in `[0, E]`. Middle passes lie wholly inside the window, so with a
    /// nonempty repeat pass the event bound also bounds the walk.
    private func passes(from low: Int128, to high: Int128) -> ClosedRange<Int64>? {
        guard high > 0 else { return nil }
        guard let loop, !repeatPass.isEmpty else {
            return low <= Int128(loop?.endTicks ?? clip.lengthTicks) ? 0...0 : nil
        }
        let length = Int128(loopLength)
        let first = max(0, ExactMath.ceilDiv(low - Int128(loop.endTicks), length))
        let last = max(0, ExactMath.ceilDiv(high - Int128(loop.startTicks), length) - 1)
        guard first <= last, let lower = Int64(exactly: first) else { return nil }
        return lower...(Int64(exactly: last) ?? Int64.max)
    }

    /// The first tick whose frame is at or after `frame`. The exact tick of `frame` rounds to at least
    /// `frame`; earlier ticks within the half-frame rounding reach are found by stepping back.
    static func firstTick(atOrAfterFrame frame: Int64, clock: MusicalClockMap) throws(ClockMapError) -> Int64 {
        let exact = clock.exactTicks(atFrame: frame)
        var tick = try ExactMath.int64(ExactMath.ceilDiv(exact.numerator, exact.denominator))
        while true {
            let (previous, overflow) = tick.subtractingReportingOverflow(1)
            guard !overflow else { throw .overflow }
            guard try clock.frame(atTicks: previous) >= frame else { return tick }
            tick = previous
        }
    }

    private func mapped(_ body: () throws(ClockMapError) -> [MIDIClipEvent]?) throws(MIDIClipRefusal)
        -> [MIDIClipEvent] {
        let events: [MIDIClipEvent]?
        do {
            events = try body()
        } catch {
            throw .clock(error)
        }
        guard let events else { throw .tooManyEvents(limit: Self.maximumEvents) }
        return events
    }
}

private extension Array {
    /// The first index whose element satisfies `belongs`, for a predicate false then true along the array.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
