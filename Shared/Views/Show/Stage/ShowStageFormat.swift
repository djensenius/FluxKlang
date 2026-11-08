//
//  ShowStageFormat.swift
//  FluxKlang
//
//  Fixed English accessibility phrases for the stage display (#106 SHV1). Each case has its own phrase; titles and
//  numbers are the only interpolations, so no title can change which phrase is chosen.
//

enum ShowStageFormat {
    static func cursorState(_ state: ShowStageProjection.CursorState) -> String {
        switch state {
        case .positioned: "The cursor is on a song."
        case .unpositioned: "The cursor is not on a song yet."
        case let .stale(status): stale(status)
        }
    }

    static func stale(_ status: ShowCursorStatus) -> String {
        switch status {
        case .current: "The cursor target is current."
        case .setlistRemoved: "The setlist was removed. Jump to a song to continue."
        case .entryRemoved: "The song entry was removed. Jump to a song to continue."
        case .partRemoved: "The part was removed. Jump to a part to continue."
        case .partsAdded: "The song gained parts. Jump to a part to continue."
        }
    }

    static func chart(_ chart: ShowStageChart) -> String {
        switch chart {
        case .none: "No chart."
        case .available: "Chart available."
        case let .missing(_, reason): missing(reason)
        }
    }

    /// The `notDocument` media is not spoken: one phrase.
    static func missing(_ reason: ChartMissingReason) -> String {
        switch reason {
        case .notInProject: "Chart missing: not in the project."
        case .notDocument: "Chart missing: the asset is not a document."
        case .contentUnavailable: "Chart missing: content unavailable."
        }
    }

    static func problems(count: Int) -> String {
        if count <= 0 { return "No link problems." }
        if count == 1 { return "1 link problem." }
        return "\(count) link problems."
    }

    static func line(_ line: ShowStageLine) -> String {
        let song = "Song \(line.songNumber) of \(line.songCount), \(line.songTitle)."
        let part = part(of: line)
        return "\(song) \(part) \(chart(line.chart)) \(problems(count: line.problems.count))"
    }

    static func destination(_ destination: ShowStageDestination, line: ShowStageLine?) -> String {
        let name = name(of: destination)
        guard let line else { return "\(name): none." }
        return "\(name): \(Self.line(line))"
    }

    private static func name(of destination: ShowStageDestination) -> String {
        switch destination {
        case .nextPart: "Next part"
        case .previousPart: "Previous part"
        case .nextSong: "Next song"
        case .previousSong: "Previous song"
        }
    }

    private static func part(of line: ShowStageLine) -> String {
        guard let number = line.partNumber, let title = line.partTitle else { return "No parts." }
        return "Part \(number) of \(line.partCount), \(title)."
    }
}
