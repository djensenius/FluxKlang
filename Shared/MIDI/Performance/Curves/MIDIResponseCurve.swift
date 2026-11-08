/// Which data byte a response curve reshapes. A velocity curve maps 1...127 to 1...127, so a sounding note stays
/// sounding: velocity 0 is how a Note On says release, and no curve can produce it. A controller curve maps 0...127
/// to 0...127 and serves control change values and both pressure kinds.
enum MIDICurveDomain: Hashable, Sendable {
    case velocity
    case controller

    /// The lowest input and the lowest output the domain allows.
    var lowestValue: UInt8 {
        switch self {
        case .velocity: 1
        case .controller: 0
        }
    }
}

/// One breakpoint of a response curve: the curve passes through `output` at `input`.
struct MIDICurvePoint: Hashable, Sendable {
    let input: UInt8
    let output: UInt8
}

/// A response curve over MIDI 1 data bytes: breakpoints joined by straight segments, evaluated in integers (round
/// half toward positive infinity) into a 128-entry table once, when the curve is built. Only the factories build a
/// curve, so every value in existence satisfies the checks of `make(domain:points:)`.
struct MIDIResponseCurve: Hashable, Sendable {
    static let maximumPoints = 16
    static let highestValue: UInt8 = 127
    private static let tableSize = 128

    var domain: MIDICurveDomain { storedDomain }
    var points: [MIDICurvePoint] { storedPoints }

    private let storedDomain: MIDICurveDomain
    private let storedPoints: [MIDICurvePoint]
    /// Indexed by input. Index 0 of a velocity curve holds 0 and is never read: `output(for:)` refuses that input.
    private let storedTable: [UInt8]

    private init(domain: MIDICurveDomain, points: [MIDICurvePoint]) {
        storedDomain = domain
        storedPoints = points
        storedTable = Self.makeTable(points)
    }

    /// Checks run in this order, each over the whole input: more than `maximumPoints`, fewer than 2, first input
    /// not at the domain start, last input not 127, inputs not strictly ascending, an output outside the domain,
    /// then direction. A velocity curve never decreases; a controller curve is non-decreasing or non-increasing.
    static func make(
        domain: MIDICurveDomain, points: [MIDICurvePoint]
    ) throws(MIDICurveRefusal) -> MIDIResponseCurve {
        try checkTooMany(points)
        try checkTooFew(points)
        try checkFirstInput(points, domain: domain)
        try checkLastInput(points)
        try checkAscending(points)
        try checkOutputs(points, domain: domain)
        try checkMonotone(points, domain: domain)
        return MIDIResponseCurve(domain: domain, points: points)
    }

    /// The identity on the domain: every input in the domain maps to itself.
    static func linear(_ domain: MIDICurveDomain) -> MIDIResponseCurve {
        let points = [
            MIDICurvePoint(input: domain.lowestValue, output: domain.lowestValue),
            MIDICurvePoint(input: highestValue, output: highestValue)
        ]
        return MIDIResponseCurve(domain: domain, points: points)
    }

    /// Every note sounds at `velocity`, which must be 1...127.
    static func fixedVelocity(_ velocity: UInt8) throws(MIDICurveRefusal) -> MIDIResponseCurve {
        guard velocity >= MIDICurveDomain.velocity.lowestValue, velocity <= highestValue else {
            throw .fixedVelocityOutOfRange(velocity)
        }
        let points = [
            MIDICurvePoint(input: 1, output: velocity),
            MIDICurvePoint(input: highestValue, output: velocity)
        ]
        return try make(domain: .velocity, points: points)
    }

    /// Velocity 1 maps to `low` and 127 to `high`, straight between. `low` above `high` is `limitOrder`, checked
    /// before the points are built, so `low` 0 or `high` above 127 is `outputOutsideDomain`.
    static func limitedVelocity(low: UInt8, high: UInt8) throws(MIDICurveRefusal) -> MIDIResponseCurve {
        guard low <= high else { throw .limitOrder }
        let points = [
            MIDICurvePoint(input: 1, output: low),
            MIDICurvePoint(input: highestValue, output: high)
        ]
        return try make(domain: .velocity, points: points)
    }

    /// The output for `input`, or nil above 127 and, for a velocity curve, at 0.
    func output(for input: UInt8) -> UInt8? {
        guard input >= storedDomain.lowestValue, input <= Self.highestValue else { return nil }
        return storedTable[Int(input)]
    }
}

// MARK: - Validation

extension MIDIResponseCurve {
    private static func checkTooMany(_ points: [MIDICurvePoint]) throws(MIDICurveRefusal) {
        if points.count > maximumPoints { throw .tooManyPoints(points.count) }
    }

    private static func checkTooFew(_ points: [MIDICurvePoint]) throws(MIDICurveRefusal) {
        if points.count < 2 { throw .tooFewPoints(points.count) }
    }

    private static func checkFirstInput(
        _ points: [MIDICurvePoint], domain: MIDICurveDomain
    ) throws(MIDICurveRefusal) {
        guard let first = points.first else { return }
        if first.input != domain.lowestValue { throw .firstInputNotAtDomainStart }
    }

    private static func checkLastInput(_ points: [MIDICurvePoint]) throws(MIDICurveRefusal) {
        guard let last = points.last else { return }
        if last.input != highestValue { throw .lastInputNot127 }
    }

    private static func checkAscending(_ points: [MIDICurvePoint]) throws(MIDICurveRefusal) {
        for index in points.indices.dropFirst() where points[index].input <= points[index - 1].input {
            throw .inputsNotAscending(index: index)
        }
    }

    private static func checkOutputs(
        _ points: [MIDICurvePoint], domain: MIDICurveDomain
    ) throws(MIDICurveRefusal) {
        for index in points.indices {
            let output = points[index].output
            if output < domain.lowestValue || output > highestValue { throw .outputOutsideDomain(index: index) }
        }
    }

    private static func checkMonotone(
        _ points: [MIDICurvePoint], domain: MIDICurveDomain
    ) throws(MIDICurveRefusal) {
        var rises = false
        var falls = false
        for index in points.indices.dropFirst() {
            if points[index].output > points[index - 1].output { rises = true }
            if points[index].output < points[index - 1].output { falls = true }
        }
        switch domain {
        case .velocity:
            if falls { throw .notMonotone }
        case .controller:
            if rises && falls { throw .notMonotone }
        }
    }
}

// MARK: - Table

extension MIDIResponseCurve {
    /// `points` satisfy the checks of `make`, so every segment has a positive width and outputs inside the domain.
    private static func makeTable(_ points: [MIDICurvePoint]) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: tableSize)
        for index in points.indices.dropFirst() {
            fill(&table, from: points[index - 1], to: points[index])
        }
        return table
    }

    private static func fill(_ table: inout [UInt8], from start: MIDICurvePoint, to end: MIDICurvePoint) {
        let startInput = Int(start.input)
        let startOutput = Int(start.output)
        let rise = Int(end.output) - startOutput
        let span = Int(end.input) - startInput
        for input in startInput...Int(end.input) {
            let numerator = (input - startInput) * rise
            let rounded = floorDivide(2 * numerator + span, 2 * span)
            table[input] = UInt8(clamping: startOutput + rounded)
        }
    }

    /// Division rounding toward negative infinity; `divisor` is positive.
    private static func floorDivide(_ dividend: Int, _ divisor: Int) -> Int {
        let quotient = dividend / divisor
        return dividend % divisor < 0 ? quotient - 1 : quotient
    }
}
