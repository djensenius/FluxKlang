// #64 X1 catalog: structural caps on a declared queue list. Control-side only; not RT-certified.

/// Structural list caps for `KernelQueueCatalog`. They bound the work and memory of building a catalog; they are not
/// kernel policy and no queue is sized from them.
enum KernelQueueCatalogLimits {
    /// Largest number of declared queues in one catalog (inclusive).
    static let maximumQueues = 256
    /// Largest queue name length, in UTF-8 bytes (inclusive).
    static let maximumNameBytes = 64
}
