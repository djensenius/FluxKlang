//
//  SpatialPlacementEditor.swift
//  FluxKlang
//
//  The pure placement editing model (#116 PL1): arrow nudges, exact entry,
//  drags and snaps for one source, all through one edit enum so the room
//  plane, the keyboard and VoiceOver adjustable actions agree. No UI, audio or
//  clock: a UI frame never drives anything here.
//

// swiftlint:disable identifier_name
/// The value an edit changes. `x` grows to the right and `y` to the front
/// (front = +y, as in `SpatialLayout`); both lie in `−1…1`. `width` is a
/// stereo source's spread in `0…1`.
enum SpatialEditAxis: String, Hashable, Sendable, CaseIterable {
    case x
    case y
    case width

    static let widthRange: ClosedRange<Double> = 0...1

    var range: ClosedRange<Double> { self == .width ? Self.widthRange : NeutralPoint.range }
}
// swiftlint:enable identifier_name

enum SpatialNudgeDirection: Hashable, Sendable, CaseIterable {
    case decrease
    case increase
}

/// Arrow keys move by `coarse` (0.05); Shift-arrows by `fine` (0.01).
enum SpatialNudgeStep: Hashable, Sendable, CaseIterable {
    case coarse
    case fine

    /// The step in hundredths of a neutral unit.
    var hundredths: Int { self == .coarse ? 5 : 1 }
}

enum SpatialSnapTarget: Hashable, Sendable {
    case centre
    case speaker(SpeakerID)
}

/// Arrow keys on the room plane, which is drawn with the front up.
enum SpatialArrowKey: Hashable, Sendable, CaseIterable {
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
}

/// One placement edit. Every input path (pointer drag, keyboard, VoiceOver or
/// Switch Control) produces one of these and goes through `SpatialPlacementEditor`.
enum SpatialPlacementEdit: Hashable, Sendable {
    /// Moves one axis by a step; the result is clamped to the axis range.
    case nudge(SpatialEditAxis, SpatialNudgeDirection, SpatialNudgeStep)
    /// Sets one axis exactly; an out-of-range or non-finite value is refused, never clamped.
    case setExact(SpatialEditAxis, Double)
    /// A pointer drag's proposed point; it is clamped by the same path as a nudge.
    case drag(proposedX: Double, proposedY: Double)
    /// Moves to a layout speaker's position or to the centre.
    case snap(SpatialSnapTarget)

    /// Arrow keys: up is front (+y), right is +x. `fine` is the Shift modifier.
    static func arrow(_ key: SpatialArrowKey, fine: Bool) -> Self {
        let step: SpatialNudgeStep = fine ? .fine : .coarse
        switch key {
        case .upArrow: return .nudge(.y, .increase, step)
        case .downArrow: return .nudge(.y, .decrease, step)
        case .leftArrow: return .nudge(.x, .decrease, step)
        case .rightArrow: return .nudge(.x, .increase, step)
        }
    }

    /// The increment action of the adjustable X, Y or Width element.
    static func accessibilityIncrement(_ axis: SpatialEditAxis) -> Self {
        .nudge(axis, .increase, .coarse)
    }

    /// The decrement action of the adjustable X, Y or Width element.
    static func accessibilityDecrement(_ axis: SpatialEditAxis) -> Self {
        .nudge(axis, .decrease, .coarse)
    }
}

/// A move offered by the "Move to speaker..." picker and as a VoiceOver custom action.
struct SpatialPlacementAction: Hashable, Sendable {
    let label: String
    let edit: SpatialPlacementEdit
}

/// The placement an edit produces, and whether a nudge or drag proposed a
/// value outside the range that was clamped.
struct SpatialPlacementEditOutcome: Hashable, Sendable {
    let placement: SpatialSourcePlacement
    let clamped: Bool
}

/// Edits one source placement against a layout. A refused edit throws a
/// `SpatialEditingRefusal` and leaves `placement` unchanged.
struct SpatialPlacementEditor: Hashable, Sendable {
    let layout: SpatialLayout
    private(set) var placement: SpatialSourcePlacement

    init(placement: SpatialSourcePlacement, layout: SpatialLayout) {
        self.placement = placement
        self.layout = layout
    }

    /// The speakers in layout order, then the centre.
    var moveActions: [SpatialPlacementAction] {
        layout.speakers.map {
            SpatialPlacementAction(label: "Move to \($0.name ?? $0.id.rawValue)", edit: .snap(.speaker($0.id)))
        } + [SpatialPlacementAction(label: "Move to centre", edit: .snap(.centre))]
    }

    /// The outcome of `edit` without applying it.
    func preview(_ edit: SpatialPlacementEdit) throws(SpatialEditingRefusal) -> SpatialPlacementEditOutcome {
        switch edit {
        case let .nudge(axis, direction, step):
            try requireEditable(axis)
            return try clamped(axis, Self.stepped(value(axis), direction, step))
        case let .setExact(axis, value):
            return try exact(axis, value)
        case let .drag(proposedX, proposedY):
            guard proposedX.isFinite else { throw .nonFiniteValue(.x) }
            guard proposedY.isFinite else { throw .nonFiniteValue(.y) }
            return try clamped(proposedX: proposedX, proposedY: proposedY, proposedWidth: placement.width)
        case let .snap(target):
            return try snapped(target)
        }
    }

    /// Applies `edit`, or throws and changes nothing.
    @discardableResult
    mutating func apply(_ edit: SpatialPlacementEdit) throws(SpatialEditingRefusal) -> SpatialPlacementEditOutcome {
        let outcome = try preview(edit)
        placement = outcome.placement
        return outcome
    }

    /// One step from `value`. A value on the hundredths grid stays on it exactly
    /// (k/100 → (k ± step)/100), so repeated nudges never drift across a spoken
    /// band edge; an off-grid value (from a drag) simply moves by the step.
    static func stepped(_ value: Double, _ direction: SpatialNudgeDirection, _ step: SpatialNudgeStep) -> Double {
        let delta = Double(direction == .increase ? step.hundredths : -step.hundredths)
        let scaled = (value * 100).rounded()
        guard scaled / 100 == value else { return value + delta / 100 }
        return (scaled + delta) / 100
    }

    private func value(_ axis: SpatialEditAxis) -> Double {
        switch axis {
        case .x: placement.position.x
        case .y: placement.position.y
        case .width: placement.width
        }
    }

    private func requireEditable(_ axis: SpatialEditAxis) throws(SpatialEditingRefusal) {
        guard axis != .width || placement.channelCount == 2 else {
            throw .widthRequiresStereo(placement.sourceID)
        }
    }

    private func clamped(_ axis: SpatialEditAxis, _ proposed: Double) throws(SpatialEditingRefusal)
        -> SpatialPlacementEditOutcome {
        try clamped(proposedX: axis == .x ? proposed : placement.position.x,
                    proposedY: axis == .y ? proposed : placement.position.y,
                    proposedWidth: axis == .width ? proposed : placement.width)
    }

    /// The one clamping path shared by nudges and drags. Inputs are finite.
    private func clamped(proposedX: Double, proposedY: Double, proposedWidth: Double) throws(SpatialEditingRefusal)
        -> SpatialPlacementEditOutcome {
        let position = NeutralPoint(clampingFinite: proposedX, y: proposedY)
        let width = min(max(proposedWidth, SpatialEditAxis.widthRange.lowerBound),
                        SpatialEditAxis.widthRange.upperBound)
        let clamped = position.x != proposedX || position.y != proposedY || width != proposedWidth
        return SpatialPlacementEditOutcome(placement: try rebuilt(position: position, width: width), clamped: clamped)
    }

    private func exact(_ axis: SpatialEditAxis, _ value: Double) throws(SpatialEditingRefusal)
        -> SpatialPlacementEditOutcome {
        try requireEditable(axis)
        guard value.isFinite else { throw .nonFiniteValue(axis) }
        guard axis.range.contains(value) else { throw .valueOutOfRange(axis, value) }
        let position: NeutralPoint
        do {
            position = try NeutralPoint(validatingX: axis == .x ? value : placement.position.x,
                                        y: axis == .y ? value : placement.position.y)
        } catch {
            throw .placement(error)
        }
        let width = axis == .width ? value : placement.width
        return SpatialPlacementEditOutcome(placement: try rebuilt(position: position, width: width), clamped: false)
    }

    private func snapped(_ target: SpatialSnapTarget) throws(SpatialEditingRefusal) -> SpatialPlacementEditOutcome {
        let position: NeutralPoint
        switch target {
        case .centre:
            position = NeutralPoint(clampingFinite: 0, y: 0)
        case let .speaker(id):
            guard let speaker = layout.speaker(id) else { throw .unknownSpeaker(id) }
            position = speaker.position
        }
        return SpatialPlacementEditOutcome(placement: try rebuilt(position: position, width: placement.width),
                                           clamped: false)
    }

    /// Zero is stored as +0.0: exact entry and drags may supply −0.0.
    private static func unsignedZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }

    private func rebuilt(position: NeutralPoint, width: Double) throws(SpatialEditingRefusal)
        -> SpatialSourcePlacement {
        let point = NeutralPoint(clampingFinite: Self.unsignedZero(position.x), y: Self.unsignedZero(position.y))
        do {
            return try SpatialSourcePlacement(
                sourceID: placement.sourceID, name: placement.name, position: point, blur: placement.blur,
                width: Self.unsignedZero(width), channelCount: placement.channelCount, evidence: placement.evidence
            )
        } catch {
            throw .placement(error)
        }
    }
}
