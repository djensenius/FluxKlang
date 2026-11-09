// #64 X1 catalog: a validated set of declared kernel queues. Control-side only: it allocates no queue, runs
// nothing and is never called from the render path. Advisory data for a later probe; not RT-certified.

/// A validated list of declared kernel queues with an exact payload-memory total.
///
/// The only way to build one is `make`, which checks every declaration (name, stride, `HandoffPolicy.validate()`,
/// the note-reserve rule, payload bytes, duplicate names), totals the payload bytes with overflow-checked integer
/// arithmetic and compares the total with a caller budget. Nothing is defaulted: every capacity, stride, reserve and
/// budget comes from the caller.
struct KernelQueueCatalog: Sendable, Equatable {
    private let entries: [KernelQueueDeclaration]
    private let sizes: [Int]
    private let indexByName: [[UInt8]: Int]
    /// The sum of `capacity * elementStride` over the queues. Payload bytes only: ring headers, atomics, padding,
    /// fault latches and alignment slack are not counted, so this is a lower bound and not an allocation size.
    let totalBytes: Int
    let byteBudget: Int

    private init(entries: [KernelQueueDeclaration], sizes: [Int], indexByName: [[UInt8]: Int],
                 totalBytes: Int, byteBudget: Int) {
        self.entries = entries
        self.sizes = sizes
        self.indexByName = indexByName
        self.totalBytes = totalBytes
        self.byteBudget = byteBudget
    }

    /// Refuses with the first defect: a budget below 1, more than `maximumQueues` declarations (both before any
    /// declaration is inspected), then declarations in index order (inside one: name, stride, policy, note
    /// reserve, queue bytes, duplicate name, running total), and last a total above the budget. An empty list
    /// with a valid budget is a valid empty catalog.
    static func make(
        declarations: [KernelQueueDeclaration], byteBudget: Int
    ) throws(KernelQueueCatalogRefusal) -> KernelQueueCatalog {
        guard byteBudget >= 1 else { throw .invalidByteBudget(byteBudget) }
        guard declarations.count <= KernelQueueCatalogLimits.maximumQueues else {
            throw .tooManyQueues(declarations.count)
        }
        var sizes: [Int] = []
        sizes.reserveCapacity(declarations.count)
        var indexByName: [[UInt8]: Int] = [:]
        indexByName.reserveCapacity(declarations.count)
        var total = 0
        for (index, declaration) in declarations.enumerated() {
            let checked = try check(declaration, index: index)
            guard indexByName[checked.key] == nil else { throw .duplicateName(index: index) }
            let (sum, overflow) = total.addingReportingOverflow(checked.bytes)
            guard !overflow else { throw .totalBytesOverflow(index: index) }
            total = sum
            sizes.append(checked.bytes)
            indexByName[checked.key] = index
        }
        guard total <= byteBudget else { throw .overBudget(totalBytes: total, byteBudget: byteBudget) }
        return KernelQueueCatalog(entries: declarations, sizes: sizes, indexByName: indexByName,
                                  totalBytes: total, byteBudget: byteBudget)
    }

    /// The declarations in the order they were given.
    var declarations: [KernelQueueDeclaration] { entries }

    /// `byteBudget - totalBytes`; never negative because `make` refuses a total above the budget.
    var headroomBytes: Int { byteBudget - totalBytes }

    /// The position of the queue whose name has exactly these UTF-8 bytes, or `nil`.
    func index(ofName name: String) -> Int? {
        guard name.utf8.count <= KernelQueueCatalogLimits.maximumNameBytes else { return nil }
        return indexByName[Array(name.utf8)]
    }

    /// The payload bytes of the queue at `index`, or `nil` when the index is out of range.
    func bytes(at index: Int) -> Int? {
        guard sizes.indices.contains(index) else { return nil }
        return sizes[index]
    }
}

extension KernelQueueCatalog {
    private struct CheckedQueue {
        let key: [UInt8]
        let bytes: Int
    }

    private static let leadBytes = UInt8(ascii: "a")...UInt8(ascii: "z")
    private static let digitBytes = UInt8(ascii: "0")...UInt8(ascii: "9")

    private static func check(
        _ declaration: KernelQueueDeclaration, index: Int
    ) throws(KernelQueueCatalogRefusal) -> CheckedQueue {
        guard isValidName(declaration.name) else { throw .invalidName(index: index) }
        guard declaration.elementStride >= 1 else {
            throw .invalidElementStride(index: index, stride: declaration.elementStride)
        }
        do throws(HandoffPolicyError) {
            try declaration.policy.validate()
        } catch {
            throw .policy(index: index, error)
        }
        if declaration.carriesNotes, let defect = noteDefect(declaration.policy) {
            throw .noteReserve(index: index, defect)
        }
        let (bytes, overflow) = declaration.policy.capacity.multipliedReportingOverflow(by: declaration.elementStride)
        guard !overflow else { throw .queueBytesOverflow(index: index) }
        return CheckedQueue(key: Array(declaration.name.utf8), bytes: bytes)
    }

    /// The length is checked before any byte is read, so a long name costs one `utf8.count`.
    private static func isValidName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard bytes.count >= 1, bytes.count <= KernelQueueCatalogLimits.maximumNameBytes,
              let first = bytes.first, leadBytes.contains(first) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            leadBytes.contains(byte) || digitBytes.contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// The note-reserve rule for a policy that already passed `validate()`: purpose, overflow kind, fan-in
    /// ordering, divisibility, then the per-lane minimum. A single producer is one lane.
    private static func noteDefect(_ policy: HandoffPolicy) -> NoteReserveDefect? {
        guard policy.purpose == .events else { return .notAnEventsQueue }
        guard case .reservedCritical(let reserved) = policy.overflow else { return .reserveMissing }
        let lanes = policy.producers.maximum
        if lanes > 1 {
            guard policy.ordering == .fifoPerProducer else { return .multiProducerNeedsPerProducerLanes }
            guard policy.capacity % lanes == 0, reserved % lanes == 0 else { return .lanesDoNotDivide }
        }
        let perLane = reserved / lanes
        guard perLane >= KernelLimits.minimumCriticalReserve else { return .reserveBelowMinimum(perLane) }
        return nil
    }
}
