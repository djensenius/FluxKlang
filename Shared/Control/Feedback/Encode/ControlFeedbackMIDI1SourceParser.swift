/// Reads a `ControlSourceID` back into the `ControlSourceKey` that built it (`ControlSourceKey` has no inverse).
/// Works on UTF-8 bytes only. One forward pass over at most 128 bytes records at most four field starts; the
/// fields are then read from those positions. The result must rebuild the same ID byte for byte, so `01`, `+1`
/// and every other non-canonical spelling is refused.
enum ControlFeedbackMIDI1SourceParser {
    private static let fieldCount = 4
    private static let maximumDigits = 5
    private static let dot = UInt8(ascii: ".")

    /// `notMIDISource` when the ID does not start with `midi.`, `malformedSource` for anything else wrong.
    static func parse(_ source: ControlSourceID) throws(ControlFeedbackMIDI1Refusal) -> ControlSourceKey {
        let text = source.rawValue
        let prefix = ControlIntakeBounds.sourceIDPrefix.utf8
        guard text.utf8.starts(with: prefix) else { throw .notMIDISource }
        let starts = try fieldStarts(in: text, after: prefix.count)
        let utf8 = text.utf8
        let origin = utf8[starts[0]..<utf8.index(before: starts[1])]
        let channel = utf8[starts[1]..<utf8.index(before: starts[2])]
        let kind = utf8[starts[2]..<utf8.index(before: starts[3])]
        let number = utf8[starts[3]..<utf8.endIndex]
        guard let channelValue = decimal(channel).flatMap({ UInt8(exactly: $0) }),
              let numberValue = decimal(number).flatMap({ UInt16(exactly: $0) }),
              let kindValue = ControlSourceKind(rawValue: String(Substring(kind))),
              let originValue = try? ControlSourceOrigin(String(Substring(origin)))
        else { throw .malformedSource }
        guard let key = try? ControlSourceKey(
            origin: originValue, channel: channelValue, kind: kindValue, number: numberValue
        ), key.sourceID.rawValue.utf8.elementsEqual(utf8) else { throw .malformedSource }
        return key
    }

    /// The index where each of the four fields starts, or `malformedSource` unless there are exactly four.
    private static func fieldStarts(
        in text: String, after prefixCount: Int
    ) throws(ControlFeedbackMIDI1Refusal) -> [String.Index] {
        let utf8 = text.utf8
        var starts: [String.Index] = []
        starts.reserveCapacity(fieldCount)
        var position = utf8.index(utf8.startIndex, offsetBy: prefixCount)
        starts.append(position)
        while position < utf8.endIndex {
            let current = position
            position = utf8.index(after: position)
            if utf8[current] == dot {
                guard starts.count < fieldCount else { throw .malformedSource }
                starts.append(position)
            }
        }
        guard starts.count == fieldCount else { throw .malformedSource }
        return starts
    }

    /// ASCII digits only, 1...5 of them.
    private static func decimal(_ field: Substring.UTF8View) -> Int? {
        guard (1...maximumDigits).contains(field.count) else { return nil }
        var value = 0
        for byte in field {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }
}
