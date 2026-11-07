import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Verbatim copy of the body of `MIDIControlChange.decode(_:)` as it was on origin/main eba971f, before LD1.
private enum LegacyCCDecoder {
    static func decode(_ bytes: [UInt8]) -> [MIDIControlChange] {
        var messages: [MIDIControlChange] = []
        var index = 0
        var runningStatus: UInt8?
        while index < bytes.count {
            if bytes[index] & 0x80 != 0 {
                runningStatus = bytes[index]
                index += 1
            }
            guard let status = runningStatus else {
                index += 1
                continue
            }
            guard status & 0xF0 == 0xB0, index + 1 < bytes.count else {
                break
            }
            messages.append(MIDIControlChange(
                channel: Int(status & 0x0F) + 1,
                controller: bytes[index],
                value: bytes[index + 1]
            ))
            index += 2
        }
        return messages
    }
}

private struct SameResultCase {
    let name: String
    let bytes: [UInt8]
    let expected: [MIDIControlChange]
}

private struct DifferenceCase {
    let name: String
    let bytes: [UInt8]
    let legacy: [MIDIControlChange]
    let current: [MIDIControlChange]
}

private func cc(_ channel: Int, _ controller: UInt8, _ value: UInt8) -> MIDIControlChange {
    MIDIControlChange(channel: channel, controller: controller, value: value)
}

/// Every input on which the old and the new decoder must agree. The first row is the byte literal used by
/// `LaunchControlXLTests.midiDecoderHandlesChannel16AndRunningStatus`, re-hosted verbatim because that file also needs
/// hosted app types and is not mirrored into the evidence package.
private let sameResultCases: [SameResultCase] = [
    SameResultCase(name: "LaunchControlXLTests fixture", bytes: [0xBF, 5, 127, 6, 64],
                   expected: [cc(16, 5, 127), cc(16, 6, 64)]),
    SameResultCase(name: "empty", bytes: [], expected: []),
    SameResultCase(name: "single CC", bytes: [0xB0, 7, 100], expected: [cc(1, 7, 100)]),
    SameResultCase(name: "channel 1 controller 0 value 0", bytes: [0xB0, 0, 0], expected: [cc(1, 0, 0)]),
    SameResultCase(name: "channel 1 controller 127 value 127", bytes: [0xB0, 127, 127], expected: [cc(1, 127, 127)]),
    SameResultCase(name: "channel 16 controller 0 value 127", bytes: [0xBF, 0, 127], expected: [cc(16, 0, 127)]),
    SameResultCase(name: "channel 16 controller 127 value 0", bytes: [0xBF, 127, 0], expected: [cc(16, 127, 0)]),
    SameResultCase(name: "running status of three CCs", bytes: [0xB3, 1, 2, 3, 4, 5, 6],
                   expected: [cc(4, 1, 2), cc(4, 3, 4), cc(4, 5, 6)]),
    SameResultCase(name: "two channels back to back", bytes: [0xB0, 1, 2, 0xB1, 3, 4],
                   expected: [cc(1, 1, 2), cc(2, 3, 4)]),
    SameResultCase(name: "new status then running status", bytes: [0xB0, 1, 2, 0xB9, 3, 4, 5, 6],
                   expected: [cc(1, 1, 2), cc(10, 3, 4), cc(10, 5, 6)]),
    SameResultCase(name: "leading data bytes are skipped", bytes: [0x05, 0x06, 0xB0, 1, 2], expected: [cc(1, 1, 2)]),
    SameResultCase(name: "status only", bytes: [0xB0], expected: []),
    SameResultCase(name: "status and one data byte", bytes: [0xB0, 5], expected: []),
    SameResultCase(name: "truncated trailing CC", bytes: [0xB0, 5, 7, 0xB0, 6], expected: [cc(1, 5, 7)]),
    SameResultCase(name: "stray data byte after a complete CC", bytes: [0xB0, 5, 7, 0x7F], expected: [cc(1, 5, 7)]),
    SameResultCase(name: "data only", bytes: [1, 2, 3, 4], expected: []),
    SameResultCase(name: "note on stops legacy and is skipped by the parser", bytes: [0x90, 0x3C, 0x40], expected: []),
    SameResultCase(name: "note on with running status after a CC", bytes: [0xB0, 5, 7, 0x90, 0x3C, 0x40, 6, 7],
                   expected: [cc(1, 5, 7)]),
    SameResultCase(name: "unterminated SysEx after a CC", bytes: [0xB0, 5, 7, 0xF0, 6, 7, 8, 9],
                   expected: [cc(1, 5, 7)]),
    SameResultCase(name: "system common after a CC clears running status", bytes: [0xB0, 5, 7, 0xF6, 6, 7],
                   expected: [cc(1, 5, 7)])
]

/// Inputs on which the new decoder deliberately differs, with the exact array each decoder returns.
private let differenceCases: [DifferenceCase] = [
    DifferenceCase(name: "program change in the middle", bytes: [0xB0, 5, 7, 0xC0, 9, 0xB0, 6, 8],
                   legacy: [cc(1, 5, 7)], current: [cc(1, 5, 7), cc(1, 6, 8)]),
    DifferenceCase(name: "note on in the middle", bytes: [0xB0, 5, 7, 0x90, 0x3C, 0x40, 0xB0, 6, 8],
                   legacy: [cc(1, 5, 7)], current: [cc(1, 5, 7), cc(1, 6, 8)]),
    DifferenceCase(name: "leading note on", bytes: [0x90, 0x3C, 0x40, 0xB0, 5, 7],
                   legacy: [], current: [cc(1, 5, 7)]),
    DifferenceCase(name: "F8 inside a CC pair", bytes: [0xB0, 5, 0xF8, 7],
                   legacy: [cc(1, 5, 0xF8)], current: [cc(1, 5, 7)]),
    DifferenceCase(name: "F8 between two running status CCs", bytes: [0xB0, 5, 7, 0xF8, 6, 8],
                   legacy: [cc(1, 5, 7)], current: [cc(1, 5, 7), cc(1, 6, 8)]),
    DifferenceCase(name: "leading F8", bytes: [0xF8, 0xB0, 5, 7], legacy: [], current: [cc(1, 5, 7)]),
    DifferenceCase(name: "FF between status and data", bytes: [0xB4, 0xFF, 5, 7],
                   legacy: [cc(5, 0xFF, 5)], current: [cc(5, 5, 7)]),
    DifferenceCase(name: "status byte in the value position", bytes: [0xB0, 5, 0xB1, 6, 7],
                   legacy: [cc(1, 5, 0xB1), cc(1, 6, 7)], current: [cc(2, 6, 7)]),
    DifferenceCase(name: "terminated SysEx with CC-looking data then a CC", bytes: [0xF0, 5, 7, 0xF7, 0xB0, 6, 8],
                   legacy: [], current: [cc(1, 6, 8)]),
    DifferenceCase(name: "SysEx interrupted by a status", bytes: [0xF0, 1, 2, 0xB0, 6, 8],
                   legacy: [], current: [cc(1, 6, 8)]),
    DifferenceCase(name: "system common in the middle", bytes: [0xB0, 5, 7, 0xF6, 0xB0, 6, 8],
                   legacy: [cc(1, 5, 7)], current: [cc(1, 5, 7), cc(1, 6, 8)]),
    DifferenceCase(name: "pitch bend in the middle", bytes: [0xB0, 5, 7, 0xE0, 1, 2, 0xB1, 6, 8],
                   legacy: [cc(1, 5, 7)], current: [cc(1, 5, 7), cc(2, 6, 8)])
]

extension MIDIControlChangeDecodeTests {
    @Test func ccDecodeFrozenLegacyCopyStillBehavesLikeTheOldDecoder() {
        #expect(LegacyCCDecoder.decode([0xB0, 5, 7, 0xC0, 9, 0xB0, 6, 8]) == [Self.cc(1, 5, 7)])
        #expect(LegacyCCDecoder.decode([0xB0, 5, 0xF8, 7]) == [Self.cc(1, 5, 0xF8)])
        #expect(LegacyCCDecoder.decode([0xBF, 5, 127, 6, 64]) == [Self.cc(16, 5, 127), Self.cc(16, 6, 64)])
    }

    @Test func ccDecodeMatchesTheLegacyDecoderOnEveryExistingFixtureAndTheWellFormedTable() {
        #expect(sameResultCases.count == 20)
        for entry in sameResultCases {
            #expect(LegacyCCDecoder.decode(entry.bytes) == entry.expected, "legacy: \(entry.name)")
            #expect(MIDIControlChange.decode(entry.bytes) == entry.expected, "new: \(entry.name)")
        }
    }

    @Test func ccDecodeMatchesTheLegacyDecoderOnEveryChannelAndRunningStatusPair() {
        for status in UInt8(0xB0)...UInt8(0xBF) {
            let bytes: [UInt8] = [status, 0, 0, 127, 127]
            let channel = Int(status & 0x0F) + 1
            let expected = [Self.cc(channel, 0, 0), Self.cc(channel, 127, 127)]
            #expect(LegacyCCDecoder.decode(bytes) == expected)
            #expect(MIDIControlChange.decode(bytes) == expected)
        }
    }

    @Test func ccDecodeListsTheIntendedDifferencesWithExactArraysForBothDecoders() {
        #expect(differenceCases.count == 12)
        for entry in differenceCases {
            #expect(LegacyCCDecoder.decode(entry.bytes) == entry.legacy, "legacy: \(entry.name)")
            #expect(MIDIControlChange.decode(entry.bytes) == entry.current, "new: \(entry.name)")
            #expect(entry.legacy != entry.current, "not a difference: \(entry.name)")
        }
    }
}
