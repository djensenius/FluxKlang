# Library and Inspector

Owner: #99 workspace-navigation-accessibility (containers). Each pane's content belongs to the lane that
owns the selection: plugins #70, plugin editors and state #77, patches #104, rigs #100, graph items #101/#54, parameters #102/#55,
media #53 (reference only). Examples: `devices.json` `capabilities`, `project.json` `patches`/`assets`,
`graph.json`, `session.json` `diagnostics`.

## Library

```text
+-- Library --------------------- [Search          ] --+
| Plugins                                              |
|   Room Verb          Installed     [Add to Wiring]   |
|   Soft Synth         Installed     [Add to Wiring]   |
|   Tape Echo          MISSING       [Resolve...]      |
|   (scan)             Not scanned   [Scan...]         |
| Patches & Variations                                 |
|   Verse              1 variation   [Recall] [Open]   |
|     Verse, wetter    2 deltas, prepared  [Recall]    |
| Rigs                                                 |
|   Host A rig         rev 7, 1 missing, 1 stale       |
| Templates                                            |
|   (none yet)                                         |
| Charts & media      (timing owned by #53)            |
|   Verse chart        Stale bookmark  [Locate...]     |
+------------------------------------------------------+
```

Status words are always text. Search filters by name, kind and status ("missing").
"Add to Wiring" inserts a draft node near the current selection, or at the end of the list
view. It is the non-drag equivalent of dragging into the canvas.

| Plugin state | Meaning | Actions |
|---|---|---|
| Installed | Capability `available` (`cap.au-effect`) | Add to Wiring, Show info |
| Missing | `cap.plugin.tape-echo` `missing`; `nod.echo` keeps a silent placeholder | **Locate...**, **Replace with...** (draft), **Keep placeholder** |
| Incompatible | Found but wrong kind or ports | Disabled "Add" with reason; Show info |
| Not scanned | Catalog not yet built (#70) | Scan... (explicit; never on launch without consent) |

Replace with... opens a picker filtered to compatible port layouts. It produces a draft that keeps
the edges where the ports still match and lists dropped edges in review. It never auto-bypasses. The
replacement's editor and opaque state come from #77; this pane only hosts them.

## Inspector

On Mac and iPad (regular width) the inspector is a trailing panel. On a compact phone it is a sheet or
a pushed page. Its content and permissions are identical in both places.

```text
+-- Inspector: Room Verb ----------------------+
| Kind       Plugin (placeholder identity)     |
| ID         nod.verb                          |
| Graph      gph.main, active rev 43           |
| State      Ready                             |
| Requires   AU effect hosting   available     |
| Ports      In 2ch audio | Mod control | Out  |
| Live       Verb Mix 30 %   [Set value...]    |
|            Room Size 0.50  [Set value...]    |
| Structure  [Replace... (draft)] [Remove...]  |
| Provenance Manual, Host A                    |
| Problems   none                              |
+----------------------------------------------+
```

Rules:

- Every editable field says whether it changes the running set now (**Live**) or edits the
  **Draft**. Structural fields never apply directly.
- IDs and revisions are visible and copyable for support and diagnostics, but they are secondary text.
- Selection is keyed by stable ID. It survives switching between canvas, matrix and list, rotation,
  Split View, and moving from regular to compact width. If the selected item disappears in a new
  revision, the inspector says "Removed in rev N" instead of going blank.
- Assistant provenance shows a badge ("Proposed by local assistant, not active").
- Multiple selection shows shared fields only and says how many items are selected.

## Non-drag, keyboard and VoiceOver paths

| Task | Keyboard (proposed) | VoiceOver |
|---|---|---|
| Open Library | Shell shortcut (#99) | Toolbar "Library" button |
| Add selected item | Return | Custom action "Add to Wiring" |
| Resolve missing plugin | Context menu via Full Keyboard Access | Custom actions Locate, Replace, Keep placeholder |
| Toggle inspector | Shell shortcut (#99) | Toolbar "Inspector" button; announcement of the selected item |
| Move between sections | Tab / arrow keys | Headings rotor; each section is a heading |

## States

| State | Library | Inspector |
|---|---|---|
| Nothing selected | — | "Select a node, edge, speaker or control" |
| Draft item | Draft badge | Fields labelled Draft; "Not in active rev 43" |
| Missing | MISSING + actions | Placeholder kept; branch silent |
| Stale | "Last seen previous session" | Rescan action |
| Not permitted (remote) | Add disabled: "Hosts edit structure" | Read-only with the reason |
| Unknown future fields | — | "Contains fields from a newer version (kept)" |

## Contract seams

Reads: catalog/capabilities, project patches and assets, graph items, parameters, diagnostics.
Writes: draft ops (add, replace, remove), live commands for live fields, and explicit scan requests.
Media asset timing is not defined here.
