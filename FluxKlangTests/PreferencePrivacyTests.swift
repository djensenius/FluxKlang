//
//  PreferencePrivacyTests.swift
//  FluxKlangTests
//
//  Storage classes and the key-value allowlist (#124 PR1): the builders and the seeded generator that every
//  PreferencePrivacyTests+*.swift file shares. Nothing here touches UserDefaults, the file system, the
//  Keychain, CloudKit or any other storage; the lane under test is pure tables and policy functions.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct PreferencePrivacyTests {
    /// What `evaluate` produced: one plan or one refusal.
    enum Outcome: Equatable {
        case plan(KeyValuePlan)
        case refused(KeyValueRefusal)
    }

    /// A fixed-seed generator for shuffles (SplitMix64). Tests never read a clock or a random source.
    struct Generator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    static let allClasses = StorageClass.allCases
    static let eligibleClasses: [StorageClass] = [.homeWiring, .environment, .catalog]
    static let ineligibleClasses: [StorageClass] = [
        .preference, .draft, .history, .pluginState, .media, .trust, .credential, .hostLocalRoute, .cache
    ]

    static func key(_ raw: String) throws -> KeyValueKey { try KeyValueKey(raw) }

    static func request(_ raw: String, _ storageClass: StorageClass = .catalog, bytes: Int) throws -> KeyValueRequest {
        KeyValueRequest(key: try key(raw), storageClass: storageClass, valueBytes: bytes)
    }

    static func entry(_ raw: String, _ storageClass: StorageClass = .catalog, bytes: Int = 100) throws
        -> KeyValueAllowlistEntry {
        KeyValueAllowlistEntry(key: try key(raw), storageClass: storageClass, maxValueBytes: bytes)
    }

    static func limits(
        keyBytes: Int = 64, entries: Int = 64, value: Int = 1_000, total: Int = 10_000
    ) throws -> KeyValueLimits {
        try KeyValueLimits(
            maximumKeyBytes: keyBytes, maximumEntries: entries, maximumValueBytes: value, maximumTotalBytes: total)
    }

    /// `store.k0`, `store.k1`, ... `store.k<count-1>`.
    static func numberedKeys(_ count: Int) -> [String] { (0..<count).map { "store.k\($0)" } }

    static func numberedEntries(_ count: Int, bytes: Int = 1) throws -> [KeyValueAllowlistEntry] {
        try numberedKeys(count).map { try entry($0, bytes: bytes) }
    }

    /// The list `a` (catalog, cap 100), `b` (environment, cap 200) and `c` (homeWiring, cap 300), built with
    /// generous limits so that the admission limits of a test decide.
    static func listABC() throws -> KeyValueAllowlist {
        try KeyValueAllowlist(
            entries: [
                try entry("store.a", .catalog, bytes: 100),
                try entry("store.b", .environment, bytes: 200),
                try entry("store.c", .homeWiring, bytes: 300)
            ],
            limits: try limits(entries: 64, value: 1_000, total: 10_000))
    }

    /// The refusal that `body` throws, or nil when it returns.
    static func refusal<T>(_ body: () throws -> T) -> KeyValueRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? KeyValueRefusal
        }
    }

    static func admit(
        _ writes: [KeyValueRequest],
        _ list: KeyValueAllowlist,
        _ limits: KeyValueLimits = .standard,
        resident: [KeyValueRequest] = []
    ) -> Outcome {
        do {
            return .plan(try KeyValueAdmission.evaluate(writes, against: list, limits: limits, resident: resident))
        } catch {
            return .refused(error)
        }
    }

    static func plan(_ outcome: Outcome) -> KeyValuePlan? {
        if case let .plan(plan) = outcome { return plan }
        return nil
    }

    /// Every order of `items` (Heap's algorithm; 120 orders for five items).
    static func permutations<T>(_ items: [T]) -> [[T]] {
        var work = items
        var result: [[T]] = []
        func heap(_ count: Int) {
            if count <= 1 {
                result.append(work)
                return
            }
            heap(count - 1)
            for index in 0..<(count - 1) {
                work.swapAt(count.isMultiple(of: 2) ? index : 0, count - 1)
                heap(count - 1)
            }
        }
        heap(work.count)
        return result
    }

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var generator = Generator(seed: seed)
        var result = items
        for index in result.indices.reversed().dropLast() {
            result.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }
        return result
    }
}
