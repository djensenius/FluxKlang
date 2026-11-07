//
//  PerformNumericEntry.swift
//  FluxKlang
//
//  Numeric entry for a perform cell (#102 P1): clamps to range and ceiling and says so, never rounds, and checks
//  every result against the real `ParameterDescriptor.check`.
//

enum PerformClampReason: Equatable, Sendable {
    case belowRange
    case aboveRange
    case aboveCeiling
}

/// Why a typed value is refused. Nothing is applied or rounded.
enum PerformEntryRefusal: Error, Equatable, Sendable {
    /// The typed value or the extra ceiling is NaN or infinite.
    case nonFinite
    case unitMismatch(expected: ParameterUnit, found: ParameterUnit)
    /// A stepped parameter takes whole numbers only; the value is never rounded.
    case notIntegral(Double)
    /// The clamped or applied value fails `ParameterDescriptor.check`: the limits cannot hold any valid value.
    case inconsistent(ParameterValueError)
}

enum PerformEntryResult: Equatable, Sendable {
    /// The typed value, unchanged.
    case applied(Double)
    /// The value that will be applied and why, with the sentence to show ("Clamped to ceiling 0 dB").
    case clamped(Double, reason: PerformClampReason, message: String)
    case refused(PerformEntryRefusal)
}

enum PerformNumericEntry {
    /// Resolves `typed`, entered in `unit`, against the descriptor and an optional extra ceiling (a lowered ceiling
    /// from a binding or a group). Checks in order: non-finite, unit, stepped integrality, then clamping to
    /// `lower...min(ceiling ?? upper, extraCeiling ?? upper)`. The result is re-checked by the descriptor.
    static func resolve(_ typed: Double, unit: ParameterUnit, descriptor: ParameterDescriptor,
                        extraCeiling: Double? = nil) -> PerformEntryResult {
        let fields = descriptor.fields
        guard typed.isFinite, extraCeiling.map(\.isFinite) ?? true else { return .refused(.nonFinite) }
        guard unit == fields.unit else { return .refused(.unitMismatch(expected: fields.unit, found: unit)) }
        if fields.curve == .stepped, typed.rounded() != typed { return .refused(.notIntegral(typed)) }
        let limit = min(fields.ceiling ?? fields.upper, extraCeiling ?? fields.upper)
        var value = typed
        var reason: PerformClampReason?
        if typed < fields.lower {
            value = fields.lower
            reason = .belowRange
        } else if typed > limit {
            value = limit
            reason = limit < fields.upper ? .aboveCeiling : .aboveRange
        }
        do {
            try descriptor.check(ParameterValue(value: value, unit: unit), ceiling: extraCeiling)
        } catch {
            return .refused(.inconsistent(error))
        }
        guard let reason else { return .applied(value) }
        let message = "Clamped to \(reason.word) \(PerformNumberText.text(value))\(PerformNumberText.symbol(of: unit))"
        return .clamped(value, reason: reason, message: message)
    }
}

private extension PerformClampReason {
    var word: String {
        switch self {
        case .belowRange: "minimum"
        case .aboveRange: "maximum"
        case .aboveCeiling: "ceiling"
        }
    }
}

/// Number and unit text. Numbers use Swift's shortest round-trip digits, written without an exponent and without
/// a trailing ".0", so the text states the exact value and never rounds it.
enum PerformNumberText {
    static func text(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        var raw = value.description
        if let marker = raw.firstIndex(of: "e") {
            let exponent = Int(raw[raw.index(after: marker)...]) ?? 0
            raw = expand(mantissa: String(raw[..<marker]), exponent: exponent)
        }
        if raw.hasSuffix(".0") { raw.removeLast(2) }
        return raw
    }

    /// The short unit text of a typed value or a clamp message: " dB" and " %" only.
    static func symbol(of unit: ParameterUnit) -> String {
        switch unit {
        case .decibels: " dB"
        case .percent: " %"
        case .normalized, .pan, .index, .boolean: ""
        }
    }

    private static func expand(mantissa: String, exponent: Int) -> String {
        let negative = mantissa.hasPrefix("-")
        let unsigned = negative ? String(mantissa.dropFirst()) : mantissa
        let integerDigits = unsigned.firstIndex(of: ".").map { unsigned.distance(from: unsigned.startIndex, to: $0) }
            ?? unsigned.count
        let digits = unsigned.filter { $0 != "." }
        let point = integerDigits + exponent
        let body: String
        if point <= 0 {
            body = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            body = digits + String(repeating: "0", count: point - digits.count)
        } else {
            body = String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
        }
        return negative ? "-" + body : body
    }
}
