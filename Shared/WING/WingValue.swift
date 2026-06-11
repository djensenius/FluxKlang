//
//  WingValue.swift
//  FluxKlang
//
//  A small, Sendable wrapper over the OSC argument types FluxKlang exchanges
//  with the WING: 32-bit floats, 32-bit ints and strings.
//

import Foundation
import SwiftOSC

/// A typed OSC argument value used when talking to the WING.
enum WingValue: Equatable, Sendable {
    case float(Float)
    case int(Int32)
    case string(String)

    /// The value as a concrete `OSCValue` for encoding into an `OSCMessage`.
    var oscValue: any OSCValue {
        switch self {
        case .float(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    /// Wraps a received `OSCValue`, normalising wider numeric types to the
    /// float/int cases. Returns `nil` for unsupported argument types.
    init?(osc value: any OSCValue) {
        switch value {
        case let value as Float: self = .float(value)
        case let value as Double: self = .float(Float(value))
        case let value as Int32: self = .int(value)
        case let value as Int64: self = .int(Int32(truncatingIfNeeded: value))
        case let value as String: self = .string(value)
        default: return nil
        }
    }

    var floatValue: Float? {
        if case .float(let value) = self { return value }
        return nil
    }

    var intValue: Int32? {
        if case .int(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
