//
//  ShowStageFormat+Resume.swift
//  FluxKlang
//
//  Fixed English phrases for a resume offer on the stage display (#106 SRW1). Each case has its own phrase; titles
//  and numbers (through the line phrase) are the only interpolations.
//

extension ShowStageFormat {
    static func resume(_ resume: ShowStageResume) -> String {
        switch resume {
        case let .offer(offer):
            let target = Self.line(offer.line)
            guard let basis = offer.basis else {
                return "Resume at the saved position. \(target) Accept to jump there."
            }
            return "Resume at a nearby position. \(Self.basis(basis)) \(target) Accept to jump there."
        case let .blocked(block):
            return Self.block(block)
        case .invalidPoint:
            return "Cannot resume: the saved position is not valid."
        }
    }

    static func basis(_ basis: ShowResumeBasis) -> String {
        switch basis {
        case .partMissing: "The saved part was removed."
        case .partsAdded: "The song gained parts since the position was saved."
        case .entryMissingNext: "The saved song entry was removed; the next entry is proposed."
        case .entryMissingPrevious: "The saved song entry was removed; the previous entry is proposed."
        case .entryMissingOrdinal:
            "The saved song entry was removed; the entry at the same place in the setlist is proposed."
        }
    }

    static func block(_ block: ShowResumeBlock) -> String {
        switch block {
        case .setlistRemoved: "Cannot resume: the setlist was removed."
        case .setlistEmpty: "Cannot resume: the setlist is empty."
        case .songChanged: "Cannot resume: the saved song entry now plays another song."
        }
    }
}
