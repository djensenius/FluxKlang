# Wiring

Owner: #101 typed-wiring-editor (shell/inspector container: #99). Examples: `graph.json`,
`transactions.json`, `session.json` `nodeStatus`. Contract owner: #54.

## Purpose

Edit a typed multichannel audio/MIDI/control graph without ever activating it implicitly.
Every edit lands in a **draft** based on an explicit active revision. Activation is a separate,
reviewed transaction ([draft-active-transactions.md](draft-active-transactions.md)).

## Regular layout (Mac, iPad regular width)

```text
+-- Wiring - Example Set - Active rev 43 - Draft: 1 change - [Review...] [Safe Mute] [PANIC] ------------+
| Sources        | Canvas  (Canvas | Matrix | List)                          | Inspector                 |
| Keys      2ch  |                                                           | Edge: Vocal -> Mains      |
| Vocal     1ch  | [Keys]==2==+===================>[Room Verb]==2==>[Mains]  | audio 1ch -> 2ch          |
| Pads     MIDI  |            |                     ^       |          ^     | Conversion: Mono to both  |
| Soft Synth     |            +==2==>[Tape Echo ?]==+       |          |     | Active since rev 43       |
| Room Verb      |                     ^---- fb, 1 block ---+          |     | Provenance: manual        |
| Tape Echo  ?   | [Vocal]--1->2 mono to both--------------------------+     | [Remove (as draft)]       |
| Cue        o   | [Pads]~~midi~~>[Soft Synth]==2==>[Space !]   [Cue o]      |                           |
| [+ Add Node]   | Needs attention (4) > Tape Echo missing ...               |                           |
+----------------+-----------------------------------------------------------+---------------------------+
  Legend: ==n==> audio with channel count; ~~midi~~> MIDI; -1->2 explicit conversion;
  ? Missing, ! Lost/Muted, o Unmapped. Every badge also has a text label and a VoiceOver label.
```

The canvas, matrix and list views share one selection and one draft. Switching views never
drops a pending connect gesture silently: it cancels the gesture and says so.

## Non-drag, keyboard and VoiceOver paths

| Task | Pointer/touch | Keyboard (proposed; final keys owned by #99/#101) | VoiceOver / Switch Control | List or matrix |
|---|---|---|---|---|
| Add node | Drag from Sources | Select in Sources, then Return ("Add to Wiring") | Custom action "Add to Wiring" | `+ Add Node...` menu |
| Connect | Drag port to port | Focus port, `C`, then pick destination; Return | Port custom action "Connect to..." opens the picker | Matrix cell toggle; List "Add Connection" |
| Choose conversion | Inline popup on wire | Inspector field focus, arrow keys | Adjustable "Conversion" | Picker in step 3 |
| Remove edge | Select wire, Delete | Focus edge in Connections, Delete | Custom action "Remove from draft" | Row button "Remove" |
| Move node | Drag | Arrow keys move one grid step; Shift moves fine | Custom action "Move..." with numeric x/y | Not needed; position is layout data |
| Review/activate | Toolbar | Command-Return opens Review | "Review draft" in the toolbar rotor | Review bar |
| Undo in draft | Edit menu | Command-Z / Shift-Command-Z | Undo action | Same |

VoiceOver element for a node: *"Room Verb, plugin, Ready. 2 inputs, 1 output. 4 connections, 1 feedback."*
Rotors: **Ports**, **Connections**, **Needs attention**. Edge label: *"Keys to Room Verb, audio,
2 channels, active."* A draft edge adds *"draft, not active"*.

## Connection validation (precise rejection)

| Case | Example | UI result |
|---|---|---|
| Valid | `prt.keys.out` → `prt.verb.in` (2→2) | Added to draft |
| Needs conversion | `prt.mic.out` (1) → `prt.mains.in` (2) | Conversion picker; no implicit up-mix |
| Signal mismatch | audio → `prt.verb.mod` (control) | Destination listed but disabled: "Audio cannot feed a control input without a conversion" (`txn.bad-wire`) |
| Direction | input → input | Not offered as a destination |
| Cycle | `prt.verb.out` → `prt.echo.in` | Offered only with "Feedback (1-block delay, ceiling −6 dB)"; never inferred (`edg.verb-echo-fb`) |
| Duplicate | Same from/to already wired | Not offered; focus moves to the existing edge |
| Observed shortcut | Any port on `nod.ch7` | Node has no ports; label says "observed, not routable" |

## Node and edge states

| State | Source of truth | Badge text | Allowed edits |
|---|---|---|---|
| Ready / Mapped | `session.json` `nodeStatus` | none, or the route name | All |
| Unmapped (`nod.cue`) | role in `devices.json` `unmappedRoles` | "Unmapped on this host" | All; "Map..." opens the rig flow (#100) |
| Missing (`nod.echo`) | capability `missing` | "Missing plugin: branch silent" | Locate, Replace, Keep placeholder; no auto-bypass |
| Stale (`nod.pads`) | device `stale` | "Last seen previous session" | All; Rescan |
| Lost/Muted (`nod.space`) | route `deviceMissing` while running | "Lost: outputs muted" | All; changes stay draft |
| Draft-added / Draft-removed | draft ops | "Draft" / struck-through + "Will remove" | Undo, Remove from draft |
| Stale draft (`dft.old-base`) | base ≠ active | "Based on rev 42; active is 43" | Rebase, then review again |

## Contract seams

Reads: graph nodes/ports/edges, node status, capabilities, diagnostics. Writes: **draft ops only**
(`connect`, `disconnect`, `addNode`, `removeNode`). The surface never writes active graph revisions,
device routes or engine state.
