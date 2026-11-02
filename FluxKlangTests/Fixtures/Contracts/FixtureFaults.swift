//
//  FixtureFaults.swift
//  FluxKlangTests
//
//  Scripted fault injection and a bounded call recorder for the contract
//  doubles. Both have fixed limits: the script refuses calls past its limit
//  and the recorder counts every entry it drops.
//

/// A fault a double reports for one scripted call.
enum FixtureFault: Error, Hashable, Sendable {
    case prepareFailed
    case timedOut
    case capacity
    case disconnected
    /// The script's call limit was reached. Reserved: it cannot be scripted.
    case callLimitExceeded
}

/// Why a fault script was not created.
enum FaultScriptError: Error, Equatable, Sendable {
    case invalidCallLimit
    /// A scripted call number outside `1...callLimit`.
    case invalidCall(Int)
    case reservedFault
}

/// Fails exactly the scripted 1-based call numbers and refuses calls past the limit.
struct FaultScript: Hashable, Sendable {
    static var maximumCallLimit: Int { 4_096 }

    let failing: [Int: FixtureFault]
    let callLimit: Int
    private(set) var callCount = 0

    init(failing: [Int: FixtureFault] = [:], callLimit: Int) throws(FaultScriptError) {
        guard (1...Self.maximumCallLimit).contains(callLimit) else { throw .invalidCallLimit }
        if let call = failing.keys.sorted().first(where: { !(1...callLimit).contains($0) }) {
            throw .invalidCall(call)
        }
        guard !failing.values.contains(.callLimitExceeded) else { throw .reservedFault }
        self.failing = failing
        self.callLimit = callLimit
    }

    /// Counts the call, then throws its scripted fault if it has one. A call past
    /// the limit throws `.callLimitExceeded` and is not counted.
    mutating func nextCall() throws(FixtureFault) {
        guard callCount < callLimit else { throw .callLimitExceeded }
        callCount += 1
        if let fault = failing[callCount] { throw fault }
    }
}

enum BoundedRecorderError: Error, Equatable, Sendable {
    case invalidCapacity
}

/// Keeps the first `capacity` entries; later entries are dropped and counted.
struct BoundedRecorder<Element: Sendable>: Sendable {
    static var maximumCapacity: Int { 4_096 }

    let capacity: Int
    private(set) var entries: [Element] = []
    /// Saturates at `Int.max` rather than trapping.
    private(set) var droppedCount = 0

    init(capacity: Int) throws(BoundedRecorderError) {
        guard (1...Self.maximumCapacity).contains(capacity) else { throw .invalidCapacity }
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    /// Returns `false` when the entry was dropped.
    mutating func record(_ element: Element) -> Bool {
        guard entries.count < capacity else {
            if droppedCount < Int.max { droppedCount += 1 }
            return false
        }
        entries.append(element)
        return true
    }
}

extension BoundedRecorder: Equatable where Element: Equatable {}
extension BoundedRecorder: Hashable where Element: Hashable {}
