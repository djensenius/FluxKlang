enum MIDI1NoteRelease: Equatable, Sendable {
    case notHeld
    case sustained
    case released
}

enum MIDI1HeldNotePhase: Equatable, Hashable, Sendable {
    case keyDown
    /// Released by the key but held by the sustain pedal (CC 64).
    case sustained
}

struct MIDI1HeldNote: Equatable, Hashable, Sendable {
    let note: UInt8
    let velocity: UInt8
    let phase: MIDI1HeldNotePhase
}

/// Bounded held notes for one channel, kept in ascending note order with unique notes.
struct MIDI1HeldNotes: Equatable, Sendable {
    static let capacity = 128

    private(set) var notes: [MIDI1HeldNote] = []

    init() {}

    /// Refuses unsorted, duplicate or out-of-range notes, zero velocity, or more than `limit` notes.
    init?(notes: [MIDI1HeldNote], limit: Int, sustainDown: Bool) {
        guard notes.count <= min(limit, Self.capacity) else { return nil }
        for (index, held) in notes.enumerated() {
            guard held.note < 0x80, (1...0x7F).contains(held.velocity) else { return nil }
            guard held.phase == .keyDown || sustainDown else { return nil }
            guard index == 0 || notes[index - 1].note < held.note else { return nil }
        }
        self.notes = notes
    }

    func phase(of note: UInt8) -> MIDI1HeldNotePhase? {
        notes.first { $0.note == note }?.phase
    }

    /// Returns false, unchanged, when a new note would exceed `limit`. A retrigger replaces the held note.
    mutating func press(note: UInt8, velocity: UInt8, limit: Int) -> Bool {
        let pressed = MIDI1HeldNote(note: note, velocity: velocity, phase: .keyDown)
        if let index = notes.firstIndex(where: { $0.note == note }) {
            notes[index] = pressed
            return true
        }
        guard notes.count < limit else { return false }
        let index = notes.firstIndex { $0.note > note } ?? notes.endIndex
        notes.insert(pressed, at: index)
        return true
    }

    /// Only a key-down note is affected; a note already held by the pedal stays sustained.
    mutating func release(note: UInt8, sustainDown: Bool) -> MIDI1NoteRelease {
        guard let index = notes.firstIndex(where: { $0.note == note && $0.phase == .keyDown }) else {
            return .notHeld
        }
        if sustainDown {
            notes[index] = MIDI1HeldNote(note: note, velocity: notes[index].velocity, phase: .sustained)
            return .sustained
        }
        notes.remove(at: index)
        return .released
    }

    /// Pedal up: removes every sustained note.
    mutating func releaseSustained() -> [UInt8] {
        remove { $0.phase == .sustained }
    }

    /// All Notes Off: key-down notes become sustained while the pedal is down, otherwise they are removed.
    mutating func releaseKeys(sustainDown: Bool) -> [UInt8] {
        guard sustainDown else { return remove { $0.phase == .keyDown } }
        notes = notes.map { MIDI1HeldNote(note: $0.note, velocity: $0.velocity, phase: .sustained) }
        return []
    }

    /// All Sound Off: removes every note.
    mutating func clear() -> [UInt8] {
        remove { _ in true }
    }

    private mutating func remove(where predicate: (MIDI1HeldNote) -> Bool) -> [UInt8] {
        let removed = notes.filter(predicate).map(\.note)
        notes.removeAll(where: predicate)
        return removed
    }
}
