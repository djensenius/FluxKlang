// #64 X1 catalog: one declared kernel queue. Control-side only; not RT-certified.

/// One queue as a caller declares it. A plain carrier: `KernelQueueCatalog.make` re-validates every field.
struct KernelQueueDeclaration: Sendable, Equatable {
    /// Bytes of `name.utf8`: a first byte in `a-z`, then `a-z`, `0-9`, `.`, `_` or `-`; 1...64 bytes.
    let name: String
    let policy: HandoffPolicy
    /// `true` when the queue may carry a note release, so the note-reserve rule applies.
    let carriesNotes: Bool
    /// Bytes per element, from the caller (for example `MemoryLayout<T>.stride`); at least 1.
    let elementStride: Int
}
