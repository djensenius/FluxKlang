# Phone Compact Routing

Owner: #101 typed-wiring-editor (shell and Safety placement #99, route mapping #100). Examples:
`graph.json`, `phone-host.json` (`rig.host-b` routes/`unmappedRoles`, `nodeStatus`, `dft.phone-cue`,
`cmd.0101`/`cmd.0102`).

## Purpose

`per.host-b` is a phone running as a **full host** in its own host session (`ses.host-b`) over the same
project file. It has its own rig, lease and epoch, is the only authority over its own live graph, and is
not a member of Host A's session. Compact width replaces the canvas with
lists, pickers and sheets. The permissions are the same as on any host, and every edit is the same
draft operation that the canvas produces.

## Three narrow screens

```text
1. Connections                  2. Add Connection: To           3. Draft added
+-----------------------------+ +-----------------------------+ +-----------------------------+
|< Wiring   Connections  [+]  | |< From: Vocal (1ch audio)    | |< Wiring   Connections  [+]  |
|Active rev 43                | |To                           | |Active rev 43                |
|MAINS (2ch)                  | | Cue in      2ch  convert  > | |CUE (2ch)  Unmapped          |
| Room Verb -> Mains          | | Room Verb   2ch  convert  > | | + Vocal -> Cue    DRAFT     |
| Vocal -> Mains  mono>both   | | Space in    2ch  convert  > | |   Mono to both sides        |
|ROOM VERB (2ch)              | | Tape Echo   2ch  convert  > | |   [Remove from draft]       |
| Keys -> Room Verb           | |   (Missing: stays silent)   | |MAINS (2ch)                  |
| Tape Echo -> Room Verb      | | Mains in    2ch             | | Room Verb -> Mains          |
|TAPE ECHO (2ch)  Missing     | |   Already connected         | | Vocal -> Mains  mono>both   |
| Keys -> Tape Echo           | | Verb Mod    control         | | ...                         |
| Room Verb -> Tape Echo  fb  | |   Not available: audio can- | |                             |
|SOFT SYNTH (MIDI)            | |   not feed a control input  | |                             |
| Pads -> Soft Synth Unmapped | | Soft Synth  MIDI            | |                             |
|SPACE (2ch)  Unmapped        | |   Not available: audio can- | |                             |
| Soft Synth -> Space         | |   not feed a MIDI input     | |                             |
|CUE (2ch)  Unmapped          | |                             | |1 change - Draft on rev 43   |
| No connections   [Map...]   | |                             | |           [Review...]       |
|-----------------------------| |-----------------------------| |-----------------------------|
| [Safe Mute]       [PANIC]   | | [Safe Mute]       [PANIC]   | | [Safe Mute]       [PANIC]   |
+-----------------------------+ +-----------------------------+ +-----------------------------+
```

Rows are grouped by destination, so "what feeds Mains?" is one heading. Channel counts and states are
text. The Safety bar is pinned outside the scrolling list.

## Add Connection flow

| Step | Picker | Rules |
|---|---|---|
| 1 From | Outputs grouped by node, with signal and channel count | Observed shortcuts (`nod.ch7`) are listed as "observed, not routable" and disabled |
| 2 To | Inputs of every node | Incompatible or duplicate entries stay **visible but disabled** with a reason ("Already connected"); a cycle is offered only as "Add as feedback..." |
| 3 Conversion | Only when the channel counts differ | No preselected up-mix; the user picks "Mono to both sides" (`[[0], [0]]`), "Left only" (`[[0], []]`, right silent) and so on |
| 4 Result | Draft row with a Draft badge | `cmd.0101` → `draftUpdated`; the review bar shows the count |

Review opens the standard sheet ([draft-active-transactions.md](draft-active-transactions.md)) as a
full-height page. `cmd.0102` → `reviewRequired`, exactly as on a Mac host.

## Equivalents for every gesture

| Gesture | Button | VoiceOver custom action | Hardware keyboard (proposed) |
|---|---|---|---|
| Swipe row to remove | Edit mode → "Remove" | "Remove from draft" | Delete |
| Long-press for details | Row disclosure (>) | "Show in inspector" | Return |
| Pull to refresh devices | Status > Devices > "Rescan" | "Rescan" | Command-R |
| Reorder | Not used: order comes from the graph | — | — |

VoiceOver row: *"Vocal to Mains, audio, mono to both sides, active."* A draft row ends with *"draft, not
active"*. Section headings are on the Headings rotor. At the largest accessibility text sizes, rows
stack label over detail, and the Safety bar stacks its two buttons vertically. Safety is never moved into a "More" menu.

## Mapping an unmapped role (host-local)

`rol.cue` is in `unmappedRoles`. **Map...** opens a route picker (owned by #100):

```text
Map Cue (2ch) on this phone (Host B)
  Interface P   Out 1-2   in use by Mains
  Interface P   Out 3-4   available        >
  Phone audio   Out 1-2   headphones       >
  Other hosts' devices are never listed (rigs are not synced)
  [Cancel]
```

Picking Phone audio creates the host-local proposal `rte.p-cue`. It needs host review (`device.configure`), is never
synced to peers, and never changes the portable project role. Console connector numbers are not
offered as interface channels.

## States

| State | Row | Actions |
|---|---|---|
| Active | Plain row | Remove (draft), Inspect |
| Draft add / remove | DRAFT badge / struck-through with "Will remove" | Remove from draft / Restore |
| Unmapped destination | Heading suffix "Unmapped" | Map... |
| Missing node | Heading suffix "Missing" | Locate, Replace, Keep placeholder |
| Lost/Muted | Heading suffix "Lost/Muted"; meters Unavailable | Choose another device, Keep muted |
| Stale draft | Banner "Based on rev 42; active is 43" | Rebase |
| Remote (not host) | Read-only list, "Hosts edit structure" | None; peer Safety is open for #94 |
