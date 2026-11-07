/// What one control source is, in declaration order (which is also its `Comparable` order). Raw values are stable and
/// appear in source IDs.
enum ControlSourceKind: String, Hashable, Comparable, Sendable, CaseIterable {
    /// A 7-bit CC.
    case controller = "cc"
    /// A 14-bit CC pair named by its MSB number 1...31.
    case controller14 = "cc14"
    case registeredParameter = "rpn"
    case nonRegisteredParameter = "nrpn"
    case pitchBend = "bend"
    case channelPressure = "press"

    /// The width of every message of this kind.
    var width: EncoderBitWidth {
        switch self {
        case .controller, .channelPressure: .seven
        case .controller14, .registeredParameter, .nonRegisteredParameter, .pitchBend: .fourteen
        }
    }

    /// The key numbers valid for this kind.
    var numberRange: ClosedRange<UInt16> {
        switch self {
        case .controller: Self.widen(ControlIntakeBounds.plainControllerRange)
        case .controller14: Self.widen(ControlIntakeBounds.pairedControllerRange)
        case .registeredParameter, .nonRegisteredParameter: ControlIntakeBounds.parameterNumberRange
        case .pitchBend, .channelPressure: ControlIntakeBounds.singletonNumberRange
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }

    private var order: Int {
        switch self {
        case .controller: 0
        case .controller14: 1
        case .registeredParameter: 2
        case .nonRegisteredParameter: 3
        case .pitchBend: 4
        case .channelPressure: 5
        }
    }

    private static func widen(_ range: ClosedRange<UInt8>) -> ClosedRange<UInt16> {
        UInt16(range.lowerBound)...UInt16(range.upperBound)
    }
}
