/// Preparation admission only; generic persistence and graph limits are unchanged.
enum PreparationProjectRefusal: Error, Hashable, Sendable {
    case structuralLimit
    case formatBounds(ProjectGraphLimitError)
    case encodedLimit
    case encoding
    case selected(ProjectValidationError)
}

/// Walks retained values, not their serialized projection. No sorting, hashing,
/// encoding, semantic indexes or input-sized scratch storage precedes this walk.
/// These caps bound newly admitted project processing, not caller allocations,
/// graph bodies, Foundation overhead, peak heap or real-time work.
struct PreparationProjectBudget {
    static let encodedBytes = 65_536
    private var textRemaining = 131_072
    private var valuesRemaining = 16_384
    private var membersRemaining = 16_384
    private var containersRemaining = 2_048

    static func check(_ project: ProjectDocument) throws(PreparationProjectRefusal) {
        do { try project.checkCollectionBounds() } catch { throw .formatBounds(error) }
        var budget = Self()
        try budget.project(project)
    }

    private mutating func value(depth: Int) throws(PreparationProjectRefusal) {
        guard (1...32).contains(depth), valuesRemaining > 0 else { throw .structuralLimit }
        valuesRemaining -= 1
    }

    /// Also used for typed records. Check immediate children before iteration;
    /// descendants are charged separately, so a shared COW value is never free.
    mutating func container(depth: Int, members: Int) throws(PreparationProjectRefusal) {
        try value(depth: depth)
        guard containersRemaining > 0, members >= 0,
              members <= membersRemaining, members <= valuesRemaining else { throw .structuralLimit }
        containersRemaining -= 1
        membersRemaining -= members
    }

    /// Names and text are scanned only through the first exceeding byte.
    mutating func text(_ string: String) throws(PreparationProjectRefusal) {
        for _ in string.utf8 {
            guard textRemaining > 0 else { throw .structuralLimit }
            textRemaining -= 1
        }
    }

    /// The containing record has already charged this member. Nil optionals
    /// are scalar leaves; present optionals have no additional wrapper.
    mutating func scalar(_ name: String, depth: Int, text string: String? = nil)
        throws(PreparationProjectRefusal) {
        try value(depth: depth)
        try text(name)
        if let string { try text(string) }
    }

    mutating func bag(_ name: String, _ fields: [String: JSONValue]?, depth: Int)
        throws(PreparationProjectRefusal) {
        try text(name)
        if let fields {
            try dictionary(fields, depth: depth)
        } else {
            try value(depth: depth)
        }
    }

    private mutating func dictionary(_ fields: [String: JSONValue], depth: Int)
        throws(PreparationProjectRefusal) {
        try container(depth: depth, members: fields.count)
        for (key, child) in fields {
            try text(key)
            try json(child, depth: depth + 1)
        }
    }

    private mutating func json(_ child: JSONValue, depth: Int) throws(PreparationProjectRefusal) {
        switch child {
        case .array(let children):
            try container(depth: depth, members: children.count)
            for child in children { try json(child, depth: depth + 1) }
        case .object(let fields):
            try dictionary(fields, depth: depth)
        case .string(let string):
            try value(depth: depth)
            try text(string)
        case .null, .bool, .int, .uint, .double:
            try value(depth: depth)
        }
    }

    private mutating func project(_ project: ProjectDocument) throws(PreparationProjectRefusal) {
        // Ten stored fields plus the two header scalars: exactly 32 header
        // text bytes, no wrapper, punctuation or invented requiredFeatures.
        try container(depth: 1, members: 12)
        try scalar("contract", depth: 2, text: "fluxklang.project")
        try scalar("version", depth: 2)
        try scalar("id", depth: 2, text: project.id.rawValue)
        try scalar("revision", depth: 2)
        try scalar("name", depth: 2, text: project.name)
        try text("graphs")
        try container(depth: 2, members: project.graphs.count)
        for reference in project.graphs { try graph(reference, depth: 3) }
        try text("roles")
        try container(depth: 2, members: project.roles.count)
        for record in project.roles { try role(record, depth: 3) }
        try text("patches")
        try container(depth: 2, members: project.patches.count)
        for record in project.patches { try patch(record, depth: 3) }
        try text("assets")
        try container(depth: 2, members: project.assets.count)
        for record in project.assets { try asset(record, depth: 3) }
        try text("actions")
        try container(depth: 2, members: project.actions.count)
        for record in project.actions { try action(record, depth: 3) }
        try bag("extensions", project.extensions, depth: 2)
        try bag("unknownFields", project.unknownFields, depth: 2)
    }

    private mutating func graph(_ graph: ProjectGraphReference, depth: Int)
        throws(PreparationProjectRefusal) {
        try container(depth: depth, members: 4)
        try scalar("graph", depth: depth + 1, text: graph.graph.rawValue)
        try scalar("revision", depth: depth + 1)
        try bag("extensions", graph.extensions, depth: depth + 1)
        try bag("unknownFields", graph.unknownFields, depth: depth + 1)
    }

    private mutating func role(_ role: ProjectRole, depth: Int) throws(PreparationProjectRefusal) {
        try container(depth: depth, members: 7)
        try scalar("id", depth: depth + 1, text: role.id.rawValue)
        try scalar("label", depth: depth + 1, text: role.label)
        try scalar("direction", depth: depth + 1, text: role.direction.rawValue)
        try scalar("signal", depth: depth + 1, text: role.signal.rawValue)
        try scalar("channels", depth: depth + 1)
        try bag("extensions", role.extensions, depth: depth + 1)
        try bag("unknownFields", role.unknownFields, depth: depth + 1)
    }

    private mutating func patch(_ patch: ProjectPatch, depth: Int) throws(PreparationProjectRefusal) {
        try container(depth: depth, members: 5)
        try scalar("id", depth: depth + 1, text: patch.id.rawValue)
        try scalar("label", depth: depth + 1, text: patch.label)
        try scalar("graph", depth: depth + 1, text: patch.graph.rawValue)
        try bag("extensions", patch.extensions, depth: depth + 1)
        try bag("unknownFields", patch.unknownFields, depth: depth + 1)
    }

    private mutating func timing(_ timing: AssetTiming, depth: Int) throws(PreparationProjectRefusal) {
        try container(depth: depth, members: 5)
        try scalar("startFrame", depth: depth + 1)
        try scalar("startTicks", depth: depth + 1)
        try scalar("startOffsetNs", depth: depth + 1)
        try bag("extensions", timing.extensions, depth: depth + 1)
        try bag("unknownFields", timing.unknownFields, depth: depth + 1)
    }

    private mutating func asset(_ asset: ProjectAsset, depth: Int) throws(PreparationProjectRefusal) {
        try container(depth: depth, members: 9)
        try scalar("id", depth: depth + 1, text: asset.id.rawValue)
        try scalar("label", depth: depth + 1, text: asset.label)
        try scalar("media", depth: depth + 1, text: asset.media.rawValue)
        try scalar("contentDigest", depth: depth + 1, text: asset.contentDigest)
        try scalar("byteCount", depth: depth + 1)
        try scalar("timePolicy", depth: depth + 1, text: asset.timePolicy?.rawValue)
        try text("timing")
        if let timing = asset.timing {
            try self.timing(timing, depth: depth + 1)
        } else {
            try value(depth: depth + 1)
        }
        try bag("extensions", asset.extensions, depth: depth + 1)
        try bag("unknownFields", asset.unknownFields, depth: depth + 1)
    }

    private mutating func action(_ action: ProjectMediaAction, depth: Int) throws(PreparationProjectRefusal) {
        try container(depth: depth, members: 5)
        try scalar("id", depth: depth + 1, text: action.id.rawValue)
        try scalar("asset", depth: depth + 1, text: action.asset.rawValue)
        try text("policy")
        try action.policy.checkPreparationBudget(&self, depth: depth + 1)
        try bag("extensions", action.extensions, depth: depth + 1)
        try bag("unknownFields", action.unknownFields, depth: depth + 1)
    }
}
