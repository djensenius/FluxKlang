//
//  OpenSoundControl+NamespaceRefusal.swift
//  FluxKlang
//
//  Typed refusals of the neutral OSC namespace (#89, slice O2a). Payloads are
//  counts, indexes, type tags and closed enums only: never address bytes or
//  argument text. A refusal returns no operation and changes nothing.
//

extension OpenSoundControl {
    /// Why one message did not map. Cases are listed in the order the mapper checks them.
    enum NamespaceRefusal: Error, Sendable, Hashable {
        case addressTooLong(byteCount: Int, limit: Int)
        case wildcardAddress
        case tooManySegments(count: Int, limit: Int)
        case segmentTooLong(index: Int, byteCount: Int, limit: Int)
        case outsideNamespace(segmentCount: Int)
        case missingFamily
        case invalidSegment(index: Int, byteOffset: Int)
        case refusedFamily(RefusedFamily)
        case unknownFamily
        case unknownRoute(segmentCount: Int)
        case wrongArgumentCount(minimum: Int, maximum: Int, got: Int)
        case unsupportedArgument(index: Int, typeTag: UInt8)
        case nonFiniteValue(index: Int)
        case negativeTicks
        case rampMillisecondsOutOfRange(Int)
        case operationNotLive
    }

    /// Why a batch did not map. No partial result is ever returned.
    enum NamespaceBatchRefusal: Error, Sendable, Hashable {
        case tooManyMessages(count: Int, limit: Int)
        case message(index: Int, refusal: NamespaceRefusal)
    }

    /// Why a `RouteTable` was not built. Entry indexes are array indexes within the entry's own list.
    enum RouteTableRefusal: Error, Sendable, Hashable {
        case emptyTable
        case tooManyRoutes(count: Int, limit: Int)
        case invalidName(family: NamespaceFamily, index: Int, byteCount: Int)
        case duplicateName(family: NamespaceFamily, index: Int)
        case duplicateTarget(family: NamespaceFamily, index: Int)
        case unknownParameter(index: Int)
        case parameterNotLive(index: Int, controlClass: ControlClass)
        case duplicateTransport(index: Int)
    }
}
