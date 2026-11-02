import Testing
@testable import FluxKlang

struct ContractFixtureTests {}

extension ContractFixtureTests {
    struct Basics {
        @Test func idSequenceIsDeterministicAndBounded() throws {
            var first = try FixtureIDSequence<ActionTag>(prefix: "action", limit: 3)
            var second = try FixtureIDSequence<ActionTag>(prefix: "action", limit: 3)
            let issued = try (0..<3).map { _ in try first.next() }
            #expect(issued.map(\.rawValue) == ["fx.action.1", "fx.action.2", "fx.action.3"])
            #expect(try (0..<3).map { _ in try second.next() } == issued)
            #expect(first.issuedCount == 3 && first == second)

            let exhausted = first
            #expect(throws: FixtureIDSequenceError.exhausted) { try first.next() }
            #expect(first == exhausted)

            #expect(throws: FixtureIDSequenceError.invalidLimit) {
                try FixtureIDSequence<ActionTag>(prefix: "action", limit: 0)
            }
            #expect(throws: FixtureIDSequenceError.invalidLimit) {
                try FixtureIDSequence<ActionTag>(prefix: "action", limit: FixtureIDSequence<ActionTag>.maximumLimit + 1)
            }
            for prefix in ["", "has space", String(repeating: "p", count: ContractID<ActionTag>.maximumLength)] {
                #expect(throws: FixtureIDSequenceError.invalidPrefix) {
                    try FixtureIDSequence<ActionTag>(prefix: prefix, limit: 1)
                }
            }
        }

        @Test func idSequenceChecksTheLengthOfItsLastID() throws {
            // "fx." + prefix + "." + one digit is exactly 128 bytes; two digits is one too many.
            let prefix = String(repeating: "p", count: ContractID<ActionTag>.maximumLength - 5)
            var single = try FixtureIDSequence<ActionTag>(prefix: prefix, limit: 1)
            let last = try single.next()
            #expect(last.rawValue.utf8.count == ContractID<ActionTag>.maximumLength)

            var nine = try FixtureIDSequence<ActionTag>(prefix: prefix, limit: 9)
            let ids = try (0..<9).map { _ in try nine.next() }
            #expect(ids.last?.rawValue == "fx.\(prefix).9")
            #expect(ids.allSatisfy { $0.rawValue.utf8.count == ContractID<ActionTag>.maximumLength })
            #expect(throws: FixtureIDSequenceError.invalidPrefix) {
                try FixtureIDSequence<ActionTag>(prefix: prefix, limit: 10)
            }
        }

        @Test func limitsAcceptTheirMaximums() throws {
            let maximumLimit = FixtureIDSequence<ActionTag>.maximumLimit
            let sequence = try FixtureIDSequence<ActionTag>(prefix: "max", limit: maximumLimit)
            #expect(sequence.limit == maximumLimit)

            var recorder = try BoundedRecorder<Int>(capacity: BoundedRecorder<Int>.maximumCapacity)
            var accepted = 0
            for value in 0..<BoundedRecorder<Int>.maximumCapacity where recorder.record(value) { accepted += 1 }
            let overflowAccepted = recorder.record(-1)
            #expect(accepted == BoundedRecorder<Int>.maximumCapacity && !overflowAccepted)
            #expect(recorder.entries.count == BoundedRecorder<Int>.maximumCapacity && recorder.droppedCount == 1)

            let limit = FaultScript.maximumCallLimit
            var script = try FaultScript(failing: [limit: .capacity], callLimit: limit)
            for _ in 1..<limit { try script.nextCall() }
            #expect(throws: FixtureFault.capacity) { try script.nextCall() }
            #expect(throws: FixtureFault.callLimitExceeded) { try script.nextCall() }
            #expect(script.callCount == limit)
        }

        @Test func fixedIDsAndStatesAreStable() {
            let raw = [
                ContractFixtureIDs.host.rawValue, ContractFixtureIDs.device.rawValue,
                ContractFixtureIDs.primaryClock.rawValue, ContractFixtureIDs.musicalClock.rawValue,
                ContractFixtureIDs.action.rawValue, ContractFixtureIDs.capability.rawValue,
                ContractFixtureIDs.stream.rawValue
            ]
            #expect(Set(raw).count == raw.count)
            #expect(raw.allSatisfy { $0.hasPrefix("fx.") })
            #expect(ContractFixtureIDs.host.rawValue == "fx.host")
            #expect(ContractFixtureState.allCases == [.available, .missing, .stale, .failed, .pressured])
        }

        @Test func hostClockIsMonotonicAndRepeatable() throws {
            let timebase = HostTimebase(numer: 125, denom: 3)
            var first = try FixtureHostClock(startTicks: 1_000, step: 24, timebase: timebase)
            var second = try FixtureHostClock(startTicks: 1_000, step: 24, timebase: timebase)
            #expect(first.now == HostStamp(ticks: 1_000) && first.timebase == timebase)
            let ticks = try (0..<4).map { _ in try first.tick().ticks }
            #expect(ticks == [1_024, 1_048, 1_072, 1_096])
            #expect(try (0..<4).map { _ in try second.tick().ticks } == ticks)

            let anchor = first.anchor(frame: 480, generation: .initial, clock: ContractFixtureIDs.primaryClock)
            #expect(anchor.host == first.now && anchor.musical == nil)
            let clock = ContractFixtureIDs.primaryClock
            #expect(anchor.sample == SampleStamp(clock: clock, generation: .initial, frame: 480))
            #expect(anchor == second.anchor(frame: 480))

            var edge = try FixtureHostClock(startTicks: .max - 1, step: 1, timebase: timebase)
            #expect(try edge.tick() == HostStamp(ticks: .max))
            let saturated = edge
            #expect(throws: FixtureClockError.exhausted) { try edge.tick() }
            #expect(edge == saturated)

            #expect(throws: FixtureClockError.invalidStep) {
                try FixtureHostClock(startTicks: 0, step: 0, timebase: timebase)
            }
            for invalid in [HostTimebase(numer: 0, denom: 1), HostTimebase(numer: 1, denom: 0)] {
                #expect(throws: FixtureClockError.invalidTimebase) {
                    try FixtureHostClock(startTicks: 0, step: 1, timebase: invalid)
                }
            }
        }

        @Test func boundedRecorderDropsBeyondCapacityAndCounts() throws {
            var recorder = try BoundedRecorder<Int>(capacity: 2)
            #expect(recorder.record(1) && recorder.record(2))
            #expect(!recorder.record(3) && !recorder.record(4))
            #expect(recorder.entries == [1, 2] && recorder.droppedCount == 2)
            #expect(recorder.capacity == 2)

            #expect(throws: BoundedRecorderError.invalidCapacity) { try BoundedRecorder<Int>(capacity: 0) }
            #expect(throws: BoundedRecorderError.invalidCapacity) {
                try BoundedRecorder<Int>(capacity: BoundedRecorder<Int>.maximumCapacity + 1)
            }
        }

        @Test func faultScriptFailsOnlyScriptedCalls() throws {
            var script = try FaultScript(failing: [2: .prepareFailed, 4: .disconnected], callLimit: 5)
            var results: [FixtureFault?] = []
            for _ in 0..<5 {
                do {
                    try script.nextCall()
                    results.append(nil)
                } catch {
                    results.append(error)
                }
            }
            #expect(results == [nil, .prepareFailed, nil, .disconnected, nil])
            #expect(script.callCount == 5)

            var replay = try FaultScript(failing: [2: .prepareFailed, 4: .disconnected], callLimit: 5)
            try replay.nextCall()
            #expect(throws: FixtureFault.prepareFailed) { try replay.nextCall() }

            var clean = try FaultScript(callLimit: 3)
            for _ in 0..<3 { try clean.nextCall() }
            #expect(clean.callCount == 3 && clean.failing.isEmpty)
        }

        @Test func faultScriptRefusesCallsBeyondLimit() throws {
            var script = try FaultScript(failing: [1: .timedOut], callLimit: 2)
            #expect(throws: FixtureFault.timedOut) { try script.nextCall() }
            try script.nextCall()
            let exhausted = script
            #expect(throws: FixtureFault.callLimitExceeded) { try script.nextCall() }
            #expect(throws: FixtureFault.callLimitExceeded) { try script.nextCall() }
            #expect(script == exhausted && script.callCount == 2)

            #expect(throws: FaultScriptError.invalidCallLimit) { try FaultScript(failing: [:], callLimit: 0) }
            #expect(throws: FaultScriptError.invalidCallLimit) {
                try FaultScript(failing: [:], callLimit: FaultScript.maximumCallLimit + 1)
            }
            for call in [0, 3] {
                #expect(throws: FaultScriptError.invalidCall(call)) {
                    try FaultScript(failing: [call: .capacity], callLimit: 2)
                }
            }
            #expect(throws: FaultScriptError.reservedFault) {
                try FaultScript(failing: [1: .callLimitExceeded], callLimit: 2)
            }
        }
    }
}
