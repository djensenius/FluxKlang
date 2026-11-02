/// Pure incremental framing for one logical MIDI 1 byte stream, independent of packet/feed boundaries.
/// Malformed/oversized SysEx uses a fail-closed recovery policy, not a complete normative error algorithm.
/// Only the logical SysEx payload grows, up to the caller's explicit bound. No timeout or output queue.
struct MIDI1Parser: Sendable {
    let maximumSysExPayloadBytes: Int

    private enum SysExState: Sendable {
        case idle
        case collecting
        case discarding
    }

    private var runningStatus: UInt8?
    private var pendingStatus: UInt8?
    private var firstData: UInt8?
    private var sysExState = SysExState.idle
    private var payload: [UInt8] = []

    init?(maximumSysExPayloadBytes: Int) {
        guard maximumSysExPayloadBytes > 0 else { return nil }
        self.maximumSysExPayloadBytes = maximumSysExPayloadBytes
    }

    /// Emits at most one event. F8...FF is transparent to all framing, including FF (System Reset).
    mutating func consume(_ byte: UInt8) -> MIDI1Event? {
        if byte >= 0xF8 { return .realTime(status: byte) }
        if byte >= 0x80 { return consumeStatus(byte) }
        switch sysExState {
        case .collecting:
            if payload.count < maximumSysExPayloadBytes {
                payload.append(byte)
            } else {
                payload.removeAll(keepingCapacity: false)
                sysExState = .discarding
            }
            return nil
        case .discarding:
            return nil
        case .idle:
            return consumeShortData(byte)
        }
    }

    /// Clears framing and any retained payload; the configured bound remains unchanged.
    mutating func reset() {
        runningStatus = nil
        pendingStatus = nil
        firstData = nil
        sysExState = .idle
        payload.removeAll(keepingCapacity: false)
    }

    private mutating func consumeStatus(_ status: UInt8) -> MIDI1Event? {
        pendingStatus = nil
        firstData = nil
        if status >= 0xF0 { runningStatus = nil }

        if status == 0xF7 {
            switch sysExState {
            case .collecting:
                let event = MIDI1Event.sysEx(payload: payload)
                endSysEx()
                return event
            case .discarding:
                endSysEx()
                return nil
            case .idle:
                return .systemCommon(status: status, data1: nil, data2: nil)
            }
        }

        // Any other non-realtime status interrupts SysEx, including a fresh nested F0.
        endSysEx()
        if status < 0xF0 {
            runningStatus = status
            pendingStatus = status
        } else if status == 0xF0 {
            sysExState = .collecting
        } else if (0xF1...0xF3).contains(status) {
            pendingStatus = status
        } else {
            // Undefined F4/F5 and Tune Request F6 have no data bytes.
            return .systemCommon(status: status, data1: nil, data2: nil)
        }
        return nil
    }

    private mutating func endSysEx() {
        sysExState = .idle
        payload.removeAll(keepingCapacity: false)
    }

    private mutating func consumeShortData(_ byte: UInt8) -> MIDI1Event? {
        guard let status = pendingStatus ?? runningStatus else { return nil }
        let isSingleData = (0xC0...0xDF).contains(status) || status == 0xF1 || status == 0xF3
        if isSingleData {
            pendingStatus = nil
            firstData = nil
            return shortEvent(status: status, data1: byte, data2: nil)
        }
        guard let data1 = firstData else {
            pendingStatus = status
            firstData = byte
            return nil
        }
        pendingStatus = nil
        firstData = nil
        return shortEvent(status: status, data1: data1, data2: byte)
    }

    private func shortEvent(status: UInt8, data1: UInt8, data2: UInt8?) -> MIDI1Event {
        if status < 0xF0 {
            return .channel(status: status, data1: data1, data2: data2)
        }
        return .systemCommon(status: status, data1: data1, data2: data2)
    }
}
