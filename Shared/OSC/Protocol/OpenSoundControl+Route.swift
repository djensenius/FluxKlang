//
//  OpenSoundControl+Route.swift
//  FluxKlang
//
//  The validated route table of the neutral OSC namespace (#89, slice O2a).
//  The table, not the mapper, owns every name. Parameter routes are limited to
//  live catalog descriptors, so structural and hazardous parameters can never
//  be routed whatever their name. The table copies each unit from the catalog
//  at construction; a later catalog change needs a rebuilt table (adapter
//  concern). Admission still revalidates class, range and ceiling.
//

extension OpenSoundControl {
    /// A name for a parameter. A plain value: it is validated only inside `RouteTable.init`.
    struct ParameterRoute: Sendable, Hashable {
        let name: String
        let id: ParameterID

        init(name: String, id: ParameterID) {
            self.name = name
            self.id = id
        }
    }

    /// A name for an action. A plain value: it is validated only inside `RouteTable.init`.
    struct ActionRoute: Sendable, Hashable {
        let name: String
        let id: ActionID

        init(name: String, id: ActionID) {
            self.name = name
            self.id = id
        }
    }

    /// A resolved parameter route: the target ID and the unit copied from the catalog.
    struct ParameterRouteTarget: Sendable, Hashable {
        let id: ParameterID
        let unit: ParameterUnit

        fileprivate init(id: ParameterID, unit: ParameterUnit) {
            self.id = id
            self.unit = unit
        }
    }

    /// An immutable, validated route table. It can only be built by the throwing initializer.
    /// Checks run check-major, first failure wins: (a) empty, (b) too many entries, (c) invalid
    /// name, (d) duplicate name, (e) duplicate target, (f) unknown parameter, (g) parameter not
    /// live, (h) duplicate transport verb. Checks (c) to (e) scan parameters, then actions, in array
    /// order; (f) and (g) scan parameters only and (h) scans transport only.
    /// Names are stored and compared as UTF-8 bytes, never as `String`.
    struct RouteTable: Sendable, Equatable {
        private(set) var parameterTargets: [[UInt8]: ParameterRouteTarget]
        private(set) var actionTargets: [[UInt8]: ActionID]
        private(set) var enabledTransport: Set<TransportVerb>

        init(
            parameters: [ParameterRoute], actions: [ActionRoute], transport: [TransportVerb], catalog: ParameterCatalog
        ) throws(RouteTableRefusal) {
            try Self.requireSize(parameters: parameters.count, actions: actions.count, transport: transport.count)
            let parameterNames = parameters.map { Array($0.name.utf8) }
            let actionNames = actions.map { Array($0.name.utf8) }
            try Self.requireValidNames(parameterNames, family: .param)
            try Self.requireValidNames(actionNames, family: .action)
            try Self.requireUnique(parameterNames, family: .param, duplicate: Self.duplicateName)
            try Self.requireUnique(actionNames, family: .action, duplicate: Self.duplicateName)
            try Self.requireUnique(parameters.map(\.id), family: .param, duplicate: Self.duplicateTarget)
            try Self.requireUnique(actions.map(\.id), family: .action, duplicate: Self.duplicateTarget)
            let targets = try Self.resolve(parameters, in: catalog)
            try Self.requireUniqueVerbs(transport)
            parameterTargets = Dictionary(uniqueKeysWithValues: zip(parameterNames, targets))
            actionTargets = Dictionary(uniqueKeysWithValues: zip(actionNames, actions.map(\.id)))
            enabledTransport = Set(transport)
        }

        var parameterRouteCount: Int { parameterTargets.count }
        var actionRouteCount: Int { actionTargets.count }

        func parameterTarget(named name: [UInt8]) -> ParameterRouteTarget? { parameterTargets[name] }
        func actionID(named name: [UInt8]) -> ActionID? { actionTargets[name] }
        func isEnabled(_ verb: TransportVerb) -> Bool { enabledTransport.contains(verb) }

        /// The entry total; `Int.max` when the sum overflows, so the size check refuses it.
        static func entryTotal(parameters: Int, actions: Int, transport: Int) -> Int {
            let first = parameters.addingReportingOverflow(actions)
            let second = first.partialValue.addingReportingOverflow(transport)
            return first.overflow || second.overflow ? Int.max : second.partialValue
        }

        private static func requireSize(parameters: Int, actions: Int, transport: Int) throws(RouteTableRefusal) {
            let total = entryTotal(parameters: parameters, actions: actions, transport: transport)
            guard total != 0 else { throw .emptyTable }
            guard total <= NamespaceLimits.maximumRoutes else {
                throw .tooManyRoutes(count: total, limit: NamespaceLimits.maximumRoutes)
            }
        }

        private static func requireValidNames(
            _ names: [[UInt8]], family: NamespaceFamily
        ) throws(RouteTableRefusal) {
            for (index, name) in names.enumerated() {
                let validLength = !name.isEmpty && name.count <= NamespaceLimits.maximumSegmentBytes
                guard validLength, name.allSatisfy(NamespaceLimits.isNameByte) else {
                    throw .invalidName(family: family, index: index, byteCount: name.count)
                }
            }
        }

        private static func duplicateName(_ family: NamespaceFamily, _ index: Int) -> RouteTableRefusal {
            .duplicateName(family: family, index: index)
        }

        private static func duplicateTarget(_ family: NamespaceFamily, _ index: Int) -> RouteTableRefusal {
            .duplicateTarget(family: family, index: index)
        }

        private static func requireUnique<Key: Hashable>(
            _ keys: [Key], family: NamespaceFamily, duplicate: (NamespaceFamily, Int) -> RouteTableRefusal
        ) throws(RouteTableRefusal) {
            var seen = Set<Key>()
            for (index, key) in keys.enumerated() where !seen.insert(key).inserted {
                throw duplicate(family, index)
            }
        }

        private static func resolve(
            _ routes: [ParameterRoute], in catalog: ParameterCatalog
        ) throws(RouteTableRefusal) -> [ParameterRouteTarget] {
            var descriptors: [ParameterDescriptor] = []
            for (index, route) in routes.enumerated() {
                guard let descriptor = catalog[route.id] else { throw .unknownParameter(index: index) }
                descriptors.append(descriptor)
            }
            for (index, descriptor) in descriptors.enumerated() where descriptor.fields.controlClass != .live {
                throw .parameterNotLive(index: index, controlClass: descriptor.fields.controlClass)
            }
            return zip(routes, descriptors).map { ParameterRouteTarget(id: $0.id, unit: $1.fields.unit) }
        }

        private static func requireUniqueVerbs(_ verbs: [TransportVerb]) throws(RouteTableRefusal) {
            var seen = Set<TransportVerb>()
            for (index, verb) in verbs.enumerated() where !seen.insert(verb).inserted {
                throw .duplicateTransport(index: index)
            }
        }
    }
}
