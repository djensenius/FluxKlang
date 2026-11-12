//
//  RemoteRoleText.swift
//  FluxKlang
//
//  The fixed texts of the remote controller's role presentation (#96, REM1,
//  host-remote-roles.md). Pure functions of their inputs; the host name is used verbatim.
//

enum RemoteRoleText {
    static let resyncing = "Resyncing..."
    static let disconnected = "Disconnected; nothing will be sent"
    static let structure = "Hosts edit structure"
    static let controllerSafety = "host only (#94 open)"
    static let observerSafety = "host only (#94)"

    static func controllerTitle(host name: String, epoch: Int) -> String {
        "Remote for \(name) - epoch \(epoch)"
    }

    static func observerTitle(host name: String) -> String {
        "Watching \(name)"
    }

    /// The count and the sentence the remote shows after a reconnect dropped its queued changes.
    /// "Values now match" is claimed only once the host's values are applied (`valuesMatch`).
    static func discarded(count: Int, host name: String, valuesMatch: Bool) -> String {
        let counted = count == 1 ? "1 queued change discarded." : "\(count) queued changes discarded."
        return valuesMatch ? "\(counted) Values now match \(name)." : counted
    }
}
