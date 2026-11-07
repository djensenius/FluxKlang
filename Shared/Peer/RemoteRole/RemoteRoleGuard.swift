//
//  RemoteRoleGuard.swift
//  FluxKlang
//
//  The capability guard of the remote-controller role (#96, RR1). A remote
//  controller can never write to the local engine, a console or MIDI, and raw
//  notes and clocks are never peer UI commands. The guard is a total function of
//  the role and the capability; `perform` calls a sink only when it allows.
//

/// What a caller wants to do. The set is closed: adding a case forces the guard table to decide.
enum RemoteCapability: Hashable, Sendable, CaseIterable {
    case engineWrite
    case consoleWrite
    case midiOutput
    /// Send a UI command to the controlled host (the host still applies its own grants).
    case peerUICommand
    /// Read status, in a remote role the mirrored host status.
    case statusRead
    case rawNoteInput
    case clockInput
}

enum RemoteRoleDecision: Hashable, Sendable {
    case allowed
    case refused(RemoteCapabilityRefusal)
}

/// Raw MIDI input handling, independent of the role.
enum RawInputClass: Hashable, Sendable, CaseIterable {
    case refusedRawNote
    case refusedRawClock
    /// Raw system messages that are neither notes nor the four clock/transport bytes.
    case refusedRawOther
    /// Control change and other bindable messages; RR2 routes them through bindings, never raw.
    case needsBinding
}

/// Writes to the local audio engine. The guard calls it only in `standalone`.
protocol EngineWriting {
    associatedtype Write
    func writeEngine(_ write: Write)
}

/// Writes to a mixing console. The guard calls it only in `standalone`.
protocol ConsoleWriting {
    associatedtype Write
    func writeConsole(_ write: Write)
}

/// Sends MIDI output. The guard calls it only in `standalone`.
protocol MIDIWriting {
    associatedtype Message
    func sendMIDI(_ message: Message)
}

enum RemoteRoleGuard {
    /// The total capability table (see DESIGN.md). In a remote role only `peerUICommand` (not for an
    /// observer, not while the host is lost) and `statusRead` pass.
    static func decide(role: RemoteRole, capability: RemoteCapability) -> RemoteRoleDecision {
        switch role.phase {
        case .standalone:
            standalone(capability)
        case .remoteController(let session):
            controlling(session, capability)
        case .hostLost:
            hostLost(capability)
        }
    }

    /// Runs `action` and returns its value only when `decide` allows; otherwise throws the typed reason
    /// and does not run it.
    static func perform<Result>(
        _ capability: RemoteCapability, role: RemoteRole, _ action: () -> Result
    ) throws(RemoteCapabilityRefusal) -> Result {
        if case .refused(let reason) = decide(role: role, capability: capability) { throw reason }
        return action()
    }

    static func writeEngine<Sink: EngineWriting>(
        _ write: Sink.Write, role: RemoteRole, to sink: Sink
    ) throws(RemoteCapabilityRefusal) {
        try perform(.engineWrite, role: role) { sink.writeEngine(write) }
    }

    static func writeConsole<Sink: ConsoleWriting>(
        _ write: Sink.Write, role: RemoteRole, to sink: Sink
    ) throws(RemoteCapabilityRefusal) {
        try perform(.consoleWrite, role: role) { sink.writeConsole(write) }
    }

    static func sendMIDI<Sink: MIDIWriting>(
        _ message: Sink.Message, role: RemoteRole, to sink: Sink
    ) throws(RemoteCapabilityRefusal) {
        try perform(.midiOutput, role: role) { sink.sendMIDI(message) }
    }

    /// Classifies a raw message with an exhaustive switch. Notes (a Note On with velocity 0 arrives as
    /// `noteOff`) and the real-time bytes 0xF8 (clock), 0xFA (start), 0xFB (continue) and 0xFC (stop) are
    /// never `needsBinding`. Any other real-time byte, system common and system exclusive are
    /// `refusedRawOther`.
    static func classify(_ semantic: MIDI1Semantic) -> RawInputClass {
        switch semantic {
        case .noteOff, .noteOn, .polyphonicPressure:
            .refusedRawNote
        case .controlChange, .programChange, .channelPressure, .pitchBend:
            .needsBinding
        case .realTime(let status):
            clockClass(status: status)
        case .systemCommon, .sysEx:
            .refusedRawOther
        }
    }

    private static func clockClass(status: UInt8) -> RawInputClass {
        switch status {
        case 0xF8, 0xFA, 0xFB, 0xFC: .refusedRawClock
        default: .refusedRawOther
        }
    }

    private static func standalone(_ capability: RemoteCapability) -> RemoteRoleDecision {
        switch capability {
        case .engineWrite, .consoleWrite, .midiOutput, .statusRead, .rawNoteInput, .clockInput: .allowed
        case .peerUICommand: .refused(.noRemoteSession)
        }
    }

    private static func controlling(_ session: RemoteSession, _ capability: RemoteCapability) -> RemoteRoleDecision {
        switch capability {
        case .peerUICommand:
            switch session.grant {
            case .remoteController: .allowed
            case .observer: .refused(.observerHasNoCommands)
            }
        case .statusRead: .allowed
        case .engineWrite, .consoleWrite, .midiOutput: .refused(.noLocalWriteInRemoteRole)
        case .rawNoteInput, .clockInput: .refused(.rawInputIsNotAPeerCommand)
        }
    }

    private static func hostLost(_ capability: RemoteCapability) -> RemoteRoleDecision {
        switch capability {
        case .peerUICommand: .refused(.hostLost)
        case .statusRead: .allowed
        case .engineWrite, .consoleWrite, .midiOutput: .refused(.noLocalWriteInRemoteRole)
        case .rawNoteInput, .clockInput: .refused(.rawInputIsNotAPeerCommand)
        }
    }
}
