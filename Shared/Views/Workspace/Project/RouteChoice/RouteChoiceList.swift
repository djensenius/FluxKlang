//
//  RouteChoiceList.swift
//  FluxKlang
//
//  The compact route picker's list as a value (#100 MAP1; phone-compact-routing.md "Map..." picker): a heading, one
//  row per candidate block the source offers an unmapped audio role, the fixed footnote, and a line when the source
//  omitted candidates. A row whose output channels another live route already writes is disabled with a visible
//  reason; a shared input stays enabled. Rows keep the source's order. Device names and role labels are the caller's
//  and are shown exactly as given. No view, I/O or clock; nothing calls it yet.
//
//  Not modelled: the host phrase, the chevron, Cancel, what a pick does, the review that follows it, a "headphones"
//  row (no device-kind source), device display names (none in the repo) and localisation.
//

struct RouteChoiceList: Equatable, Sendable {
    let role: RoleID
    /// "Map <role label> (<N>ch)".
    let headline: String
    /// In the source's (device, first channel) order. Never sorted, and no row is preselected.
    let rows: [RouteChoiceRow]
    /// Non-nil exactly when `rows` is empty.
    let emptyText: String?
    /// Non-nil exactly when `isTruncated`.
    let truncationText: String?
    /// True exactly when the source omitted compatible blocks. The source's cap is carried, not re-applied.
    let isTruncated: Bool

    var footnote: String { RouteChoiceText.footnote }

    private init(
        role: RoleID, headline: String, rows: [RouteChoiceRow], truncationText: String?
    ) {
        self.role = role
        self.headline = headline
        self.rows = rows
        emptyText = rows.isEmpty ? RouteChoiceText.empty : nil
        self.truncationText = truncationText
        isTruncated = truncationText != nil
    }

    /// Throws for the first offender of the first failing check, in this order: route count, target label, candidate
    /// count, candidate role, candidate fit, device names, claimant labels.
    static func make( // swiftlint:disable:this function_parameter_count
        role: RoleID,
        requirement: RouteRoleRequirement,
        candidates: RigRoleCandidates,
        existingRoutes: [AudioRoute],
        deviceNames: [DeviceID: String],
        roleLabels: [RoleID: String]
    ) throws(RouteChoiceListRefusal) -> Self {
        guard existingRoutes.count <= DeviceCapabilityLimits.routes else {
            throw .tooManyRoutes(count: existingRoutes.count, maximum: DeviceCapabilityLimits.routes)
        }
        let roleLabel = try label(of: role, in: roleLabels)
        let blocks = candidates.candidates
        guard blocks.count <= RigMappingLimits.candidatesPerRole else {
            throw .tooManyCandidates(count: blocks.count, maximum: RigMappingLimits.candidatesPerRole)
        }
        if let other = blocks.first(where: { $0.role != role }) { throw .candidateForOtherRole(other.role) }
        if let misfit = blocks.first(where: {
            $0.direction != requirement.direction || $0.channelCount != requirement.channelCount
        }) {
            throw .candidateDoesNotFit(device: misfit.device, firstChannel: misfit.firstChannel)
        }
        try checkDeviceNames(of: blocks, in: deviceNames)

        let claimants = blocks.map { claimants(of: $0, role: role, in: existingRoutes) }
        var claimantLabels: [RoleID: String] = [:]
        for claimant in Set(claimants.joined()).sorted(by: { bytesPrecede($0, $1) }) {
            claimantLabels[claimant] = try label(of: claimant, in: roleLabels)
        }
        let rows = blocks.indices.map { index in
            makeRow(blocks[index], name: deviceNames[blocks[index].device] ?? "", by: claimants[index],
                    labels: claimantLabels)
        }
        return Self(
            role: role,
            headline: RouteChoiceText.headline(roleLabel: roleLabel, channelCount: requirement.channelCount),
            rows: rows,
            truncationText: candidates.truncation.map { RouteChoiceText.truncation(omitted: $0.omitted) }
        )
    }

    private static func label(
        of role: RoleID, in labels: [RoleID: String]
    ) throws(RouteChoiceListRefusal) -> String {
        guard let label = labels[role] else { throw .missingRoleLabel(role) }
        let bytes = label.utf8.count
        guard RouteChoiceLimits.nameBytes.contains(bytes) else { throw .invalidRoleLabelLength(role, bytes: bytes) }
        return label
    }

    /// The smallest offending device ID by UTF-8 bytes wins, whether its name is missing or the wrong length.
    private static func checkDeviceNames(
        of blocks: [RigRouteCandidate], in names: [DeviceID: String]
    ) throws(RouteChoiceListRefusal) {
        for device in Set(blocks.map(\.device)).sorted(by: { bytesPrecede($0, $1) }) {
            guard let name = names[device] else { throw .missingDeviceName(device) }
            let bytes = name.utf8.count
            guard RouteChoiceLimits.nameBytes.contains(bytes) else {
                throw .invalidDeviceNameLength(device, bytes: bytes)
            }
        }
    }

    /// The distinct roles, in RoleID byte order, of the live routes that use the candidate's channels. Mirrors the
    /// policy in `RigChannelOverlap.swift`: only `.proposed` and `.confirmed` routes claim, per device and
    /// direction. The target role's own route is the one a choice replaces, so it never claims.
    private static func claimants(
        of candidate: RigRouteCandidate, role: RoleID, in routes: [AudioRoute]
    ) -> [RoleID] {
        let block = Set(candidate.channels)
        let roles = routes.filter { route in
            (route.binding == .proposed || route.binding == .confirmed)
                && route.device == candidate.device
                && route.direction == candidate.direction
                && route.role != role
                && route.channels.contains(where: block.contains)
        }.map(\.role)
        return Set(roles).sorted(by: { bytesPrecede($0, $1) })
    }

    private static func makeRow(
        _ candidate: RigRouteCandidate, name: String, by claimants: [RoleID], labels: [RoleID: String]
    ) -> RouteChoiceRow {
        let state: RouteChoiceState = switch (claimants.isEmpty, candidate.direction) {
        case (true, _): .available
        case (false, .input): .sharedInput(by: claimants)
        case (false, .output): .outputInUse(by: claimants)
        }
        return RouteChoiceRow(
            candidate: candidate, deviceName: name, state: state,
            stateText: RouteChoiceText.state(state, labels: claimants.compactMap { labels[$0] })
        )
    }
}

private func bytesPrecede<Tag: ContractIDTag>(_ lhs: ContractID<Tag>, _ rhs: ContractID<Tag>) -> Bool {
    lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
}
