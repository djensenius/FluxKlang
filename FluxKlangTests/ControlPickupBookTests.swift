import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Fixtures of `ControlPickupBookTests` and its `+Limits` extension.
enum BookFx {
    static let srcA = ControlSourceID(validated: "src.a")
    static let srcB = ControlSourceID(validated: "src.b")
    static let srcAX = ControlSourceID(validated: "src.a.x")
    static let parX = ParameterID(validated: "par.x")
    static let parY = ParameterID(validated: "par.y")
    static let parZ = ParameterID(validated: "par.z")
    static let idA = BindingID(validated: "bnd.a")
    static let idB = BindingID(validated: "bnd.b")
    static let idC = BindingID(validated: "bnd.c")
    static let idD = BindingID(validated: "bnd.d")
    static let idE = BindingID(validated: "bnd.e")
    static let idF = BindingID(validated: "bnd.f")
    static let idG = BindingID(validated: "bnd.g")
    static let idBetween = BindingID(validated: "bnd.b.")
    static let ordZero = BindingID(validated: "bnd.0")
    static let ordColon = BindingID(validated: "bnd.:")
    static let ordUpper = BindingID(validated: "bnd.Z")
    static let ordScore = BindingID(validated: "bnd._")
    static let ordDash = BindingID(validated: "bnd.a-")
    static let ordDot = BindingID(validated: "bnd.a.")
    static let ordDotX = BindingID(validated: "bnd.a.x")
    static let wide = EncoderProfile.absolute(resolution: 128)

    static func catching(_ id: BindingID, source: ControlSourceID = srcA,
                         target: ParameterID = parX) throws -> ControlBinding {
        try ControlBinding(.init(id: id, source: source, target: target, unit: .percent, profile: wide, pickup: .catch))
    }

    static func jumping(_ id: BindingID, source: ControlSourceID = srcA,
                        target: ParameterID = parX) throws -> ControlBinding {
        try ControlBinding(.init(id: id, source: source, target: target, unit: .percent, profile: wide, pickup: .jump))
    }

    static func relative(_ id: BindingID, source: ControlSourceID = srcA,
                         target: ParameterID = parX) throws -> ControlBinding {
        try ControlBinding(.init(
            id: id, source: source, target: target, unit: .percent,
            profile: .twosComplement(width: .seven), step: 1
        ))
    }

    static func book(_ bindings: [ControlBinding]) throws -> ControlPickupBook {
        var book = ControlPickupBook()
        for binding in bindings { try book.add(binding) }
        return book
    }

    static func digits(_ number: Int, width: Int) -> String {
        var text = ""
        var rest = number
        for _ in 0..<width {
            text = String(rest % 10) + text
            rest /= 10
        }
        return text
    }

    static func named(_ prefix: String, _ number: Int, width: Int = 3) throws -> BindingID {
        try BindingID(prefix + digits(number, width: width))
    }

    static func ids(_ prefix: String, _ count: Int) throws -> [BindingID] {
        var found: [BindingID] = []
        for number in 0..<count { found.append(try named(prefix, number, width: 2)) }
        return found
    }

    static func jumpBook(_ ids: [BindingID]) throws -> ControlPickupBook {
        var book = ControlPickupBook()
        for id in ids { try book.add(jumping(id)) }
        return book
    }

    static func catchBook(_ ids: [BindingID]) throws -> ControlPickupBook {
        var book = ControlPickupBook()
        for id in ids { try book.add(catching(id)) }
        return book
    }

    static func fullBook(_ count: Int) throws -> ControlPickupBook {
        var book = ControlPickupBook()
        for number in 0..<count { try book.add(jumping(named("bnd.", number))) }
        return book
    }

    static func updates(_ ids: [BindingID], _ state: PickupState) -> [BindingID: PickupState] {
        var table: [BindingID: PickupState] = [:]
        for id in ids { table[id] = state }
        return table
    }

    static func targetList(_ count: Int, last: ParameterID) throws -> [ParameterID] {
        var list: [ParameterID] = []
        for number in 0..<(count - 1) { list.append(try ParameterID("par." + digits(number, width: 4))) }
        list.append(last)
        return list
    }

    static func bytes(_ ids: [BindingID]) -> [[UInt8]] {
        ids.map { Array($0.rawValue.utf8) }
    }

    static func refusal(_ work: () throws -> Void) -> ControlPickupBookRefusal? {
        do {
            try work()
            return nil
        } catch let known as ControlPickupBookRefusal {
            return known
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    static func moved(_ book: inout ControlPickupBook,
                      _ targets: [ParameterID]) -> Result<[BindingID], ControlPickupBookRefusal> {
        do {
            return .success(try book.hostChanged(targets: targets))
        } catch {
            return .failure(error)
        }
    }

    /// Three bindings on `src.a` (a jump, a catch engaged at 0.3, and one that was lost first), one catch on `src.b`
    /// engaged at 0.6 and one on `src.a.x`, after `src.a` was lost twice and then `src.a.x`.
    static func lostBook() throws -> ControlPickupBook {
        var book = try Self.book([jumping(idA), catching(idD, source: srcB), catching(idE, source: srcAX)])
        book.sourceLost(srcA)
        try book.add(catching(idC))
        try book.add(jumping(idB))
        try book.record([idC: .engaged(hardware: 0.3), idD: .engaged(hardware: 0.6)])
        book.sourceLost(srcA)
        book.sourceLost(srcAX)
        return book
    }
}

@Suite("Control pickup book")
struct ControlPickupBookTests {
    // MARK: Adding and ordering

    @Test func controlPickupBookStartsEachBindingInItsInitialState() throws {
        let book = try BookFx.book([
            BookFx.catching(BookFx.idA), BookFx.jumping(BookFx.idB), BookFx.relative(BookFx.idC)
        ])
        #expect(book.state(of: BookFx.idA) == .waiting(hardware: nil))
        #expect(book.state(of: BookFx.idB) == .engaged(hardware: nil))
        #expect(book.state(of: BookFx.idC) == .engaged(hardware: nil))
        #expect(book.state(of: BookFx.idD) == nil)
        #expect(book.state(of: BookFx.idBetween) == nil)
        let expected: [BindingID: PickupState] = [
            BookFx.idA: .waiting(hardware: nil), BookFx.idB: .engaged(hardware: nil),
            BookFx.idC: .engaged(hardware: nil)
        ]
        #expect(book.states == expected)
        #expect(book.count == 3)
    }

    @Test func controlPickupBookKeepsBindingsInByteOrderOfTheId() throws {
        let sorted: [BindingID] = [
            BookFx.ordZero, BookFx.ordColon, BookFx.ordUpper, BookFx.ordScore,
            BookFx.ordDash, BookFx.ordDot, BookFx.ordDotX
        ]
        let scrambled: [BindingID] = [
            BookFx.ordDot, BookFx.ordUpper, BookFx.ordZero, BookFx.ordDotX,
            BookFx.ordColon, BookFx.ordDash, BookFx.ordScore
        ]
        let scrambledBook = try BookFx.catchBook(scrambled)
        let sortedBook = try BookFx.catchBook(sorted)
        let reversedBook = try BookFx.catchBook(Array(sorted.reversed()))
        let expected = BookFx.bytes(sorted)
        #expect(BookFx.bytes(scrambledBook.waitingBindings) == expected)
        #expect(BookFx.bytes(sortedBook.waitingBindings) == expected)
        #expect(BookFx.bytes(reversedBook.waitingBindings) == expected)
        #expect(scrambledBook == sortedBook)
        #expect(sortedBook == reversedBook)
        var mixed = scrambledBook
        try mixed.add(BookFx.jumping(BookFx.idA))
        #expect(mixed.count == sorted.count + 1)
        #expect(BookFx.bytes(mixed.waitingBindings) == expected)
        #expect(mixed.state(of: BookFx.idA) == .engaged(hardware: nil))
    }

    @Test func controlPickupBookRefusesADuplicateIdBeforeAFullBook() throws {
        var small = try BookFx.book([BookFx.catching(BookFx.idA)])
        let smallBefore = small
        let repeated = try BookFx.jumping(BookFx.idA)
        let outcome = BookFx.refusal { try small.add(repeated) }
        #expect(outcome == .duplicateBinding(BookFx.idA))
        #expect(small == smallBefore)
        var full = try BookFx.fullBook(ControlPickupBook.maximumBindings)
        let fullBefore = full
        let again = try BookFx.jumping(BookFx.named("bnd.", 7))
        let both = BookFx.refusal { try full.add(again) }
        let sevenID = try BookFx.named("bnd.", 7)
        #expect(both == .duplicateBinding(sevenID))
        let fresh = try BookFx.jumping(BookFx.idA)
        let onlyFull = BookFx.refusal { try full.add(fresh) }
        #expect(onlyFull == .bookFull(limit: ControlPickupBook.maximumBindings))
        #expect(ControlPickupBook.maximumBindings == ControlLocalDispatch.maximumBindings)
        #expect(full == fullBefore)
    }

    @Test func controlPickupBookAcceptsTheTwoHundredFiftySixthBindingAndRefusesTheNext() throws {
        let limit = ControlPickupBook.maximumBindings
        var book = try BookFx.fullBook(limit - 1)
        #expect(book.count == limit - 1)
        try book.add(BookFx.jumping(BookFx.named("bnd.", limit - 1)))
        #expect(book.count == limit)
        let before = book
        let extra = try BookFx.jumping(BookFx.named("bnd.", limit))
        let outcome = BookFx.refusal { try book.add(extra) }
        #expect(outcome == .bookFull(limit: limit))
        #expect(book.count == limit)
        #expect(book == before)
    }

    @Test func controlPickupBookRemovesOneBindingAndAReAddedBindingRestartsInItsInitialState() throws {
        var book = try BookFx.book([
            BookFx.catching(BookFx.idA), BookFx.catching(BookFx.idB), BookFx.jumping(BookFx.idC)
        ])
        try book.record([BookFx.idA: .engaged(hardware: 0.6)])
        let removed = BookFx.refusal { try book.remove(BookFx.idA) }
        #expect(removed == nil)
        #expect(book.count == 2)
        #expect(book.state(of: BookFx.idA) == nil)
        #expect(book.state(of: BookFx.idB) == .waiting(hardware: nil))
        #expect(book.state(of: BookFx.idC) == .engaged(hardware: nil))
        let again = BookFx.refusal { try book.remove(BookFx.idA) }
        #expect(again == .bindingMissing(BookFx.idA))
        try book.add(BookFx.catching(BookFx.idA))
        #expect(book.state(of: BookFx.idA) == .waiting(hardware: nil))
        try book.remove(BookFx.idB)
        #expect(book.count == 2)
        #expect(book.state(of: BookFx.idB) == nil)
        #expect(book.state(of: BookFx.idC) == .engaged(hardware: nil))
    }

    // MARK: Recording

    @Test func controlPickupBookRecordsTheStatesADispatcherReported() throws {
        var book = try BookFx.book([
            BookFx.catching(BookFx.idA), BookFx.catching(BookFx.idB), BookFx.jumping(BookFx.idC)
        ])
        try book.record([BookFx.idA: .engaged(hardware: 0.6), BookFx.idB: .waiting(hardware: 0.2)])
        #expect(book.state(of: BookFx.idA) == .engaged(hardware: 0.6))
        #expect(book.state(of: BookFx.idB) == .waiting(hardware: 0.2))
        #expect(book.state(of: BookFx.idC) == .engaged(hardware: nil))
        try book.record([BookFx.idA: .engaged(hardware: 0), BookFx.idB: .waiting(hardware: 1)])
        #expect(book.state(of: BookFx.idA) == .engaged(hardware: 0))
        #expect(book.state(of: BookFx.idB) == .waiting(hardware: 1))
    }

    @Test func controlPickupBookRecordsAWholeTableHandedBack() throws {
        var book = try BookFx.book([
            BookFx.catching(BookFx.idA), BookFx.jumping(BookFx.idB), BookFx.jumping(BookFx.idC, source: BookFx.srcB)
        ])
        try book.record([BookFx.idA: .engaged(hardware: 0.5)])
        book.sourceLost(BookFx.srcB)
        let before = book
        let table = book.states
        let outcome = BookFx.refusal { try book.record(table) }
        #expect(outcome == nil)
        #expect(book == before)
        #expect(book.state(of: BookFx.idC) == .unavailable)
    }

    @Test func controlPickupBookChecksRecordedIdsInByteOrderAndWritesNothingOnRefusal() throws {
        let missing = try BookFx.ids("bnd.m", 10)
        let firstMissing = try #require(missing.first)
        var book = try BookFx.jumpBook([BookFx.idA])
        let before = book
        var mixed = BookFx.updates(missing, .engaged(hardware: 0.4))
        mixed[BookFx.idA] = .engaged(hardware: 0.4)
        let gone = BookFx.refusal { try book.record(mixed) }
        #expect(gone == .bindingMissing(firstMissing))
        #expect(book == before)
        let stale = try BookFx.ids("bnd.u", 10)
        let firstStale = try #require(stale.first)
        var lost = try BookFx.jumpBook(stale)
        lost.sourceLost(BookFx.srcA)
        let lostBefore = lost
        let bothDefects = BookFx.updates(stale, .waiting(hardware: nil))
        let staleFirst = BookFx.refusal { try lost.record(bothDefects) }
        #expect(staleFirst == .bindingUnavailable(firstStale))
        #expect(lost == lostBefore)
        let early = try BookFx.ids("bnd.p", 6)
        let late = try BookFx.ids("bnd.q", 6)
        let firstEarly = try #require(early.first)
        var badFirst = try BookFx.jumpBook(early)
        let badBefore = badFirst
        var crossed = BookFx.updates(early, .waiting(hardware: nil))
        crossed.merge(BookFx.updates(late, .waiting(hardware: nil))) { first, _ in first }
        let notAllowed = BookFx.refusal { try badFirst.record(crossed) }
        #expect(notAllowed == .stateNotAllowed(firstEarly))
        #expect(badFirst == badBefore)
        var missingFirst = try BookFx.jumpBook(late)
        let missingBefore = missingFirst
        let outcome = BookFx.refusal { try missingFirst.record(crossed) }
        #expect(outcome == .bindingMissing(firstEarly))
        #expect(missingFirst == missingBefore)
    }

    @Test func controlPickupBookRefusesPositionsThatResolveWouldRefuse() throws {
        var book = try BookFx.book([BookFx.catching(BookFx.idA)])
        let before = book
        let invalid: [Double] = [.nan, .infinity, -0.001, 1.001]
        for position in invalid {
            let states: [PickupState] = [.engaged(hardware: position), .waiting(hardware: position)]
            for state in states {
                let outcome = BookFx.refusal { try book.record([BookFx.idA: state]) }
                #expect(outcome == .stateNotAllowed(BookFx.idA))
                #expect(book == before)
            }
        }
        let valid: [Double] = [-0.0, 0, 1]
        for position in valid {
            let engaged = BookFx.refusal { try book.record([BookFx.idA: .engaged(hardware: position)]) }
            #expect(engaged == nil)
            let waiting = BookFx.refusal { try book.record([BookFx.idA: .waiting(hardware: position)]) }
            #expect(waiting == nil)
        }
    }

    @Test func controlPickupBookRefusesStatesNoExistingCodePathProduces() throws {
        var book = try BookFx.book([
            BookFx.catching(BookFx.idA), BookFx.jumping(BookFx.idB), BookFx.relative(BookFx.idC)
        ])
        let before = book
        for id in [BookFx.idB, BookFx.idC] {
            let outcome = BookFx.refusal { try book.record([id: .waiting(hardware: nil)]) }
            #expect(outcome == .stateNotAllowed(id))
        }
        for id in [BookFx.idA, BookFx.idB, BookFx.idC] {
            let outcome = BookFx.refusal { try book.record([id: .unavailable]) }
            #expect(outcome == .stateNotAllowed(id))
        }
        #expect(book == before)
        try book.record([BookFx.idB: .engaged(hardware: 0.5)])
        #expect(book.state(of: BookFx.idB) == .engaged(hardware: 0.5))
    }

    @Test func controlPickupBookRefusesAChangeToAnUnavailableBindingButNotTheSameState() throws {
        var book = try BookFx.book([BookFx.jumping(BookFx.idA)])
        book.sourceLost(BookFx.srcA)
        let before = book
        let change = BookFx.refusal { try book.record([BookFx.idA: .engaged(hardware: 0.4)]) }
        #expect(change == .bindingUnavailable(BookFx.idA))
        #expect(book == before)
        let same = BookFx.refusal { try book.record([BookFx.idA: .unavailable]) }
        #expect(same == nil)
        #expect(book == before)
    }

    // MARK: Controller loss

    @Test func controlPickupBookMarksOnlyTheLostSourcesBindingsUnavailableInByteOrder() throws {
        var book = try BookFx.book([BookFx.jumping(BookFx.idA), BookFx.catching(BookFx.idD, source: BookFx.srcB),
                                    BookFx.catching(BookFx.idE, source: BookFx.srcAX)])
        let first = book.sourceLost(BookFx.srcA)
        #expect(first == [BookFx.idA])
        try book.add(BookFx.catching(BookFx.idC))
        try book.add(BookFx.jumping(BookFx.idB))
        #expect(book.sourceLost(BookFx.srcAX) == [BookFx.idE])
        #expect(book.state(of: BookFx.idE) == .unavailable)
        let lost = book.sourceLost(BookFx.srcA)
        #expect(lost == [BookFx.idB, BookFx.idC])
        #expect(book.unavailableBindings == [BookFx.idA, BookFx.idB, BookFx.idC, BookFx.idE])
        #expect(book.state(of: BookFx.idD) == .waiting(hardware: nil))
        let before = book
        #expect(book.sourceLost(BookFx.srcA).isEmpty)
        let unknown = ControlSourceID(validated: "src.nobody")
        #expect(book.sourceLost(unknown).isEmpty)
        #expect(book == before)
    }

    @Test func controlPickupBookReturnsAReturnedSourcesBindingsToTheirInitialStates() throws {
        var book = try BookFx.lostBook()
        #expect(book.state(of: BookFx.idC) == .unavailable)
        let seen = book.sourceSeen(BookFx.srcA)
        #expect(seen == [BookFx.idA, BookFx.idB, BookFx.idC])
        #expect(book.state(of: BookFx.idE) == .unavailable)
        #expect(book.sourceSeen(BookFx.srcAX) == [BookFx.idE])
        #expect(book.state(of: BookFx.idE) == .waiting(hardware: nil))
        #expect(book.state(of: BookFx.idA) == .engaged(hardware: nil))
        #expect(book.state(of: BookFx.idB) == .engaged(hardware: nil))
        #expect(book.state(of: BookFx.idC) == .waiting(hardware: nil))
        let before = book
        #expect(book.sourceSeen(BookFx.srcA).isEmpty)
        #expect(book.sourceSeen(BookFx.srcB).isEmpty)
        #expect(book == before)
        #expect(book.state(of: BookFx.idD) == .engaged(hardware: 0.6))
    }

    // MARK: Composition with the local dispatcher

    @Test func controlPickupBookStatesFeedTheLocalDispatcherAndItsUpdatesComeBack() throws {
        let pad = ControlSourceID(validated: "midi.ld-pad.1.cc.70")
        let level = ParameterID(validated: "par.ld.level")
        var book = try BookFx.book([
            BookFx.jumping(BookFx.idA, source: pad, target: level),
            BookFx.catching(BookFx.idB, source: pad, target: level)
        ])
        let descriptor = try ParameterDescriptor(.init(
            id: level, unit: .percent, lower: 0, upper: 100, defaultValue: 0, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: .live, verification: .unverified
        ))
        let truth = try ControlHostTruth(
            catalog: ParameterCatalog([descriptor]), values: [level: ParameterValue(value: 50, unit: .percent)]
        )
        let update = MIDI1StateUpdate(channel: 1, effect: .controller(70, value: 127))
        let input = try ControlLocalInput(update: update, origin: ControlSourceOrigin("ld-pad"))
        let bindings = book.entries.map(\.binding)
        let admission = ControlLocalDispatch.admit(input: input, learn: .idle, bindings: bindings, pickup: book.states)
        #expect(admission.candidates.map(\.binding.id) == [BookFx.idA, BookFx.idB])
        let result = ControlLocalDispatch.settle(admission, echoes: [], truth: truth)
        var reported: [BindingID: PickupState] = [:]
        for item in result.pickupUpdates { reported[item.binding] = item.state }
        try book.record(reported)
        #expect(book.state(of: BookFx.idA) == .engaged(hardware: 1))
        #expect(book.state(of: BookFx.idB) == .waiting(hardware: 1))
        #expect(book.sourceLost(pad) == [BookFx.idA, BookFx.idB])
        let second = ControlLocalDispatch.admit(input: input, learn: .idle, bindings: bindings, pickup: book.states)
        let after = ControlLocalDispatch.settle(second, echoes: [], truth: truth)
        let refused: [ControlLocalDispatchRefusal] = [
            .binding(BookFx.idA, .pickupUnavailable), .binding(BookFx.idB, .pickupUnavailable)
        ]
        #expect(after.refusals == refused)
        #expect(after.proposals.isEmpty)
    }
}
