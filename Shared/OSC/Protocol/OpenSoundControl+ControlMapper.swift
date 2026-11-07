//
//  OpenSoundControl+ControlMapper.swift
//  FluxKlang
//
//  The pure, table-driven mapper from one already decoded and allow-listed
//  OSC message to ONE live-only `CommandOperation`, or a typed refusal (#89,
//  slice O2a). The allow-list admits addresses; this second, stricter gate
//  decides meaning. It builds no `CommandIntent`: epochs, revisions,
//  permission and origin stay with the admission caller, and admission still
//  revalidates the operation. Provisional v1 grammar (Q-OSC-NS).
//

extension OpenSoundControl {
    /// A route resolved from the address alone, before any argument is read.
    enum MappedRoute {
        case set(ParameterRouteTarget)
        case ramp(ParameterRouteTarget)
        case trigger(ActionID)
        case transport(TransportVerb)
    }

    /// Maps messages through a validated `RouteTable`. Value type; mapping never changes it.
    /// The address grammar is closed and byte-exact (case-sensitive, no inbound wildcards):
    /// `/fk/v1/param/<name>` set, `/fk/v1/param/<name>/ramp` ramp, `/fk/v1/action/<name>` trigger,
    /// `/fk/v1/transport/<verb>` start, stop or locate. Structural, safety, hazardous and
    /// proposal families are recognised and refused by name.
    struct ControlMapper: Sendable, Equatable {
        let table: RouteTable

        init(table: RouteTable) {
            self.table = table
        }

        /// Checks run in this order and the first failure wins: address length, wildcard, segment
        /// count, segment length, namespace, family presence, segment bytes, family, route, arguments,
        /// then the live-only postcondition.
        func map(_ message: Message) throws(NamespaceRefusal) -> CommandOperation {
            let segments = try Self.segments(of: message.address)
            let route = try resolve(segments)
            let operation = try Self.operation(for: route, arguments: message.arguments)
            guard NamespaceLiveness.isLive(operation) else { throw .operationNotLive }
            return operation
        }

        /// Maps in index order. More than `maximumBatchMessages` is refused before any message is
        /// read; otherwise the first failing message wins and no partial result is returned.
        func map(batch: [Message]) throws(NamespaceBatchRefusal) -> [CommandOperation] {
            guard batch.count <= NamespaceLimits.maximumBatchMessages else {
                throw .tooManyMessages(count: batch.count, limit: NamespaceLimits.maximumBatchMessages)
            }
            var operations: [CommandOperation] = []
            operations.reserveCapacity(batch.count)
            for (index, message) in batch.enumerated() {
                do {
                    operations.append(try map(message))
                } catch {
                    throw .message(index: index, refusal: error)
                }
            }
            return operations
        }

        /// Checks 1 to 7: the segments after the leading `/`, bounded and byte-checked.
        private static func segments(of address: AddressPattern) throws(NamespaceRefusal) -> [[UInt8]] {
            let bytes = address.bytes
            guard bytes.count <= NamespaceLimits.maximumAddressBytes else {
                throw .addressTooLong(byteCount: bytes.count, limit: NamespaceLimits.maximumAddressBytes)
            }
            guard !address.hasWildcards else { throw .wildcardAddress }
            let segments = bytes.dropFirst().split(separator: AddressGrammar.slash, omittingEmptySubsequences: false)
                .map { Array($0) }
            guard segments.count <= NamespaceLimits.maximumSegments else {
                throw .tooManySegments(count: segments.count, limit: NamespaceLimits.maximumSegments)
            }
            if let index = segments.firstIndex(where: { $0.count > NamespaceLimits.maximumSegmentBytes }) {
                throw .segmentTooLong(
                    index: index, byteCount: segments[index].count, limit: NamespaceLimits.maximumSegmentBytes
                )
            }
            try requireNamespace(segments)
            for (index, segment) in segments.enumerated().dropFirst(2) {
                if let offset = invalidByteOffset(in: segment) {
                    throw .invalidSegment(index: index, byteOffset: offset)
                }
            }
            return segments
        }

        /// The offset of the first byte outside `[a-z0-9_-]`; an empty segment is invalid at offset 0.
        static func invalidByteOffset(in segment: [UInt8]) -> Int? {
            segment.isEmpty ? 0 : segment.firstIndex(where: { !NamespaceLimits.isNameByte($0) })
        }

        private static func requireNamespace(_ segments: [[UInt8]]) throws(NamespaceRefusal) {
            let prefix = NamespaceLimits.namespaceSegments
            guard segments.count >= prefix.count, Array(segments.prefix(prefix.count)) == prefix else {
                throw .outsideNamespace(segmentCount: segments.count)
            }
            if segments.count == prefix.count { throw .missingFamily }
        }

        /// Checks 8 and 9: the family, then the shape and the table lookup.
        private func resolve(_ segments: [[UInt8]]) throws(NamespaceRefusal) -> MappedRoute {
            let family = segments[2]
            if let refused = RefusedFamily.allCases.first(where: { Array($0.rawValue.utf8) == family }) {
                throw .refusedFamily(refused)
            }
            guard let live = NamespaceFamily.allCases.first(where: { Array($0.rawValue.utf8) == family }) else {
                throw .unknownFamily
            }
            let route: MappedRoute?
            switch live {
            case .param: route = parameterRoute(segments)
            case .action:
                route = segments.count == 4 ? table.actionID(named: segments[3]).map(MappedRoute.trigger) : nil
            case .transport: route = transportRoute(segments)
            }
            guard let route else { throw .unknownRoute(segmentCount: segments.count) }
            return route
        }

        private static let rampSegment = Array("ramp".utf8)

        private func parameterRoute(_ segments: [[UInt8]]) -> MappedRoute? {
            guard segments.count == 4 || segments.count == 5,
                  let target = table.parameterTarget(named: segments[3]) else { return nil }
            if segments.count == 4 { return .set(target) }
            return segments[4] == Self.rampSegment ? .ramp(target) : nil
        }

        private func transportRoute(_ segments: [[UInt8]]) -> MappedRoute? {
            guard segments.count == 4,
                  let verb = TransportVerb.allCases.first(where: { Array($0.rawValue.utf8) == segments[3] }),
                  table.isEnabled(verb) else { return nil }
            return .transport(verb)
        }
    }
}
