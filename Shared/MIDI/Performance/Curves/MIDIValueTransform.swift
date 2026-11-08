/// A response curve registered for one control change number. A carrier only: `MIDIValueTransform.make` checks the
/// number and the curve's domain, so a value of this type means nothing until a transform accepts it.
struct MIDIControllerCurve: Hashable, Sendable {
    let controller: UInt8
    let curve: MIDIResponseCurve
}

/// Reshapes the data values of MIDI 1 messages. It changes how hard a note sounds and how large a value is, and
/// nothing else: never the case, channel, note or controller number, and never whether a note-on is a note-on. A
/// velocity of 1...127 stays 1...127, a velocity of 0 (a release) and every Note Off stay as they are, and no
/// controller in `MIDIProtectedControllers` can be registered. Only `make` and `identity` build a value, and the
/// controller list it stores is sorted ascending, so equal contents compare equal whatever order they came in.
struct MIDIValueTransform: Hashable, Sendable {
    static let maximumControllerCurves = 16
    static let identity = MIDIValueTransform(velocity: nil, pressure: nil, controllers: [])

    var velocity: MIDIResponseCurve? { storedVelocity }
    var pressure: MIDIResponseCurve? { storedPressure }
    var controllers: [MIDIControllerCurve] { storedControllers }

    private let storedVelocity: MIDIResponseCurve?
    private let storedPressure: MIDIResponseCurve?
    private let storedControllers: [MIDIControllerCurve]

    private init(velocity: MIDIResponseCurve?, pressure: MIDIResponseCurve?, controllers: [MIDIControllerCurve]) {
        storedVelocity = velocity
        storedPressure = pressure
        storedControllers = controllers
    }

    /// Checks run in this order, each over the whole input: more than `maximumControllerCurves` controllers, a
    /// curve in the wrong domain (velocity slot, pressure slot, then the controllers in array order), a controller
    /// number above 127, a protected controller, a controller given twice. The first violation in array order is
    /// reported for the last three. `velocity` must be a velocity curve; `pressure` and each controller curve must
    /// be controller curves.
    static func make(
        velocity: MIDIResponseCurve?, pressure: MIDIResponseCurve?, controllers: [MIDIControllerCurve]
    ) throws(MIDICurveRefusal) -> MIDIValueTransform {
        try checkTooMany(controllers)
        try checkDomains(velocity: velocity, pressure: pressure, controllers: controllers)
        try checkRange(controllers)
        try checkProtected(controllers)
        try checkDuplicates(controllers)
        let sorted = controllers.sorted { $0.controller < $1.controller }
        return MIDIValueTransform(velocity: velocity, pressure: pressure, controllers: sorted)
    }

    /// The message with its data value reshaped, or the message itself when no curve applies. A message that
    /// `hasRoutableData` rejects (a data byte out of range, or a system common, real-time or system exclusive
    /// message) is returned unchanged.
    func apply(_ message: MIDI1Semantic) -> MIDI1Semantic {
        guard message.hasRoutableData else { return message }
        switch message {
        case let .noteOn(channel, note, velocity):
            let curved = reshaped(velocity, by: storedVelocity)
            return .noteOn(channel: channel, note: note, velocity: curved)
        case let .polyphonicPressure(channel, note, pressure):
            let curved = reshaped(pressure, by: storedPressure)
            return .polyphonicPressure(channel: channel, note: note, pressure: curved)
        case let .channelPressure(channel, pressure):
            let curved = reshaped(pressure, by: storedPressure)
            return .channelPressure(channel: channel, pressure: curved)
        case let .controlChange(channel, controller, value):
            let curved = reshaped(value, by: controllerCurve(for: controller))
            return .controlChange(channel: channel, controller: controller, value: curved)
        case .noteOff, .programChange, .pitchBend, .systemCommon, .realTime, .sysEx:
            return message
        }
    }

    private func reshaped(_ value: UInt8, by curve: MIDIResponseCurve?) -> UInt8 {
        curve?.output(for: value) ?? value
    }

    private func controllerCurve(for controller: UInt8) -> MIDIResponseCurve? {
        storedControllers.first { $0.controller == controller }?.curve
    }
}

// MARK: - Validation

extension MIDIValueTransform {
    private static func checkTooMany(_ controllers: [MIDIControllerCurve]) throws(MIDICurveRefusal) {
        if controllers.count > maximumControllerCurves { throw .tooManyControllers(controllers.count) }
    }

    private static func checkDomains(
        velocity: MIDIResponseCurve?, pressure: MIDIResponseCurve?, controllers: [MIDIControllerCurve]
    ) throws(MIDICurveRefusal) {
        if let velocity, velocity.domain != .velocity { throw .wrongDomain }
        if let pressure, pressure.domain != .controller { throw .wrongDomain }
        for entry in controllers where entry.curve.domain != .controller { throw .wrongDomain }
    }

    private static func checkRange(_ controllers: [MIDIControllerCurve]) throws(MIDICurveRefusal) {
        for entry in controllers where entry.controller > MIDIResponseCurve.highestValue {
            throw .controllerOutOfRange(entry.controller)
        }
    }

    private static func checkProtected(_ controllers: [MIDIControllerCurve]) throws(MIDICurveRefusal) {
        for entry in controllers where MIDIProtectedControllers.contains(entry.controller) {
            throw .protectedController(entry.controller)
        }
    }

    private static func checkDuplicates(_ controllers: [MIDIControllerCurve]) throws(MIDICurveRefusal) {
        for index in controllers.indices {
            let earlier = controllers[..<index]
            if earlier.contains(where: { $0.controller == controllers[index].controller }) {
                throw .duplicateController(controllers[index].controller)
            }
        }
    }
}
