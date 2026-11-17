/// The shapes each store loads, checked on strict JSON values only; nothing is decoded into an app model.
///
/// Connections mirror `StudioConnectionsStore.load`, which decodes `StudioConnectionsStore.Persisted` with a plain
/// `JSONDecoder`. Accepted: a top-level object whose `connections` member is an object (required, not `null`);
/// `initialized` absent, `null` or a Boolean; `confirmedOutputDefaultsVersion` absent, `null` or an integer that
/// fits `Int`. Inside `connections` (`GlobalStudioConnections`, whose decoder falls back to empty for each member):
/// `home` absent, `null` or an object whose `inputs` and `outputs` are arrays (`StudioHomeConnections` requires
/// both); `temporaryMoves` and `migrationIssues` absent, `null` or arrays. Unknown members anywhere are ignored, as
/// `JSONDecoder` ignores them. Array elements (connections, moves with their evidence and lifecycle, issues) are
/// not interpreted; they travel only inside the original bytes. Everything else is `unsupportedShape`.
///
/// The USB map mirrors `LaunchControlXLConfiguration`: an integer `version`, a `mode` string naming a
/// `LaunchControlXLMode`, and a `mapping` object, whose members are not interpreted.
extension ProjectMigration {
    static func isStoreConnections(_ top: [String: JSONValue]) -> Bool {
        guard case .object(let connections)? = top["connections"] else { return false }
        return isAbsentOrNull(top["initialized"], or: isBool)
            && isAbsentOrNull(top["confirmedOutputDefaultsVersion"], or: isInteger)
            && isAbsentOrNull(connections["home"], or: isHome)
            && isAbsentOrNull(connections["temporaryMoves"], or: isArray)
            && isAbsentOrNull(connections["migrationIssues"], or: isArray)
    }

    static func isUSBMap(_ top: [String: JSONValue]) -> Bool {
        guard let version = top["version"], isInteger(version),
              case .string(let mode)? = top["mode"], LaunchControlXLMode(rawValue: mode) != nil,
              case .object? = top["mapping"] else {
            return false
        }
        return true
    }

    /// What `decodeIfPresent` accepts: a missing member or `null`, otherwise a value `accepts` admits.
    private static func isAbsentOrNull(_ value: JSONValue?, or accepts: (JSONValue) -> Bool) -> Bool {
        guard let value, value != .null else { return true }
        return accepts(value)
    }

    private static func isHome(_ value: JSONValue) -> Bool {
        guard case .object(let home) = value, case .array? = home["inputs"], case .array? = home["outputs"] else {
            return false
        }
        return true
    }

    private static func isBool(_ value: JSONValue) -> Bool {
        if case .bool = value { return true }
        return false
    }

    /// `JSONValue` decodes an integral literal that fits `Int64` as `.int`; anything larger is not an `Int`.
    private static func isInteger(_ value: JSONValue) -> Bool {
        if case .int = value { return true }
        return false
    }

    private static func isArray(_ value: JSONValue) -> Bool {
        if case .array = value { return true }
        return false
    }
}
