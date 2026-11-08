# TouchOSC examples

`address-table.json` is a neutral table of the OSC addresses FluxKlang's namespace mapper accepts, with the typed
refusal for each address it refuses. It is original work: it is not TouchOSC editor output, and the repository holds
no `.tosc` layout. Use it to build your own layout in your own editor.

The examples change no hardware or console state. They are read by tests that feed synthetic packets to pure
values; nothing here opens a socket or talks to a device. The OSC endpoint is opt-in and default-off, and IP
allowlists are not authentication. Hazardous actions are never reachable through OSC.

Read `docs/controllers/touchosc.md` for the grammar, the limits and the order of refusals.

## Fields

- `accepted`: one row per accepted address. `control` is a label for your layout, `address` is the full address,
  `kind` is `set`, `ramp`, `trigger`, `start`, `stop` or `locate`, `args` lists the OSC type names, `range` and
  `unit` give the bounds of a parameter, `milliseconds` gives the inclusive duration bounds of a ramp (a test drives
  the mapper at each bound and one past it), `ticks` gives the inclusive bounds of a locate count (the largest
  `int64`; an `int32` count tops out at 2147483647 by its type), and `example` is one valid argument list.
- `refused`: addresses the mapper refuses, with the name of the typed refusal. These are not an error in your
  layout; they show what a host will never route.

`FluxKlangTests/TouchOSCInteropTests+Table.swift` embeds this table and maps every row through the mapper.
