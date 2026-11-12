//
//  MIDICIMcoded7Refusal.swift
//  FluxKlang
//
//  Why `MIDICIMcoded7.decode` refused its input (#83, slice MCO1). A separate type from `MIDICIRefusal`, which has an
//  unrelated `dataByteHigh(offset:)` for envelope payloads. Nothing calls it yet.
//

enum MIDICIMcoded7Refusal: Error, Equatable, Hashable, Sendable {
    /// A byte of the encoded input is 0x80 or more; `offset` is its index in the input.
    case dataByteHigh(offset: Int)
    /// The input ends with a header byte that has no data byte after it; `offset` is that header byte's index.
    case truncatedGroup(offset: Int)
}
