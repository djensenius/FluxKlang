import Foundation

/// Why one environment of a legacy `environments.json` could not be adopted. Nothing is produced when one is
/// thrown. Cases carry no paths, payload bytes, environment identities or Foundation text.
/// `adopt` refuses in this order: `oversizedInput`, `undecodableInput`, `unsupportedShape`,
/// `environmentNotFound`/`duplicateEnvironmentID`, then `adoption`.
enum LegacyEnvironmentAdoptionRefusal: Error, Equatable, Sendable {
    /// Over `min(maxEntryBytes, 4 MiB)`; checked before any decoding.
    case oversizedInput
    /// Not one strict JSON value (`ContractCoding`): BOM, NUL, malformed JSON or duplicate member names.
    case undecodableInput
    /// Valid JSON that is not `EnvironmentStore`'s shape: an object whose `environments` member is an array of
    /// objects, each with a UUID string `id` and a string `name`.
    case unsupportedShape
    /// No environment has the requested ID.
    case environmentNotFound
    /// More than one environment has the requested ID; none is chosen.
    case duplicateEnvironmentID
    /// The selected environment's StudioGraph/endpoints were refused by `LegacyAdoption.adopt`.
    case adoption(LegacyAdoptionRefusal)
}

/// Adopts the StudioGraph embedded in one environment of `EnvironmentStore`'s `environments.json` into a verified
/// v1 package, via `LegacyAdoption.adopt`. The whole original file is retained byte-for-byte as an extra
/// `.opaqueState` member, so other environments, unknown members and legacy roles survive untouched; it is never
/// re-encoded. Only `studioGraph` and `studioEndpoints` are read for adoption. `studioSetup` (legacy local plug
/// mappings) and the WING `graph`, `effects` and `placements` are not interpreted: they gain no binding, role or
/// authority and live only inside the retained original. The adopted graph still requires review.
///
/// Unlike direct `LegacyAdoption`, `legacy/StudioGraph.json` and `legacy/StudioEndpoints.json` here hold
/// canonical re-encodings of the selected environment's members, not original bytes; the true original is
/// `legacy/Environments.json`. The whole file must fit one package entry and counts against the package total
/// together with the re-encoded graph and endpoints, so a large file refuses even when the chosen environment
/// is small.
enum LegacyEnvironmentAdoption {
    static let originalEnvironmentsPath = "legacy/Environments.json"
    /// What `RoutingEnvironment` decodes for a missing `studioGraph`: an empty `StudioGraph()`.
    static let emptyStudioGraph = Data(#"{"edges":[],"nodes":[]}"#.utf8)

    /// Adopts environment `environmentID`, or refuses with nothing produced. The selected environment's
    /// `studioGraph` and `studioEndpoints` values are re-encoded canonically (`ContractCoding`) as the adapter's
    /// inputs: a missing or `null` `studioGraph` is the empty graph and a missing or `null` `studioEndpoints`
    /// adds no endpoints member, matching `RoutingEnvironment`'s legacy decoding. The same input always yields
    /// identical bytes.
    static func adopt( // swiftlint:disable:this function_parameter_count
        environmentsData: Data, environmentID: UUID, projectID: ProjectID, graphID: GraphID, name: String,
        policy: ProjectPackageManifestPolicy
    ) throws(LegacyEnvironmentAdoptionRefusal) -> LegacyAdoptionResult {
        // One package entry; valid limits never have a total below the entry cap.
        let entryLimit = min(policy.packageLimits.maxEntryBytes, ProjectGraphLimits.documentBytes)
        guard environmentsData.count <= entryLimit else { throw .oversizedInput }
        let environment = try select(environmentID, in: try environments(in: environmentsData))
        let graphData = try encodedMember(environment["studioGraph"]) ?? emptyStudioGraph
        let endpointsData = try encodedMember(environment["studioEndpoints"])
        let original = ProjectPackageFile(path: originalEnvironmentsPath, role: .opaqueState, bytes: environmentsData)
        do {
            return try LegacyAdoption.adopt(
                graphData: graphData, endpointsData: endpointsData, projectID: projectID, graphID: graphID,
                name: name, policy: policy, retaining: [original]
            )
        } catch {
            throw .adoption(error)
        }
    }

    /// The `environments` array's members, each checked for a UUID `id` and a string `name`.
    private static func environments(
        in data: Data
    ) throws(LegacyEnvironmentAdoptionRefusal) -> [(id: UUID, fields: [String: JSONValue])] {
        let value: JSONValue
        do {
            value = try ContractCoding.decode(JSONValue.self, from: data)
        } catch {
            throw .undecodableInput
        }
        guard case .object(let top) = value, case .array(let entries)? = top["environments"] else {
            throw .unsupportedShape
        }
        var found: [(id: UUID, fields: [String: JSONValue])] = []
        found.reserveCapacity(entries.count)
        for entry in entries {
            guard case .object(let fields) = entry, case .string(let raw)? = fields["id"],
                  let id = UUID(uuidString: raw), case .string? = fields["name"] else {
                throw .unsupportedShape
            }
            found.append((id, fields))
        }
        return found
    }

    /// Exactly one environment with `id`, compared as UUID values (case-insensitive spelling).
    private static func select(
        _ id: UUID, in environments: [(id: UUID, fields: [String: JSONValue])]
    ) throws(LegacyEnvironmentAdoptionRefusal) -> [String: JSONValue] {
        let matches = environments.filter { $0.id == id }
        guard let match = matches.first else { throw .environmentNotFound }
        guard matches.count == 1 else { throw .duplicateEnvironmentID }
        return match.fields
    }

    /// A present, non-`null` member re-encoded canonically; `nil` when absent or `null`.
    private static func encodedMember(_ value: JSONValue?) throws(LegacyEnvironmentAdoptionRefusal) -> Data? {
        guard let value, value != .null else { return nil }
        do {
            return try ContractCoding.makeEncoder().encode(value)
        } catch {
            throw .unsupportedShape
        }
    }
}
