import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Per-endpoint keying (#81, slice D2): the pure bindings mapper, the stream it feeds and the controller's resets.
/// Records come from the fake directory and connections from a recording input; nothing calls CoreMIDI.
extension CoreMIDIAdapterTests {
    static let legacyKey = MIDIEndpointKey(fingerprint: 0)

    static func bind(
        _ records: [CoreMIDIEndpointRecord], after bindings: CoreMIDIEndpointBindings = CoreMIDIEndpointBindings()
    ) -> CoreMIDIEndpointBindings.Update {
        bindings.update(with: reconcile(records, connected: bindings.connectedRefs))
    }

    static func token(_ rawValue: UInt) throws -> MIDIConnectionToken {
        try #require(MIDIConnectionToken(rawValue: rawValue))
    }

    static func connected(_ rawValue: UInt, _ name: String, fingerprint: UInt64?) throws -> MIDIConnectedSource {
        MIDIConnectedSource(
            token: try token(rawValue), endpoint: fingerprint.map { MIDIEndpointKey(fingerprint: $0) }, name: name
        )
    }

    /// The token the update bound to `ref`.
    static func token(of ref: UInt32, in update: CoreMIDIEndpointBindings.Update) throws -> MIDIConnectionToken {
        try #require(update.bindings.bindings.first { $0.ref == ref }).source.token
    }

    static func cc(_ controller: UInt8, _ value: UInt8) -> MIDI1Event {
        .channel(status: 0xBF, data1: controller, data2: value)
    }

    @Test func aUniqueFingerprintRegistersUnderItsOwnEndpointKey() throws {
        let record = Self.source(10, "Launch Control XL")
        let update = Self.bind([record])
        let key = MIDIEndpointKey(fingerprint: record.fingerprint)
        #expect(update.detaches.isEmpty)
        try #require(update.registrations.count == 1)
        let registration = update.registrations[0]
        #expect(registration.ref == 10)
        #expect(registration.source == MIDIConnectedSource(
            token: try Self.token(1), endpoint: key, name: record.displayName
        ))
        #expect(update.bindings.sources == [registration.source])

        var stream = try LaunchControlXLStream.make()
        let sharedChanged = stream.connect(update.bindings.sources)
        #expect(!sharedChanged)
        #expect(stream.sources == update.bindings.sources)
        #expect(stream.snapshot.sources.map(\.key) == [Self.legacyKey, key])
    }

    /// Mutation (a): routing every batch to one source lets A's `7F` complete B's `BF 06`.
    @Test func twoEndpointsSplitBytesNeverFrameEachOther() throws {
        let update = Self.bind([Self.source(10, "Launch Control XL"), Self.source(20, "Launch Control XL")])
        var stream = try LaunchControlXLStream.make()
        stream.connect(update.bindings.sources)
        let first = try Self.token(of: 10, in: update)
        let second = try Self.token(of: 20, in: update)
        #expect(first != second)

        #expect(stream.feed(packets: [[0xBF, 5]], from: first).isEmpty)
        #expect(stream.feed(packets: [[0xBF, 6]], from: second).isEmpty)
        let completedFirst = stream.feed(packets: [[127]], from: first)
        let completedSecond = stream.feed(packets: [[64]], from: second)
        #expect(completedFirst.map(\.event) == [Self.cc(5, 127)])
        #expect(completedSecond.map(\.event) == [Self.cc(6, 64)])
        #expect(Set(completedFirst.map(\.input) + completedSecond.map(\.input)).count == 2)
        #expect(stream.feed(packets: [[127]]).isEmpty, "the legacy source saw none of it")
        #expect(stream.droppedBatches == 0)
    }

    @Test func aDisappearingEndpointIsDetachedAndItsLateBatchIsDropped() throws {
        let first = Self.bind([Self.source(10, "Launch Control XL"), Self.source(20, "Launch Control XL")])
        var stream = try LaunchControlXLStream.make()
        stream.connect(first.bindings.sources)
        let gone = try Self.token(of: 10, in: first)
        let stays = try Self.token(of: 20, in: first)

        let second = Self.bind([Self.source(20, "Launch Control XL")], after: first.bindings)
        #expect(second.detaches.map(\.ref) == [10])
        #expect(second.detaches.map(\.source.token) == [gone])
        #expect(second.registrations.isEmpty)
        #expect(second.bindings.sources.map(\.token) == [stays])
        let sharedChanged = stream.connect(second.bindings.sources)
        #expect(!sharedChanged)
        #expect(stream.snapshot.sources.count == 2)

        #expect(stream.feed(packets: [[0xBF, 5, 127]], from: gone).isEmpty)
        #expect(stream.droppedBatches == 1)
        #expect(stream.feed(packets: [[0xBF, 5, 127]], from: stays).map(\.event) == [Self.cc(5, 127)])
        #expect(stream.feed(packets: [[0xBF, 5, 127]]).map(\.input) == [LaunchControlXLStream.input])
        #expect(stream.droppedBatches == 1)
    }

    /// Mutation (b): registering before detaching meets the old unit's key and refuses the replug as ambiguous.
    @Test func aReplugUnderANewRefIsAFreshSourceNotAnAmbiguity() throws {
        let before = Self.source(10, "Launch Control XL", uniqueID: 77)
        let after = Self.source(30, "Launch Control XL", uniqueID: 77)
        let key = MIDIEndpointKey(fingerprint: before.fingerprint)
        let first = Self.bind([before])
        var stream = try LaunchControlXLStream.make()
        stream.connect(first.bindings.sources)
        let old = try Self.token(of: 10, in: first)
        #expect(stream.feed(packets: [[0xBF, 5]], from: old).isEmpty)

        let second = Self.bind([after], after: first.bindings)
        #expect(second.detaches.map(\.ref) == [10])
        try #require(second.registrations.count == 1)
        let replugged = second.registrations[0].source
        #expect(second.registrations[0].ref == 30)
        #expect(replugged.token == (try Self.token(2)))
        #expect(replugged.endpoint == key)
        let sharedChanged = stream.connect(second.bindings.sources)
        #expect(!sharedChanged)
        #expect(stream.sources == [replugged], "the replug is resolved, not refused as ambiguous")
        #expect(stream.snapshot.sources.map(\.key) == [Self.legacyKey, key])
        #expect(stream.feed(packets: [[127]], from: replugged.token).isEmpty, "no half message crossed the replug")
        #expect(stream.feed(packets: [[0xBF, 5, 127]], from: replugged.token).map(\.event) == [Self.cc(5, 127)])
    }

    @Test func aFingerprintChangeOnTheSameRefDetachesAndRegisters() throws {
        let first = Self.bind([Self.source(10, "Launch Control XL", manufacturer: "Acme")])
        let changed = Self.source(10, "Launch Control XL", manufacturer: "Other")
        let second = Self.bind([changed], after: first.bindings)
        #expect(second.detaches == first.bindings.bindings)
        try #require(second.registrations.count == 1)
        #expect(second.registrations[0].ref == 10)
        #expect(second.registrations[0].source.token == (try Self.token(2)))
        #expect(second.registrations[0].source.endpoint == MIDIEndpointKey(fingerprint: changed.fingerprint))

        var stream = try LaunchControlXLStream.make()
        stream.connect(first.bindings.sources)
        let old = try Self.token(1)
        #expect(stream.feed(packets: [[0xBF, 5]], from: old).isEmpty)
        stream.connect(second.bindings.sources)
        let changedKey = MIDIEndpointKey(fingerprint: changed.fingerprint)
        #expect(stream.snapshot.sources.map(\.key) == [Self.legacyKey, changedKey])
        #expect(stream.feed(packets: [[127]], from: old).isEmpty)
        #expect(stream.droppedBatches == 1)
        #expect(stream.feed(packets: [[127]], from: try Self.token(2)).isEmpty)

        let renamed = Self.bind([Self.source(10, "Launch Control XL 2", manufacturer: "Other")], after: second.bindings)
        #expect(renamed.detaches.isEmpty && renamed.registrations.isEmpty)
        #expect(renamed.bindings.sources.map(\.token) == [try Self.token(2)])
        #expect(renamed.bindings.sources.map(\.name) == ["Launch Control XL 2"])
    }

    @Test func tokensAreNeverZeroNeverReusedAndSurviveTheRefConRoundTrip() throws {
        #expect(MIDIConnectionToken(rawValue: 0) == nil)
        #expect(MIDIConnectionToken(refCon: nil) == nil)
        for rawValue: UInt in [1, 2, 0xFFFF, UInt.max] {
            let token = try Self.token(rawValue)
            #expect(token.refCon != nil)
            #expect(MIDIConnectionToken(refCon: token.refCon) == token)
        }

        let steps: [[CoreMIDIEndpointRecord]] = [
            [Self.source(10, "Launch Control XL")],
            [Self.source(10, "Launch Control XL"), Self.source(20, "Launch Control XL")],
            [Self.source(20, "Launch Control XL")],
            [Self.source(10, "Launch Control XL"), Self.source(20, "Launch Control XL", manufacturer: "Other")],
            [Self.source(30, "Launch Control XL", uniqueID: 10), Self.source(20, "Launch Control XL")]
        ]
        var bindings = CoreMIDIEndpointBindings()
        var minted: [UInt] = []
        for records in steps {
            let update = Self.bind(records, after: bindings)
            minted += update.registrations.map(\.source.token.rawValue)
            bindings = update.bindings
        }
        #expect(minted == Array(1...UInt(minted.count)))
        #expect(minted.count == 6)

        let exhausted = Self.bind(
            [Self.source(10, "Launch Control XL"), Self.source(20, "Launch Control XL")],
            after: CoreMIDIEndpointBindings(lastToken: UInt.max - 1)
        )
        #expect(exhausted.registrations.map(\.source.token.rawValue) == [UInt.max])
        let refused = Self.bind([Self.source(10, "Launch Control XL"), Self.source(20, "Launch Control XL")],
                                after: exhausted.bindings)
        #expect(refused.registrations.isEmpty, "the counter refuses rather than wrapping to a used token")
        #expect(refused.bindings.connectedRefs == [10])
    }

    /// Mutation (c): giving an ambiguous unit its own source makes it resolved here.
    @Test func ambiguousAndIdentityUnavailableUnitsShareTheLegacySourceUnresolved() throws {
        let unique = Self.source(4, "Launch Control XL D")
        let update = Self.bind([
            Self.source(1, "Launch Control XL A", uniqueID: 5), Self.source(2, "Launch Control XL B", uniqueID: 5),
            Self.anonymous(3, "Launch Control XL C"), unique
        ])
        let uniqueKey = MIDIEndpointKey(fingerprint: unique.fingerprint)
        #expect(update.bindings.sources.map(\.endpoint) == [nil, nil, nil, uniqueKey])
        #expect(CoreMIDIEndpointBindings.endpointKey(fingerprint: 0, isAmbiguous: false) == nil)
        #expect(CoreMIDIEndpointBindings.endpointKey(fingerprint: nil, isAmbiguous: false) == nil)
        #expect(CoreMIDIEndpointBindings.endpointKey(fingerprint: 7, isAmbiguous: true) == nil)
        #expect(CoreMIDIEndpointBindings.endpointKey(fingerprint: 7, isAmbiguous: false) == .init(fingerprint: 7))

        var stream = try LaunchControlXLStream.make()
        let unresolvedJoined = stream.connect(update.bindings.sources)
        #expect(unresolvedJoined)
        let zero = try Self.connected(9, "Fingerprint zero", fingerprint: 0)
        let zeroJoined = stream.connect(update.bindings.sources + [zero])
        #expect(zeroJoined)
        #expect(stream.sources.filter { !$0.isResolved }.map(\.name) == [
            "Launch Control XL A", "Launch Control XL B", "Launch Control XL C", "Fingerprint zero"
        ])
        #expect(stream.snapshot.sources.map(\.key) == [Self.legacyKey, uniqueKey])
        // They share today's one framing, so one unit's status byte and another's data byte still join.
        #expect(stream.feed(packets: [[0xBF, 5]], from: try Self.token(of: 1, in: update)).isEmpty)
        let joined = stream.feed(packets: [[127]], from: try Self.token(of: 3, in: update))
        #expect(joined.map(\.event) == [Self.cc(5, 127)])
        #expect(joined.map(\.input) == [LaunchControlXLStream.input])
        #expect(stream.feed(packets: [[0xBF, 6, 1]], from: zero.token).map(\.input) == [LaunchControlXLStream.input])
    }

    @Test func aFullRegistryLeavesTheUnitUnresolvedOnTheLegacySource() throws {
        var stream = try LaunchControlXLStream.make()
        let room = UInt(LaunchControlXLStream.maximumSources - 1)
        let fitting = try (1...room).map { try Self.connected($0, "Unit \($0)", fingerprint: UInt64($0)) }
        let extra = try Self.connected(room + 1, "One too many", fingerprint: UInt64(room + 1))
        let demoted = stream.connect(fitting + [extra])
        #expect(demoted)
        #expect(stream.snapshot.sources.count == LaunchControlXLStream.maximumSources)
        #expect(stream.sources.dropLast() == ArraySlice(fitting))
        #expect(stream.sources.last == MIDIConnectedSource(token: extra.token, endpoint: nil, name: "One too many"))

        let outputs = stream.feed(packets: [[0xBF, 5, 127]], from: extra.token)
        #expect(outputs.map(\.event) == [Self.cc(5, 127)], "the unit is not dropped")
        #expect(outputs.map(\.input) == [LaunchControlXLStream.input])
        #expect(stream.droppedBatches == 0)
        let repeated = stream.connect(fitting + [extra])
        #expect(!repeated, "a repeated report changes nothing")
    }
}

/// The controller's resets across several sources.
extension CoreMIDIAdapterTests {
    @MainActor
    static func controller(
        _ fixture: LaunchControlXLFixture, input: RecordingLaunchControlXLInput,
        policy: LaunchControlXLSourcePolicy = .default
    ) -> (LaunchControlXLController, () -> [LaunchControlXLAction]) {
        let controller = LaunchControlXLController(
            fileStore: fixture.store, defaultConfiguration: fixture.configuration, makeMIDIInput: { input },
            sourcePolicy: policy
        )
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }
        return (controller, { dispatched })
    }

    /// Mutation (d): resetting only the gap batch's source lets B's `7F` complete its `BF 06`.
    @MainActor
    @Test func afterAGapEverySourceIsReset() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = RecordingLaunchControlXLInput()
        let (controller, dispatched) = Self.controller(fixture, input: input)
        await controller.load()
        let first = try Self.connected(1, "A", fingerprint: 1)
        let second = try Self.connected(2, "B", fingerprint: 2)
        input.reportConnected([first, second])

        input.send(packets: [[0xBF, 5]], from: first.token)
        input.send(packets: [[0xBF, 6]], from: second.token)
        input.send(packets: [[0x7F]], from: first.token, afterGap: true)
        input.send(packets: [[0x7F]], from: second.token)
        input.send(packets: [[0x7F]])
        input.send(packets: [[0xBF, 102, 0x7F]], from: second.token)
        await controller.dispatchPendingActions()
        #expect(dispatched() == [.moveBank(1)])
        await controller.setMode(.disabled)
    }

    @MainActor
    @Test func resetStreamResetsOnlyTheSourcesThatChanged() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = RecordingLaunchControlXLInput()
        let policy = LaunchControlXLSourcePolicy(profile: .unpaired, sourceChange: .resetStream)
        let (controller, dispatched) = Self.controller(fixture, input: input, policy: policy)
        await controller.load()
        let first = try Self.connected(1, "A", fingerprint: 1)
        let second = try Self.connected(2, "B", fingerprint: 2)
        let shared = try Self.connected(3, "C", fingerprint: nil)
        let joining = try Self.connected(4, "D", fingerprint: nil)

        input.reportConnected([first])
        input.send(packets: [[0xBF, 5]], from: first.token)
        input.reportConnected([first, second])
        input.send(packets: [[0x7F]], from: first.token)
        await controller.dispatchPendingActions()
        #expect(dispatched() == [.fader(slot: 0, value: 1)], "adding B did not reset A")

        input.reportConnected([first, second, shared])
        input.send(packets: [[0xBF, 5]], from: first.token)
        input.send(packets: [[0xBF, 6]], from: shared.token)
        input.reportConnected([first, second, shared, joining])
        #expect(controller.unresolvedSourceNames == ["C", "D"])
        #expect(controller.status == .connected(["A", "B", "C", "D"]))
        input.send(packets: [[0x7F]], from: shared.token)
        input.send(packets: [[0x7F]], from: first.token)
        await controller.dispatchPendingActions()
        #expect(dispatched() == [.fader(slot: 0, value: 1), .fader(slot: 0, value: 1)], "only the shared source reset")
        await controller.setMode(.disabled)
    }

    @MainActor
    @Test func keepPreservesOtherSourcesButNotADepartedUnit() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = RecordingLaunchControlXLInput()
        let (controller, dispatched) = Self.controller(fixture, input: input)
        await controller.load()
        let first = try Self.connected(1, "A", fingerprint: 1)
        let second = try Self.connected(2, "B", fingerprint: 2)
        let replugged = try Self.connected(3, "B", fingerprint: 2)
        let shared = try Self.connected(4, "C", fingerprint: nil)
        let joining = try Self.connected(5, "D", fingerprint: nil)

        input.reportConnected([first, second, shared])
        input.send(packets: [[0xBF, 5]], from: first.token)
        input.send(packets: [[0xBF, 6]], from: second.token)
        input.send(packets: [[0xBF, 6]], from: shared.token)
        input.reportConnected([first, shared, joining])
        input.send(packets: [[0x7F]], from: second.token)
        input.reportConnected([first, replugged, shared, joining])
        input.send(packets: [[0x7F]], from: replugged.token)
        input.send(packets: [[0x7F]], from: first.token)
        input.send(packets: [[0x40]], from: shared.token)
        await controller.dispatchPendingActions()
        #expect(dispatched() == [.fader(slot: 0, value: 1), .fader(slot: 1, value: 64 / 127)])
        await controller.setMode(.disabled)
    }
}
