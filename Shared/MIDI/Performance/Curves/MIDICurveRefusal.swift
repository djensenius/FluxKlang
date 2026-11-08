/// Why a response curve or a value transform was refused. Payloads carry the offending count, index or byte.
enum MIDICurveRefusal: Error, Equatable, Sendable {
    case tooFewPoints(Int)
    case tooManyPoints(Int)
    case firstInputNotAtDomainStart
    case lastInputNot127
    case inputsNotAscending(index: Int)
    case outputOutsideDomain(index: Int)
    case notMonotone
    case wrongDomain
    case tooManyControllers(Int)
    case controllerOutOfRange(UInt8)
    case protectedController(UInt8)
    case duplicateController(UInt8)
    case fixedVelocityOutOfRange(UInt8)
    case limitOrder
}

/// The 22 controller numbers a response curve is never registered for: 0 and 32 (bank select), 6 and 38 (data
/// entry), 64...67 (the pedal switches), 96 and 97 (data step), 98...101 (parameter selectors) and 120...127 (channel
/// mode). A reshaped value could change which bank or parameter is addressed, what a mode message does or which
/// notes a pedal holds. `MIDI1ChannelState` treats 6, 38, 96 and 97 as data entry and 120 and above as mode or
/// reset messages; `MIDINoteLedger` owns notes through the pedals 64 and 66 (`MIDIPedal`) and 64...127 means down;
/// 65 and 67 are kept with them as the other pedal switches. The numbers 1...31 and 33...63 are not listed, although
/// `MIDI1ChannelState` combines each coarse and fine pair into one 14-bit value: a curve on one of them reshapes
/// only that byte.
enum MIDIProtectedControllers {
    private static let bankSelect: [UInt8] = [0, 32]
    private static let dataEntry: [UInt8] = [6, 38]
    private static let pedals: [UInt8] = [64, 65, 66, 67]
    private static let dataStep: [UInt8] = [96, 97]
    private static let parameterSelectors: ClosedRange<UInt8> = 98...101
    private static let channelMode: ClosedRange<UInt8> = 120...127

    static func contains(_ controller: UInt8) -> Bool {
        bankSelect.contains(controller) || dataEntry.contains(controller) || pedals.contains(controller)
            || dataStep.contains(controller) || parameterSelectors.contains(controller)
            || channelMode.contains(controller)
    }
}
