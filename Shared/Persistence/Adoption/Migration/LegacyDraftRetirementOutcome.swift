import Foundation

/// One draft name as the retirement sees it.
enum LegacyDraftNode: Sendable, Equatable {
    case absent
    /// A regular file that passed the reader's checks, with its bytes.
    case file(Data)
    /// Present but not usable: a link, a directory, a hard-linked, foreign-volume or oversized file, or one that
    /// changed while it was read.
    case unusable
}

/// Where the archived draft stands at launch once the archive exists.
enum LegacyDraftLaunchState: Sendable, Equatable {
    /// The archive holds no draft; nothing is retirable.
    case noDraftArchived
    /// The archived draft is at the original name and the retired name is free: retire it.
    case pending
    /// The archived draft is at the retired name. Whatever is at the original name is a new user draft.
    case retired
    /// The archived draft is at neither name, and nothing else is either; nothing is left to retire.
    case draftGone
    /// The original name holds something other than the archived draft and it was never retired.
    case draftChanged
    /// The retired name holds something other than the archived draft.
    case retiredNameOccupied
}

/// Why the draft was not retired. Carries no bytes, paths or OS text. Nothing was replaced in any case.
enum LegacyDraftRetirementRefusal: Error, Sendable, Equatable {
    /// The draft at the original name is not the archived draft, or changed just before the rename.
    case draftChanged
    /// The retired name is taken by another node; both are left as they are.
    case retiredNameOccupied
    /// The receipt's draft is not the draft the archive holds; nothing was changed.
    case receiptMismatch
    /// The archive cannot be read as a package.
    case archiveUnreadable
    /// A status, read, rename or sync failed, or the retired file did not read back as the draft.
    case staging(StagingRefusal)
}

/// The result of one `LegacyDraftRetirement.retire` run.
enum LegacyDraftRetirementOutcome: Sendable, Equatable {
    /// The draft was renamed to the retired name, the root was synced and the file read back unchanged.
    case retired
    /// The archived draft was already at the retired name; nothing was written.
    case alreadyRetired
    /// The receipt or the archive holds no draft, or the draft is gone from both names; nothing was written.
    case nothingRetirable
    case refused(LegacyDraftRetirementRefusal)
}
