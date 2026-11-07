import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// MMC machine-control intents, default-deny authorization, send grants and the tempo-sharing seam (#85 X3).
/// The topic suites live in `TimecodeMachineTests+*.swift` extensions.
@Suite("TimecodeMachine")
struct TimecodeMachineTests {
    static func deviceID(_ raw: UInt8) throws -> SysExDeviceID {
        try SysExDeviceID(raw)
    }

    static func entry(_ commandClass: MMCCommandClass, _ selector: MMCDeviceSelector = .any) -> MMCAuthorizationEntry {
        MMCAuthorizationEntry(selector: selector, commandClass: commandClass)
    }

    static func policy(_ entries: [MMCAuthorizationEntry]) throws -> MMCAuthorization {
        try MMCAuthorization.make(entries: entries)
    }

    static func locateTarget(subframes: Int = 42, colorFrame: Bool = true) throws -> MMCLocateTarget {
        let time = try SMPTETime(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps25)
        return try MMCLocateTarget(time: time, subframes: subframes, colorFrame: colorFrame)
    }

    /// Every MMC command with the class it must map to.
    static func commandsWithClasses() throws -> [(command: MMCCommand, commandClass: MMCCommandClass)] {
        [(.stop, .stop), (.play, .play), (.deferredPlay, .deferredPlay), (.fastForward, .fastForward),
         (.rewind, .rewind), (.pause, .pause), (.recordStrobe, .record), (.recordExit, .record),
         (.locate(try locateTarget()), .locate)]
    }

    @Test func machineCommandsMapToTheirAuthorizationClasses() throws {
        for (command, commandClass) in try Self.commandsWithClasses() {
            #expect(MMCCommandClass(command) == commandClass)
        }
    }

    @Test func machineCommandClassesHaveStableRawValuesAndOrder() {
        #expect(MMCCommandClass.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(MMCCommandClass.allCases
            == [.stop, .play, .deferredPlay, .fastForward, .rewind, .pause, .record, .locate])
        #expect(MMCCommandClass.record < .locate)
        #expect(!(MMCCommandClass.locate < .record))
        #expect(!(MMCCommandClass.play < .play))
    }
}
