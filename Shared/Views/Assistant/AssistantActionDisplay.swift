import Foundation

/// Formatting only. Display evidence and saved labels never confer permission to execute.
enum AssistantActionDisplay {
    static func source(group: String?, index: Int?) -> String {
        guard let group, !group.isEmpty, let index else { return "Source not verified" }
        return "Source: \(group) \(index)"
    }

    static func linkage(_ equipmentID: Equipment.ID?) -> String {
        equipmentID == nil ? "Unlinked to saved Equipment" : "Saved Equipment link recorded (not proof of cabling)"
    }

    static func side(index: Int, count: Int) -> String {
        count == 2 ? (index == 0 ? "Left · " : "Right · ") : ""
    }

    static func level(position: Float, muted: Bool) -> String {
        guard position.isFinite, (0...1).contains(position) else { return "Unknown fader value" }
        let travel = (Double(position) * 100).formatted(.number.precision(.fractionLength(1)))
        let level = FaderMath.isOff(position: position) ? "Off (−∞ dB)" : FaderMath.label(forPosition: position)
        return "\(level) · \(travel)% travel · \(muted ? "muted" : "unmuted")"
    }

    static func suggestedChange(_ review: AssistantActionReview) -> String? {
        guard let amount = review.suggestedAmountDB else { return nil }
        let changes = review.faderChanges
        let direction: String
        if !changes.isEmpty && changes.allSatisfy({ $0.afterPosition < $0.beforePosition }) {
            direction = "lower by "
        } else if !changes.isEmpty && changes.allSatisfy({ $0.afterPosition > $0.beforePosition }) {
            direction = "raise by "
        } else {
            direction = ""
        }
        return "Suggested change: \(direction)\(abs(amount).formatted()) dB (amount not specified)."
    }

    static func localStatus(_ status: AssistantActionResult.LocalStatus) -> String {
        switch status {
        case .notRequested: return "Shortcut: not requested"
        case .added: return "Shortcut: added locally"
        case .alreadyPresent: return "Shortcut: already present locally"
        case .failed: return "Shortcut: local addition failed"
        case .notAttempted: return "Shortcut: not attempted"
        }
    }

    static func memberStatus(_ status: AssistantActionResult.MemberStatus) -> String {
        switch status {
        case .notSent: return "Not sent"
        case .sentUnconfirmed: return "Sent; unconfirmed — inspect WING"
        case .confirmed: return "Confirmed by readback"
        case .readbackDiffers: return "Sent; readback differs — inspect WING"
        }
    }

    static func resultTitle(_ result: AssistantActionResult) -> String {
        let statuses = result.members.map(\.status)
        let confirmed = statuses.filter { $0 == .confirmed }.count
        if confirmed > 0 && confirmed < statuses.count { return "Partial outcome" }
        if statuses.contains(.notSent) && statuses.contains(where: { $0 != .notSent }) { return "Partial outcome" }
        if statuses.contains(.sentUnconfirmed) || statuses.contains(.readbackDiffers) {
            return "Unconfirmed outcome"
        }
        if statuses.contains(.notSent) {
            return result.localStatus == .added ? "Partial outcome" : "Changes not sent"
        }
        return "Action result"
    }
}
