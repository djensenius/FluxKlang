//
//  MIDICIPropertyContentRefusal.swift
//  FluxKlang
//
//  Why `MIDICIPropertyContent.decode(_:)` refused a reassembled Property Exchange message (#83, slice M83-PXD, issue
//  #828). A separate type from `MIDICIRefusal`, which covers the message envelope. It wraps the refusals of the two
//  stages it runs, `MIDICIPropertyHeaderRefusal` and `MIDICIPropertyBodyRefusal`, unchanged. Nothing calls it yet.
//

/// The cases are listed in the order `MIDICIPropertyContent.decode(_:)` checks them.
enum MIDICIPropertyContentRefusal: Error, Equatable, Hashable, Sendable {
    /// 1. Property data in a kind without it (`MIDICIPropertyDataKind.hasNoPropertyData`: Get Inquiry and Set Reply);
    /// `count` is its length in bytes. Nothing was read.
    case propertyDataNotAllowed(kind: MIDICIPropertyDataKind, count: Int)
    /// 2. `MIDICIPropertyHeader.parse(_:)` refused the header data.
    case header(MIDICIPropertyHeaderRefusal)
    /// 3. `MIDICIPropertyHeader.decodeBody(_:)` refused the property data. Never for a kind without property data.
    case body(MIDICIPropertyBodyRefusal)
}
