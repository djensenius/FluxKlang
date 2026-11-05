//
//  OpenSoundControl+Packet.swift
//  FluxKlang
//
//  OSC 1.0 values: arguments, messages, bundles and the raw 64-bit time tag.
//

extension OpenSoundControl {
    /// Raw NTP-format time tag: upper 32 bits seconds since 1900, lower 32 bits
    /// fraction. No scheduling semantics live here.
    struct TimeTag: Sendable, Hashable {
        var rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        init(seconds: UInt32, fraction: UInt32) {
            rawValue = UInt64(seconds) << 32 | UInt64(fraction)
        }

        /// The OSC 1.0 "immediately" tag: 63 zero bits followed by a one.
        static let immediate = TimeTag(rawValue: 1)

        var seconds: UInt32 { UInt32(truncatingIfNeeded: rawValue >> 32) }
        var fraction: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
        var isImmediate: Bool { rawValue == Self.immediate.rawValue }
    }

    /// One message argument. Floats compare and hash by bit pattern so NaN
    /// payloads and signed zeros round-trip exactly.
    enum Argument: Sendable {
        case int32(Int32)
        case float32(Float)
        case string(String)
        case blob([UInt8])
        case int64(Int64)
        case float64(Double)
        case timeTag(TimeTag)
        case `true`
        case `false`
        case `nil`
        case impulse

        /// The OSC type tag byte for this argument.
        var typeTag: UInt8 {
            switch self {
            case .int32: UInt8(ascii: "i")
            case .float32: UInt8(ascii: "f")
            case .string: UInt8(ascii: "s")
            case .blob: UInt8(ascii: "b")
            case .int64: UInt8(ascii: "h")
            case .float64: UInt8(ascii: "d")
            case .timeTag: UInt8(ascii: "t")
            case .true: UInt8(ascii: "T")
            case .false: UInt8(ascii: "F")
            case .nil: UInt8(ascii: "N")
            case .impulse: UInt8(ascii: "I")
            }
        }
    }

    struct Message: Sendable, Hashable {
        var address: AddressPattern
        var arguments: [Argument]

        init(address: AddressPattern, arguments: [Argument] = []) {
            self.address = address
            self.arguments = arguments
        }
    }

    struct Bundle: Sendable, Hashable {
        var timeTag: TimeTag
        var elements: [Packet]

        init(timeTag: TimeTag = .immediate, elements: [Packet] = []) {
            self.timeTag = timeTag
            self.elements = elements
        }
    }

    /// One UDP datagram or stream frame: a message or a bundle.
    enum Packet: Sendable, Hashable {
        case message(Message)
        case bundle(Bundle)
    }
}

extension OpenSoundControl.Argument: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.int32(left), .int32(right)): left == right
        case let (.float32(left), .float32(right)): left.bitPattern == right.bitPattern
        case let (.string(left), .string(right)): Array(left.utf8) == Array(right.utf8)
        case let (.blob(left), .blob(right)): left == right
        case let (.int64(left), .int64(right)): left == right
        case let (.float64(left), .float64(right)): left.bitPattern == right.bitPattern
        case let (.timeTag(left), .timeTag(right)): left == right
        case (.true, .true), (.false, .false), (.nil, .nil), (.impulse, .impulse): true
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(typeTag)
        switch self {
        case .int32(let value): hasher.combine(value)
        case .float32(let value): hasher.combine(value.bitPattern)
        case .string(let value): hasher.combine(Array(value.utf8))
        case .blob(let value): hasher.combine(value)
        case .int64(let value): hasher.combine(value)
        case .float64(let value): hasher.combine(value.bitPattern)
        case .timeTag(let value): hasher.combine(value)
        case .true, .false, .nil, .impulse: break
        }
    }
}
