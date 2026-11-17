import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    @MainActor
    @Test func manualTurnsBoundBatchesBytesAndCarryWithoutReuse() throws {
        let delivery = MIDICallbackDelivery(automaticallyDrive: false)
        let ingress = try MIDICallbackIngress(batches: 128)
        var handled: [MIDIPacketBatch] = []
        delivery.start(ingress, reconcile: {}, handler: { handled.append($0) })
        for value in 0..<65 { #expect(Self.send([[UInt8(value)]], to: ingress)) }
        delivery.tick()
        #expect(handled.count == 64)
        delivery.tick()
        #expect(handled.map(\.packets) == (0..<65).map { [[UInt8($0)]] })
        delivery.stop()

        let small = try MIDICallbackIngress(batches: 2, bytes: 131_072)
        handled = []
        delivery.start(small, reconcile: {}, handler: { handled.append($0) })
        let large = Array(repeating: UInt8(11), count: 65_535)
        #expect(Self.send([[10, 10]], to: small))
        #expect(Self.send([large], to: small))
        delivery.tick() // second descriptor popped but carried: 2 + 65,535 exceeds one turn
        #expect(handled.map(\.packets) == [[[10, 10]]])
        #expect(small.storage.descriptors.tryPop() == nil)
        #expect(Self.send([[12]], to: small))
        #expect(!Self.send([[13]], to: small), "carried descriptor still consumes batch capacity")
        delivery.tick()
        #expect(handled.map(\.packets) == [[[10, 10]], [large], [[12]]])
        #expect(Self.send([[14]], to: small))
        delivery.tick()
        #expect(handled.last?.afterGap == true)
        delivery.stop()
    }

    @MainActor
    @Test func sourceReconciliationPrecedesDataAndReentrantStopEndsTurn() throws {
        let delivery = MIDICallbackDelivery(automaticallyDrive: false)
        let ingress = try MIDICallbackIngress()
        var log: [String] = []
        delivery.start(ingress, reconcile: { log.append("sources") }, handler: { _ in
            log.append("data")
            delivery.stop()
        })
        ingress.sourcesChanged()
        #expect(Self.send([[1]], to: ingress))
        #expect(Self.send([[2]], to: ingress))
        delivery.tick()
        delivery.tick()
        #expect(log == ["sources", "data"])
        #expect(!Self.send([[3]], to: ingress))

        let next = try MIDICallbackIngress()
        delivery.start(next, reconcile: { delivery.stop() }, handler: { _ in log.append("forbidden") })
        next.sourcesChanged()
        #expect(Self.send([[4]], to: next))
        delivery.tick()
        #expect(log == ["sources", "data"])
    }

    @MainActor
    @Test func restartTokenOneAndRetainedOldCallbackStaySessionLocal() throws {
        let delivery = MIDICallbackDelivery(automaticallyDrive: false)
        var old: MIDICallbackIngress? = try MIDICallbackIngress()
        weak let retained = old
        var callback: (() -> Bool)? = { [session = try #require(old)] in
            session.sourcesChanged()
            return Self.send([[1]], to: session, token: 1)
        }
        var log: [MIDIPacketBatch] = []
        var reconciliations = 0
        delivery.start(try #require(old), reconcile: { reconciliations += 1 }, handler: { log.append($0) })
        #expect(callback?() == true)
        delivery.stop()
        old = nil
        #expect(retained != nil)
        let next = try MIDICallbackIngress()
        delivery.start(next, reconcile: { reconciliations += 1 }, handler: { log.append($0) })
        #expect(callback?() == false)
        #expect(Self.send([[2]], to: next, token: 1))
        delivery.tick()
        #expect(log.map(\.packets) == [[[2]]])
        #expect(log.first?.source?.rawValue == 1 && reconciliations == 0)
        callback = nil
        #expect(retained == nil, "no retired-session leak list")
        delivery.stop()
    }

    @MainActor
    @Test func idleWaitWakesOnStartAndCancellationReleasesWaiter() async throws {
        let wake = MIDIConsumerWake()
        var completed = false
        let waiter = Task { await wake.wait(); completed = true }
        guard await Self.eventually({ wake.isWaiting || completed }) else {
            waiter.cancel()
            await waiter.value
            return
        }
        #expect(wake.isWaiting && !completed)
        wake.setActive(true)
        _ = await Self.eventually { completed }
        wake.finish() // Release the task even if the start-resumption mutation failed.
        await waiter.value
        #expect(completed && !wake.isWaiting)
        let cancelledWake = MIDIConsumerWake()
        completed = false
        let cancelled = Task { await cancelledWake.wait(); completed = true }
        _ = await Self.eventually { cancelledWake.isWaiting || completed }
        #expect(!completed)
        cancelled.cancel()
        _ = await Self.eventually { completed }
        cancelledWake.setActive(true) // Completion-aware escape if cancellation release is broken.
        await cancelled.value
        #expect(completed && !cancelledWake.isWaiting)
    }

    @MainActor
    @Test func reusableDriverSuspendsAcrossRestartsWithoutRetainingIdleOwner() async throws {
        var driver: MIDICallbackDelivery? = MIDICallbackDelivery()
        weak let weakDriver = driver
        guard await Self.eventually({ driver?.isIdleWaiting == true }) else { return }
        for _ in 0..<8 {
            let session = try MIDICallbackIngress()
            var delivered = false
            driver?.start(session, reconcile: {}, handler: { _ in delivered = true })
            #expect(Self.send([[1]], to: session))
            _ = await Self.eventually { delivered }
            driver?.stop()
            _ = await Self.eventually { driver?.isIdleWaiting == true }
            #expect(!Self.send([[2]], to: session))
        }
        driver = nil
        #expect(weakDriver == nil, "task must not keep an owner alive across indefinite idle await")
    }
}
