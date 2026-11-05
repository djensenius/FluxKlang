//
//  PeerCommandLedger.swift
//  FluxKlang
//
//  In-session dedup for admitted peer commands (#95). Entries are keyed by the
//  connection epoch and command ID and keep the exact intent, the permission
//  fingerprint it was admitted under and, once known, its completion. The
//  ledger only remembers; it never admits. It is bounded and refuses when
//  full instead of evicting, and it dies with its connection epoch.
//

import Foundation

struct PeerCommandKey: Hashable, Sendable {
    let connection: ConnectionEpoch
    let command: CommandID
}

/// Thrown only by the ledger and processor initializers.
enum PeerCommandCapacityError: Error, Hashable, Sendable {
    case invalidCapacity(Int)
}

enum PeerCommandLedgerError: Error, Hashable, Sendable {
    case full(capacity: Int)
    case wrongConnection
    case alreadyRecorded(CommandID)
    case unknownCommand(CommandID)
    case alreadyCompleted(CommandID)
}

struct PeerCommandLedger: Sendable {
    static let capacityBounds = 1...16_384
    static let standardCapacity = 1_024

    struct Entry: Hashable, Sendable {
        let intent: CommandIntent
        let permission: PermissionFingerprint
        var completion: PeerCommandCompletion?
    }

    let connectionEpoch: ConnectionEpoch
    let capacity: Int
    private var entries: [PeerCommandKey: Entry] = [:]

    init(connectionEpoch: ConnectionEpoch, capacity: Int = Self.standardCapacity) throws(PeerCommandCapacityError) {
        guard Self.capacityBounds.contains(capacity) else { throw .invalidCapacity(capacity) }
        self.connectionEpoch = connectionEpoch
        self.capacity = capacity
    }

    var count: Int { entries.count }
    var isFull: Bool { entries.count >= capacity }

    func entry(for command: CommandID) -> Entry? {
        entries[PeerCommandKey(connection: connectionEpoch, command: command)]
    }

    /// Records an admitted intent as pending.
    mutating func reserve(_ intent: CommandIntent,
                          permission: PermissionFingerprint) throws(PeerCommandLedgerError) {
        guard intent.connectionEpoch == connectionEpoch else { throw .wrongConnection }
        let key = PeerCommandKey(connection: connectionEpoch, command: intent.id)
        guard entries[key] == nil else { throw .alreadyRecorded(intent.id) }
        guard !isFull else { throw .full(capacity: capacity) }
        entries[key] = Entry(intent: intent, permission: permission, completion: nil)
    }

    /// Records the applier's completion for a pending command, exactly once.
    mutating func complete(_ command: CommandID,
                           with completion: PeerCommandCompletion) throws(PeerCommandLedgerError) {
        let key = PeerCommandKey(connection: connectionEpoch, command: command)
        guard var entry = entries[key] else { throw .unknownCommand(command) }
        guard entry.completion == nil else { throw .alreadyCompleted(command) }
        entry.completion = completion
        entries[key] = entry
    }
}
