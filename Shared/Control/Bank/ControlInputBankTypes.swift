//
//  ControlInputBankTypes.swift
//  FluxKlang
//
//  The value types a `ControlInputBank` takes and refuses with (#87, CPR1). Nothing here reads a port, registry,
//  session or clock.
//

/// Names the control origin whose bindings one MIDI input drives. The caller owns the table of links; the bank derives
/// nothing from a device, an endpoint or a registry.
struct ControlInputBankLink: Hashable, Sendable {
    let input: MIDIInputID
    let origin: ControlSourceOrigin
}

/// The host truth both dispatchers read for one `receive`.
struct ControlInputBankTruth: Sendable {
    let control: ControlHostTruth
    let trigger: ControlTriggerHostTruth
}

/// Why a bank was not built or a call was refused. A refused call leaves the bank equal to what it was.
///
/// Build order (first failure wins): `tooManyLinks`, `duplicateInput`, `duplicateOrigin`, `tooManyFaders`,
/// `tooManyTriggers`, then the faders ascending by id bytes (`unmappableSource`, `originNotLinked`, `pickup`), then the
/// triggers ascending by id bytes (`unmappableSource`, `originNotLinked`), then `trigger`.
/// `receive`: `unlinkedOrigin`, `originLost`, then `pickup`.
enum ControlInputBankRefusal: Error, Equatable, Sendable {
    /// More links than `ControlInputBank.maximumLinks`.
    case tooManyLinks(Int)
    /// Two links name this input; the smallest repeated input.
    case duplicateInput(MIDIInputID)
    /// Two links name this origin; the smallest repeated origin by UTF-8 bytes.
    case duplicateOrigin(ControlSourceOrigin)
    /// More fader bindings than `ControlInputBank.maximumFaders`.
    case tooManyFaders(Int)
    /// More trigger bindings than `ControlInputBank.maximumTriggers`.
    case tooManyTriggers(Int)
    /// The binding's source is not a canonical MIDI source id.
    case unmappableSource(BindingID)
    /// No link names the origin of the binding's source.
    case originNotLinked(BindingID, ControlSourceOrigin)
    /// The pickup book refused (a repeated binding id at build).
    case pickup(ControlPickupBookRefusal)
    /// The detector refused (a repeated binding id at build, or a `clear` of an unknown or momentary binding).
    case trigger(ControlTriggerRefusal)
    /// No link names this input.
    case unknownInput(MIDIInputID)
    /// `receive` came from an origin no link names.
    case unlinkedOrigin(ControlSourceOrigin)
    /// `receive` came from an origin whose input was reported lost.
    case originLost(ControlSourceOrigin)
}
