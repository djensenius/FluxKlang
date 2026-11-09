//
//  WiringProblemList+Text.swift
//  FluxKlang
//
//  The two fixed English lines of a problem list (#101 WGP1): the one-line summary and the line that says how many
//  problems the cap left out. There is no localisation; the wording is the inspector's own.
//

extension WiringProblemList {
    /// `No problems.`, `1 problem.` or `N problems.`, counting every distinct problem, shown or not.
    var summary: String { WiringInspectorLabel.problemSummary(distinctCount) }

    /// `1 problem not shown.` or `N problems not shown.`; nil when the cap left nothing out.
    var omittedLine: String? {
        if omittedCount == 0 { return nil }
        return "\(WiringInspectorLabel.count(omittedCount, "problem")) not shown."
    }
}
