import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlPickupBookTests {
    // MARK: Limits and host changes

    @Test func controlPickupBookRefusesTooManyUpdatesBeforeLookingAnyUp() throws {
        let limit = ControlPickupBook.maximumBindings
        var book = try BookFx.fullBook(limit)
        var inside: [BindingID: PickupState] = [:]
        for number in 0..<(limit - 1) { inside[try BookFx.named("bnd.", number)] = .engaged(hardware: 0.5) }
        let below = BookFx.refusal { try book.record(inside) }
        #expect(below == nil)
        inside[try BookFx.named("bnd.", limit - 1)] = .engaged(hardware: 0.5)
        let exact = BookFx.refusal { try book.record(inside) }
        #expect(exact == nil)
        let lastID = try BookFx.named("bnd.", limit - 1)
        #expect(book.state(of: lastID) == .engaged(hardware: 0.5))
        let before = book
        var beyond: [BindingID: PickupState] = [:]
        for number in 0...limit { beyond[try BookFx.named("bnd.x", number)] = .engaged(hardware: 0.5) }
        let outcome = BookFx.refusal { try book.record(beyond) }
        #expect(outcome == .tooManyUpdates(limit + 1))
        #expect(book == before)
    }

    @Test func controlPickupBookRefusesTooManyChangedTargetsBeforeChangingAnything() throws {
        let limit = ControlPickupBook.maximumChangedTargets
        var book = try BookFx.book([BookFx.catching(BookFx.idA)])
        try book.record([BookFx.idA: .engaged(hardware: 0.2)])
        let before = book
        for count in [limit - 1, limit] {
            let unwritten = try BookFx.targetList(count, last: BookFx.parZ)
            #expect(BookFx.moved(&book, unwritten) == .success([]))
            #expect(book == before)
        }
        let beyond = try BookFx.targetList(limit + 1, last: BookFx.parX)
        #expect(BookFx.moved(&book, beyond) == .failure(.tooManyTargets(limit + 1)))
        #expect(book == before)
        let exact = try BookFx.targetList(limit, last: BookFx.parX)
        #expect(BookFx.moved(&book, exact) == .success([BookFx.idA]))
        #expect(book.state(of: BookFx.idA) == .waiting(hardware: 0.2))
    }

    @Test func controlPickupBookWaitsEngagedCatchBindingsThatWriteAChangedTarget() throws {
        var book = try BookFx.book([
            BookFx.catching(BookFx.idA), BookFx.catching(BookFx.idB), BookFx.jumping(BookFx.idC),
            BookFx.relative(BookFx.idD), BookFx.catching(BookFx.idE, target: BookFx.parY),
            BookFx.catching(BookFx.idF), BookFx.catching(BookFx.idG, source: BookFx.srcB)
        ])
        try book.record([
            BookFx.idA: .engaged(hardware: 0.2), BookFx.idB: .engaged(hardware: nil),
            BookFx.idE: .engaged(hardware: 0.9), BookFx.idF: .waiting(hardware: 0.7)
        ])
        book.sourceLost(BookFx.srcB)
        let before = book
        #expect(BookFx.moved(&book, []) == .success([]))
        #expect(BookFx.moved(&book, [BookFx.parZ]) == .success([]))
        #expect(book == before)
        let outcome = BookFx.moved(&book, [BookFx.parX, BookFx.parX, BookFx.parZ])
        #expect(outcome == .success([BookFx.idA, BookFx.idB]))
        let expected: [BindingID: PickupState] = [
            BookFx.idA: .waiting(hardware: 0.2), BookFx.idB: .waiting(hardware: nil),
            BookFx.idC: .engaged(hardware: nil), BookFx.idD: .engaged(hardware: nil),
            BookFx.idE: .engaged(hardware: 0.9), BookFx.idF: .waiting(hardware: 0.7),
            BookFx.idG: .unavailable
        ]
        #expect(book.states == expected)
    }
}
