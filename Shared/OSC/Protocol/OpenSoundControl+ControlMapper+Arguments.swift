//
//  OpenSoundControl+ControlMapper+Arguments.swift
//  FluxKlang
//
//  Argument handling of the neutral OSC namespace mapper (#89, slice O2a).
//  Order within one message: count, then types by ascending index, then
//  finiteness, then ranges. Numbers are `float32` or `int32`, converted with
//  `Double(_)` (exact). Nothing is clamped, rounded or range-checked against
//  the catalog: admission does that against the current catalog.
//

extension OpenSoundControl.ControlMapper {
    private typealias Refusal = OpenSoundControl.NamespaceRefusal
    private typealias Argument = OpenSoundControl.Argument

    /// Check 10: builds the operation for a resolved route.
    static func operation(
        for route: OpenSoundControl.MappedRoute, arguments: [OpenSoundControl.Argument]
    ) throws(OpenSoundControl.NamespaceRefusal) -> CommandOperation {
        switch route {
        case .set(let target):
            try requireCount(arguments, minimum: 1, maximum: 1)
            let value = try number(arguments[0], at: 0)
            try requireFinite(value, at: 0)
            return .set(target.id, ParameterValue(value: value, unit: target.unit))
        case .ramp(let target):
            try requireCount(arguments, minimum: 2, maximum: 2)
            let value = try number(arguments[0], at: 0)
            let milliseconds = try rampMilliseconds(arguments[1])
            try requireFinite(value, at: 0)
            try requireRampRange(milliseconds)
            return .ramp(target.id, ParameterValue(value: value, unit: target.unit), milliseconds: Int(milliseconds))
        case .trigger(let id):
            try requireTrigger(arguments)
            return .trigger(id)
        case .transport(let verb):
            return try transportOperation(verb, arguments: arguments)
        }
    }

    private static func transportOperation(
        _ verb: OpenSoundControl.TransportVerb, arguments: [Argument]
    ) throws(Refusal) -> CommandOperation {
        switch verb {
        case .start:
            try requireCount(arguments, minimum: 0, maximum: 0)
            return .start
        case .stop:
            try requireCount(arguments, minimum: 0, maximum: 0)
            return .stop
        case .locate:
            try requireCount(arguments, minimum: 1, maximum: 1)
            let ticks = try tickCount(arguments[0])
            guard ticks >= 0 else { throw .negativeTicks }
            return .locate(ticks: ticks)
        }
    }

    private static func requireCount(
        _ arguments: [Argument], minimum: Int, maximum: Int
    ) throws(Refusal) {
        guard arguments.count >= minimum, arguments.count <= maximum else {
            throw .wrongArgumentCount(minimum: minimum, maximum: maximum, got: arguments.count)
        }
    }

    /// Zero arguments, or exactly one `impulse`. A press and release pair is never guessed here.
    private static func requireTrigger(_ arguments: [Argument]) throws(Refusal) {
        try requireCount(arguments, minimum: 0, maximum: 1)
        if let argument = arguments.first, argument != .impulse {
            throw .unsupportedArgument(index: 0, typeTag: argument.typeTag)
        }
    }

    private static func number(_ argument: Argument, at index: Int) throws(Refusal) -> Double {
        if case .float32(let value) = argument { return Double(value) }
        if case .int32(let value) = argument { return Double(value) }
        throw .unsupportedArgument(index: index, typeTag: argument.typeTag)
    }

    private static func rampMilliseconds(_ argument: Argument) throws(Refusal) -> Int32 {
        if case .int32(let value) = argument { return value }
        throw .unsupportedArgument(index: 1, typeTag: argument.typeTag)
    }

    private static func tickCount(_ argument: Argument) throws(Refusal) -> Int64 {
        if case .int32(let value) = argument { return Int64(value) }
        if case .int64(let value) = argument { return value }
        throw .unsupportedArgument(index: 0, typeTag: argument.typeTag)
    }

    private static func requireFinite(_ value: Double, at index: Int) throws(Refusal) {
        guard value.isFinite else { throw .nonFiniteValue(index: index) }
    }

    private static func requireRampRange(_ milliseconds: Int32) throws(Refusal) {
        let limit = OpenSoundControl.NamespaceLimits.maximumRampMilliseconds
        guard milliseconds >= 0, Int(milliseconds) <= limit else {
            throw .rampMillisecondsOutOfRange(Int(milliseconds))
        }
    }
}
