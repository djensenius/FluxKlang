import Dispatch
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    /// Fixture owns allocation; the cursor borrows it only for the synchronous receive call.
    final class BorrowedPackets {
        let bytes: UnsafeMutablePointer<UInt8>
        let lengths: [Int]
        let count: Int

        init(_ packets: [[UInt8]]) {
            lengths = packets.map(\.count)
            count = lengths.reduce(0, +)
            bytes = .allocate(capacity: max(count, 1))
            bytes.initialize(repeating: 0, count: max(count, 1))
            var offset = 0
            for packet in packets {
                for byte in packet {
                    bytes[offset] = byte
                    offset += 1
                }
            }
        }

        deinit { bytes.deallocate() }

        func send(
            to ingress: MIDICallbackIngress, token: UInt = 0, onNext: (() -> Void)? = nil,
            beforeExchange: (() -> Void)? = nil, afterExchange: (() -> Void)? = nil
        ) -> Bool {
            var cursor = FixtureCursor(bytes: bytes, lengths: lengths, onNext: onNext)
            return ingress.receive(
                &cursor, rawToken: token, beforeExchange: beforeExchange, afterExchange: afterExchange
            )
        }

    }

    struct FixtureCursor: MIDIBorrowedPacketCursor {
        let bytes: UnsafePointer<UInt8>
        let lengths: [Int]
        var onNext: (() -> Void)?
        var index = 0
        var offset = 0
        var packetCount: Int { lengths.count }

        mutating func next() -> UnsafeBufferPointer<UInt8> {
            onNext?()
            let count = lengths[index]
            defer {
                offset += count
                index += 1
            }
            return UnsafeBufferPointer(start: bytes.advanced(by: offset), count: count)
        }
    }

    @discardableResult
    static func send(_ packets: [[UInt8]], to ingress: MIDICallbackIngress, token: UInt = 0) -> Bool {
        BorrowedPackets(packets).send(to: ingress, token: token)
    }

    static func pop(_ ingress: MIDICallbackIngress) throws -> MIDIPacketBatch {
        let descriptor = try #require(ingress.storage.descriptors.tryPop())
        return ingress.storage.copyAndAcknowledge(descriptor)
    }

    /// Bounded waits fail missing completion, never hang a mutant. No wall-clock delay proves nonwaiting.
    final class AdmissionGate: Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = Atomic<Bool>(false)
        var accepted: Bool { result.load(ordering: .acquiring) }

        func hold() {
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
        }

        func wait(_ semaphore: DispatchSemaphore) -> Bool {
            let success = semaphore.wait(timeout: .now() + 5) == .success
            #expect(success)
            return success
        }
    }

    @MainActor
    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        let satisfied = condition()
        #expect(satisfied)
        return satisfied
    }
}
