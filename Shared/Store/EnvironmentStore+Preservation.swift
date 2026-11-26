//
//  EnvironmentStore+Preservation.swift
//  FluxKlang
//
//  Explicit, user-confirmed start-fresh for a held local environment source (#947). The named item is moved,
//  unchanged, into `Preserved`; nothing is deleted, overwritten or written to iCloud before the hold clears.
//  iCloud-caused holds are never preserved here.
//

import Foundation

/// A completed start-fresh: where the held item went, and the state after reading again.
struct EnvironmentPreservation: Equatable, Sendable {
    let fileName: String
    let preservedURL: URL
    /// `reloadClearingHold()` succeeded: nothing is held and no read is in flight, so dependents may reload.
    let cleared: Bool
    /// Non-nil when another source now holds; the first item stays preserved either way.
    let hold: EnvironmentLoadHold?
}

enum EnvironmentPreservationError: Error, Equatable, Sendable {
    /// The confirmed hold is on iCloud data, which start-fresh never touches: nothing was moved.
    case notPreservable
    /// Saved environments were being read: nothing was moved.
    case busy
    /// The current hold is not the one the user confirmed (it changed or cleared): nothing was moved.
    case holdChanged
    /// The move failed: the item stays in place and the hold remains.
    case moveFailed(fileName: String, reason: String)
}

/// The latest start-fresh, for the environment banner.
enum EnvironmentPreservationStatus: Equatable, Sendable {
    case inProgress(fileName: String)
    case completed(EnvironmentPreservation)
    case failed(EnvironmentPreservationError)

    var isInProgress: Bool {
        if case .inProgress = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .inProgress(let fileName):
            return "Moving \(fileName) to Preserved…"
        case .completed(let result):
            let moved = "Moved \(result.fileName) unchanged to \(EnvironmentPreservationStatus.location(result)); "
                + "it wasn't deleted."
            if result.cleared { return moved }
            return result.hold == nil
                ? moved + " Saved environments are still being read."
                : moved + " Saved environments are still stopped, as shown above."
        case .failed(.notPreservable):
            return "Nothing was moved: an iCloud copy can't be set aside here."
        case .failed(.busy):
            return "Nothing was moved: saved environments are still loading. Try again."
        case .failed(.holdChanged):
            return "Nothing was moved: the problem changed after you confirmed. Check the message above and try again."
        case .failed(.moveFailed(let fileName, let reason)):
            return "Couldn't move \(fileName), so nothing changed and environments stay stopped. \(reason)"
        }
    }

    private static func location(_ result: EnvironmentPreservation) -> String {
        "\(JSONFileStore.preservedDirectoryName)/\(result.preservedURL.lastPathComponent) in FluxKlang's app data"
    }
}

extension EnvironmentStore {
    /// A read is in flight, so neither reload nor start-fresh can act yet.
    var isReading: Bool { loads.phase == .loading }

    /// Moves the item named by `confirmed` aside, then runs `reloadClearingHold()`. Refused unless `confirmed` is a
    /// local hold, it is still the current hold and no read is in flight. Queued saves are invalidated and submitted
    /// writes awaited before the move; a failed move keeps the hold and leaves every file in place.
    func preserveHeldSourceAndStartFresh(
        confirmed: EnvironmentLoadHold
    ) async throws(EnvironmentPreservationError) -> EnvironmentPreservation {
        guard confirmed.isLocal else { throw .notPreservable }
        try requireHeld(on: confirmed)
        saves.invalidateQueued()
        await saves.awaitTailSnapshot()
        try requireHeld(on: confirmed) // A reload or another start-fresh may have run during the suspension.
        let store = injectedStore ?? JSONFileStore.shared
        let destination: URL
        do {
            destination = try await store.preserveLocalItem(named: confirmed.fileName)
        } catch {
            throw .moveFailed(fileName: confirmed.fileName, reason: error.localizedDescription)
        }
        let cleared = await reloadClearingHold()
        return EnvironmentPreservation(
            fileName: confirmed.fileName, preservedURL: destination, cleared: cleared, hold: hold)
    }

    private func requireHeld(on confirmed: EnvironmentLoadHold) throws(EnvironmentPreservationError) {
        if isReading { throw .busy }
        guard loads.phase == .held, hold == confirmed else { throw .holdChanged }
    }
}
