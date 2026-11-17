import Dispatch
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    @Test func overlapCompletesWhileProducerIsHeldAndRoleTransfers() throws {
        let ingress = try MIDICallbackIngress()
        let first = AdmissionGate()
        DispatchQueue.global().async {
            let result = BorrowedPackets([[1]]).send(to: ingress, onNext: first.hold)
            first.result.store(result, ordering: .releasing)
            first.completed.signal()
        }
        defer { first.release.signal() }
        guard first.wait(first.entered) else { return }
        let second = AdmissionGate()
        DispatchQueue.global().async {
            second.result.store(Self.send([[2]], to: ingress), ordering: .releasing)
            second.completed.signal()
        }
        let completedWhileHeld = second.wait(second.completed)
        #expect(completedWhileHeld && !second.accepted)
        first.release.signal()
        guard first.wait(first.completed) else { return }
        #expect(first.accepted)
        let batch = try Self.pop(ingress)
        #expect(batch.packets == [[1]] && batch.afterGap)
        #expect(ingress.storage.descriptors.tryPop() == nil)
        // Another thread acquires the role after the first producer's release.
        let third = AdmissionGate()
        DispatchQueue.global().async {
            third.result.store(Self.send([[3]], to: ingress), ordering: .releasing)
            third.completed.signal()
        }
        guard third.wait(third.completed) else { return }
        #expect(third.accepted)
        #expect(try Self.pop(ingress).packets == [[3]])
    }

    @Test func reentryAndRefusalsOnBothSidesOfGapExchange() throws {
        let ingress = try MIDICallbackIngress()
        let packet = BorrowedPackets([[1]])
        let accepted = packet.send(to: ingress, beforeExchange: {
            #expect(!Self.send([[2]], to: ingress))
        }, afterExchange: {
            #expect(!Self.send([[3]], to: ingress))
        })
        #expect(accepted)
        #expect(try Self.pop(ingress).afterGap)
        #expect(Self.send([[]], to: ingress))
        #expect(Self.send([[4]], to: ingress))
        #expect(try Self.pop(ingress).afterGap)
        #expect(Self.send([[5]], to: ingress))
        #expect(!(try Self.pop(ingress).afterGap))
    }

    @Test func closeDuringAdmittedProducerIsSticky() throws {
        let ingress = try MIDICallbackIngress()
        let gate = AdmissionGate()
        DispatchQueue.global().async {
            let result = BorrowedPackets([[9]]).send(to: ingress, onNext: gate.hold)
            gate.result.store(result, ordering: .releasing)
            gate.completed.signal()
        }
        defer { gate.release.signal() }
        guard gate.wait(gate.entered) else { return }
        ingress.close()
        #expect(!Self.send([[7]], to: ingress))
        gate.release.signal()
        guard gate.wait(gate.completed) else { return }
        #expect(gate.accepted, "admitted work may finish into this old session only")
        #expect(try Self.pop(ingress).packets == [[9]])
        #expect(!Self.send([[8]], to: ingress), "producer exit must clear busy, not closed")
        #expect(ingress.storage.descriptors.tryPop() == nil)
    }
}
