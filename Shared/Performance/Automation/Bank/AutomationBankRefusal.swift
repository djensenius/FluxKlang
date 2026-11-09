//
//  AutomationBankRefusal.swift
//  FluxKlang
//
//  Typed refusals of the automation bank (#108, slice AUB1). A refused call returns nothing and leaves the bank
//  exactly as it was.
//

/// Why the bank refused to add or remove a lane, render a window or route a gesture. When several checks hold at
/// once, the first of these orders is reported:
/// - `add`: `duplicateLane`, then `laneLimitReached`, then `laneAlreadyRendered`.
/// - `render`: `invalidWindow`, then `windowTooLong`, then lane by lane in the byte order of the parameter ids: the
///   step's own refusal (`lane`), then `laneNotAtWindowEnd`, then `tooManyEvents`. The first refusal ends the render.
/// - `perform`: `parameterNotInBank`, then the lane's refusal (`lane`).
enum AutomationBankRefusal: Error, Equatable, Sendable {
    /// The window `[start, end)` is empty or reversed.
    case invalidWindow(start: Int64, end: Int64)
    /// The window spans more than `limit` frames, or its length overflows.
    case windowTooLong(start: Int64, end: Int64, limit: Int64)
    /// A lane for this parameter is already in the bank. Replacing one is `remove`, then `add`.
    case duplicateLane(ParameterID)
    /// The bank already holds `limit` lanes.
    case laneLimitReached(limit: Int)
    /// The renderer has already rendered. Reset it first, so that all lanes start on the same window.
    case laneAlreadyRendered(ParameterID)
    /// No lane in the bank is for this parameter.
    case parameterNotInBank(ParameterID)
    /// The lane refused: the step threw during a render, or the gesture was refused.
    case lane(parameter: ParameterID, refusal: AutomationRenderRefusal)
    /// The step returned, but the lane's cursor is not the window end (`got` is nil if the lane has no cursor).
    case laneNotAtWindowEnd(parameter: ParameterID, expected: Int64, got: Int64?)
    /// The lanes together hold more than `limit` events for this window. Nothing is truncated: the caller splits
    /// the window.
    case tooManyEvents(limit: Int)
}
