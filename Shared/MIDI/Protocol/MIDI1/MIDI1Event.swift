/// Effective MIDI 1 status and data, not a byte-perfect record of running-status omissions.
/// SysEx payload excludes F0, F7 and interleaved realtime bytes.
enum MIDI1Event: Equatable, Sendable {
    case channel(status: UInt8, data1: UInt8, data2: UInt8?)
    case systemCommon(status: UInt8, data1: UInt8?, data2: UInt8?)
    case realTime(status: UInt8)
    case sysEx(payload: [UInt8])
}
