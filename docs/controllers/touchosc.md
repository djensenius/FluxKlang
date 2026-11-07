# Using a TouchOSC-style client with FluxKlang

These notes are original. They describe the neutral OSC address table that FluxKlang's namespace mapper accepts
and the limits that apply to every packet, so that any OSC client, TouchOSC included, can be configured against
it. The notes contain no editor output, no vendor layout and no vendor test plan, and the repository holds no
`.tosc` file. Build your own layout in your own editor.

The examples change no hardware or console state. Every packet in this folder is a synthetic byte array fed to a
pure value in a test; nothing opens a socket, and nothing talks to a mixer, a MIDI port or a network.

## Ground rules

- The OSC endpoint is opt-in and default-off. A fresh intake pipeline refuses every packet as `endpointDisabled`
  until the host enables it with a validated policy, and `disable()` returns it to exactly that fresh value.
- IP allowlists are not authentication. An address allow-list decides which OSC addresses are listened to; it never
  says who sent a packet. Treat any packet on an open OSC port as coming from anyone who can reach that port.
- Hazardous actions are never reachable through OSC. The families `route`, `patch`, `draft`, `safety` and `hazard`
  are refused by name, whatever the leaf and whatever the arguments, and a parameter that is not live cannot be
  named in a route table at all.
- OSC carries requests, not facts. A request is mapped to one command operation and then goes through the host's
  normal admission checks, which may still refuse it (for example above a host ceiling).

## The address table

`Examples/TouchOSC/address-table.json` lists every address the mapper accepts for the bundled WING catalog, with
the argument types, the value range, the unit and one example argument list. It also lists refused addresses with
the typed refusal each one produces. The same table is embedded in `FluxKlangTests/TouchOSCInteropTests+Table.swift`,
and a test compares the two byte for byte whenever the checkout is present.

All addresses live under `/fk/v1`. After the namespace comes a family, then the route names:

| Family      | Shape                       | Meaning                                              |
|-------------|-----------------------------|------------------------------------------------------|
| `param`     | `/fk/v1/param/<name>`       | Set a live parameter to one number                   |
| `param`     | `/fk/v1/param/<name>/ramp`  | Ramp a live parameter to a number over milliseconds  |
| `action`    | `/fk/v1/action/<name>`      | Trigger a named action (no argument, or one impulse) |
| `transport` | `/fk/v1/transport/<verb>`   | `start`, `stop`, or `locate` with a tick count       |

The parameter names in the bundled table are `fader`, `mute`, `pan`, `send` and `colour`; the actions are `go` and
`next`. A host that builds its own route table chooses its own names, within the same grammar.

### Arguments

- A set takes exactly one number: `float32` or `int32`. A ramp takes a number and then an `int32` duration in
  milliseconds from 0 to 60,000.
- A number must be finite. The mapper never clamps and never rounds; range and ceiling checks belong to the host.
- `start` and `stop` take no argument. `locate` takes one `int32` or `int64` tick count, from zero up to the largest
  `int64`; the table's `ticks` bound is that bound, and a negative count is refused as `negativeTicks`.
- Strings, blobs, booleans and other tags are refused as unsupported arguments, with the index and the type tag.

### Refused on purpose

| Address                          | Typed refusal                   |
|----------------------------------|---------------------------------|
| `/fk/v1/route/main`              | `refusedFamily(route)`          |
| `/fk/v1/patch/scene`             | `refusedFamily(patch)`          |
| `/fk/v1/draft/new`               | `refusedFamily(draft)`          |
| `/fk/v1/safety/mute`             | `refusedFamily(safety)`         |
| `/fk/v1/hazard/panic`            | `refusedFamily(hazard)`         |
| `/fk/v1/param/*`                 | `wildcardAddress`               |
| `/fk/v1/unknown/fader`           | `unknownFamily`                 |
| `/fk/v1/param/fader/jump`        | `unknownRoute(segmentCount: 5)` |
| `/other/v1/param/fader`          | `outsideNamespace`              |

A wildcard address is refused by the mapper because a client message must name one target. Intake may also
refuse a wildcard earlier, as it does for any address that is not on its allow-list.

## Limits

| Limit                          | Value   | Tested at                                            |
|--------------------------------|---------|------------------------------------------------------|
| Address length                 | 256 B   | N unreachable; 257 refused as `addressTooLong`       |
| Segments per address           | 6       | a seventh is `tooManySegments`                       |
| Bytes per segment              | 32      | 33 is `segmentTooLong`                               |
| Messages per batch             | 1,024   | 1,025 is `tooManyMessages`, before any is read       |
| Ramp duration                  | 60,000  | 60,001 ms and negative values are refused            |
| Elements per bundle (intake)   | 1,024   | 1,025 is `malformed(tooManyElements)`                |

An address of exactly 256 bytes can never be accepted: six segments of at most 32 bytes make at most 198 bytes, so
the segment limit is reached first. Segment bytes are `a` to `z`, `0` to `9`, `_` and `-`. The OSC codec admits
printable ASCII only, so an address with a multi-byte UTF-8 byte is refused as malformed before the mapper runs.

## Order of refusals

Packets pass through two stages that a host wires together. The intake stage is a pure value; the mapper is a
later stage that the host calls for each accepted message.

1. Intake gates, in order: disabled, wrong transport, a tick running backwards, size, peer table, quarantine,
   packet budget, byte budget. These refuse without charging and leave the pipeline unchanged. The size gate
   charges nothing only for a datagram above the whole byte allowance (`datagramTooLarge`) or a stream chunk above
   the chunk limit (`chunkTooLarge`). A datagram above the policy's packet size but within the byte allowance is
   charged and then refused as `malformed`.
2. Decoding: a packet the codec cannot read is `malformed`, and it counts as one strike against the sender. A peer
   that goes over its strike limit in one window is quarantined for the cooldown.
3. The allow-list: an address that is not listed is `notAdmitted`.
4. The mapper, per message: address length, wildcard, segment count, segment length, namespace, segment bytes,
   refused family, unknown family, route, argument count, argument types, finiteness, ramp range.

So a malformed packet to a disabled endpoint reports `endpointDisabled`, and a malformed packet that arrives after
the packet budget is spent reports `packetBudgetExceeded`. Each pair above has a test that holds both defects at
once, so a change of order is caught.

## UDP and TCP

A datagram carries one OSC packet. A stream carries packets with a four-byte big-endian length in front of each.
A policy is built for one of them; calling the other way is refused as `wrongTransport` and changes nothing.
The same packet bytes give the same mapped operation by either route, however a stream is cut into chunks.

## Feedback to the controller

A controller that moves a control is told the host's answer through the feedback planner, which emits neutral
position messages. It does not encode OSC; a host turns a message into whatever its client expects. Two short
scripts in the tests show the behaviour that matters to a client author:

- A client asks for 90 on a control whose host ceiling is 50. The planner is told the controller moved, the host
  clamps, and the planner sends the clamped position once. The client's echo of that value is recognised as an echo
  and is not applied again. A later refresh says nothing until `forget` makes the planner tell the client again.
- At most `emitBudget` corrections go out in one window. The next is coalesced, and `due(at:)` names the tick at
  which a re-plan will send it.

## Setting up a client

1. Point your client at the host's OSC port, with UDP or TCP matching the policy the host enabled.
2. Create one control per row of the address table you need, with the listed argument type and range.
3. Send fader, pan and send values as `float32`, mute and colour as `int32`, and ramps as a value then milliseconds.
4. Do not rely on the client to learn why a packet was refused: the intake stage returns a typed refusal to the host,
   and nothing here sends it back over the wire.
5. Remember the first rule: nothing here is authentication, so keep the port on a trusted network segment.

## Not covered by tests

The tests in this slice do not pin these behaviours of the merged code, so do not rely on this folder for them:

- How an allow-list entry matches an address, beyond the addresses used in the table.
- Quarantine release after the cooldown, idle expiry of peers, a full peer table, and the byte budget.
- SLIP framing of a stream, and stream frames longer than 255 bytes.
- Peer isolation: that one sender's strikes never count against another.
- How a controller's value is turned into OSC bytes on the way out; the feedback tests stop at the planner's message.
- Hold and touch handling in the feedback planner.
- Whether a transport verb is enabled at all; the tests enable all three.
- The shape of an action route (its segment count).
