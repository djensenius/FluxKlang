//
//  AutomationBank.swift
//  FluxKlang
//
//  A bank of automation block renderers, one per parameter, rendered window by window in lockstep (#108, slice AUB1).
//

/// Up to 64 `AutomationBlockRenderer`s, one per `ParameterID`, kept sorted by the UTF-8 bytes of the id. One
/// `render(from:to:using:)` renders all of the lanes over the same window and returns one list of parameter-tagged
/// events, ordered by frame, then by the parameter id bytes, then by the lane's own emission order. A refused call
/// changes nothing: the bank is equal to what it was before the call.
///
/// A pure value. It reads no time, drives no audio unit and has no caller yet; an adapter that turns
/// `AutomationParameterEvent`s into host ramps, and a scheduler that owns the windows, are outstanding.
/// CONTROL THREAD ONLY: a render allocates (copies, a sorted list), so it must not run on the audio thread.
///
/// Lanes stay in lockstep: `add` refuses a renderer that has already rendered, `render` advances all lanes or none,
/// and `reset()` rewinds all lanes. A lane added later therefore joins at the next window start. `remove` does not
/// cancel a host ramp the lane already emitted, and no idle timeout releases a touch the caller leaves held.
struct AutomationBank: Hashable, Sendable {
    /// Renders one lane over `[start, end)` and returns its events. The caller builds it around the tempo map and the
    /// generations, so the bank does not name them: a typical step calls `renderer.render(from:to:clock:current:)`.
    /// The bank calls it at most once per lane per window, in the byte order of the parameter ids, on a copy of
    /// the lane, and then requires that the copy's cursor is `end`. Precondition: a step renders the renderer it is
    /// handed. One that assigns a different renderer to it breaks the order and the distinctness of the lanes, and
    /// the bank does not detect that.
    typealias Step = (inout AutomationBlockRenderer, Int64, Int64) throws(AutomationRenderRefusal)
        -> [AutomationRampEvent]

    /// The most lanes a bank holds. The 65th `add` is refused.
    static let maximumLanes = 64
    /// The most events one window may return across all lanes, the renderer's own per-lane limit. A window with more
    /// is refused, not truncated.
    static let maximumEvents = AutomationBlockRenderer.maximumEvents

    /// The lanes, sorted by the UTF-8 bytes of their parameter ids, without a repeated id.
    private(set) var renderers: [AutomationBlockRenderer]

    init() {
        renderers = []
    }

    var count: Int { renderers.count }

    /// The parameter ids in the order lanes render: ascending by UTF-8 bytes.
    var parameters: [ParameterID] { renderers.map(\.arbiter.lane.parameter) }

    func renderer(for parameter: ParameterID) -> AutomationBlockRenderer? {
        let place = locate(parameter)
        return place.found ? renderers[place.slot] : nil
    }

    /// Adds a lane that has not rendered. Refused, in this order: a lane for the parameter is already in the bank,
    /// the bank holds 64 lanes, the renderer has already rendered (`reset()` it first).
    mutating func add(_ renderer: AutomationBlockRenderer) throws(AutomationBankRefusal) {
        let parameter = renderer.arbiter.lane.parameter
        let place = locate(parameter)
        guard !place.found else { throw .duplicateLane(parameter) }
        guard renderers.count < Self.maximumLanes else { throw .laneLimitReached(limit: Self.maximumLanes) }
        guard renderer.cursor == nil else { throw .laneAlreadyRendered(parameter) }
        renderers.insert(renderer, at: place.slot)
    }

    /// Removes the lane for `parameter` and returns it with its cursor and arbiter. It works at any time and does not
    /// cancel a host ramp the lane already emitted.
    @discardableResult
    mutating func remove(_ parameter: ParameterID) throws(AutomationBankRefusal) -> AutomationBlockRenderer {
        let place = locate(parameter)
        guard place.found else { throw .parameterNotInBank(parameter) }
        return renderers.remove(at: place.slot)
    }

    /// Renders `[start, end)` for all of the lanes, in byte order, each on a copy, and publishes them with one
    /// assignment after the last one. An empty bank returns no events and keeps no position. Refused with the first
    /// refusal that holds, before any later lane renders; see `AutomationBankRefusal` for the order.
    mutating func render(from start: Int64, to end: Int64,
                         using step: Step) throws(AutomationBankRefusal) -> [AutomationParameterEvent] {
        try Self.checkedWindow(start: start, end: end)
        var copies = renderers
        var tagged: [Tagged] = []
        tagged.reserveCapacity(Self.maximumEvents)
        for rank in copies.indices {
            let events = try Self.advance(&copies, rank: rank, from: start, to: end, using: step)
            try Self.collect(events, of: copies[rank].arbiter.lane.parameter, rank: rank, into: &tagged)
        }
        tagged.sort { ($0.frame, $0.rank, $0.index) < ($1.frame, $1.rank, $1.index) }
        renderers = copies
        return tagged.map(\.value)
    }

    /// Applies a gesture to the lane for `parameter` at that lane's position, on a copy written back on success. Its
    /// effect on the output starts with the next window. The other lanes are untouched. Refused if the parameter has
    /// no lane, or with the lane's own refusal (the lane has not rendered, or the touch rules refuse the gesture).
    mutating func perform(_ gesture: AutomationRenderGesture,
                          on parameter: ParameterID) throws(AutomationBankRefusal) -> ArbitrationResult {
        let place = locate(parameter)
        guard place.found else { throw .parameterNotInBank(parameter) }
        var copy = renderers[place.slot]
        let result: ArbitrationResult
        do throws(AutomationRenderRefusal) {
            result = try copy.perform(gesture)
        } catch {
            throw .lane(parameter: parameter, refusal: error)
        }
        renderers[place.slot] = copy
        return result
    }

    /// Rewinds all lanes. Lanes, arbiters and loops stay; the next render may start anywhere and binds to its own
    /// generations. Call it after a clock revision change or a transport jump.
    mutating func reset() {
        for slot in renderers.indices {
            renderers[slot].reset()
        }
    }
}

private extension AutomationBank {
    /// An event with its sort key: the frame, the lane's rank in byte order, and its index in the lane's emission.
    struct Tagged {
        let frame: Int64
        let rank: Int
        let index: Int
        let value: AutomationParameterEvent
    }

    static func precedes(_ lhs: ParameterID, _ rhs: ParameterID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    static func matches(_ lhs: ParameterID, _ rhs: ParameterID) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    /// The slot of `parameter` by binary search over the byte order, and whether a lane is there; if not, the slot
    /// where it would be inserted.
    func locate(_ parameter: ParameterID) -> (slot: Int, found: Bool) {
        var low = 0
        var high = renderers.count
        while low < high {
            let middle = low + (high - low) / 2
            let probe = renderers[middle].arbiter.lane.parameter
            if Self.matches(probe, parameter) { return (middle, true) }
            if Self.precedes(probe, parameter) { low = middle + 1 } else { high = middle }
        }
        return (low, false)
    }

    static func checkedWindow(start: Int64, end: Int64) throws(AutomationBankRefusal) {
        guard start < end else { throw .invalidWindow(start: start, end: end) }
        let limit = AutomationBlockRenderer.maximumBlockFrames
        let (span, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, span <= limit else { throw .windowTooLong(start: start, end: end, limit: limit) }
    }

    /// Runs the step on the lane's copy, then checks that the copy reached `end`.
    static func advance(_ copies: inout [AutomationBlockRenderer], rank: Int, from start: Int64, to end: Int64,
                        using step: Step) throws(AutomationBankRefusal) -> [AutomationRampEvent] {
        let parameter = copies[rank].arbiter.lane.parameter
        let events: [AutomationRampEvent]
        do throws(AutomationRenderRefusal) {
            events = try step(&copies[rank], start, end)
        } catch {
            throw .lane(parameter: parameter, refusal: error)
        }
        let cursor = copies[rank].cursor
        guard cursor == end else { throw .laneNotAtWindowEnd(parameter: parameter, expected: end, got: cursor) }
        return events
    }

    /// Tags one lane's events, refusing before any of them is appended if the total would pass the limit.
    static func collect(_ events: [AutomationRampEvent], of parameter: ParameterID, rank: Int,
                        into tagged: inout [Tagged]) throws(AutomationBankRefusal) {
        guard events.count <= Self.maximumEvents - tagged.count else {
            throw .tooManyEvents(limit: Self.maximumEvents)
        }
        for (index, event) in events.enumerated() {
            let value = AutomationParameterEvent(parameter: parameter, event: event)
            tagged.append(Tagged(frame: event.frame, rank: rank, index: index, value: value))
        }
    }
}
