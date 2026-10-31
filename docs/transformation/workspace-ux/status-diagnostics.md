# Status and Diagnostics

Owner: #99 (status projection and placement). Inputs come from #62 (lifecycle, lease, safety), #65
(devices), #66 (telemetry), #94/#97 (peers) and #118/#119 (assistant explanations). Examples:
`session.json`, `devices.json`, `transport.json`.

## One status projection

Every surface reads the same projection, so Wiring, Perform, Spatial and a phone host never disagree.

```text
+----------------------------------------------------------------------------------------------------+
| Engine: Running (Host A) | Devices: 1 missing, 1 stale | Clock: 48 kHz nominal, actual Unavailable |
| Peers: Remote C connected (epoch 4) | Draft: 1 awaiting review | [Safe Mute] [PANIC]               |
+----------------------------------------------------------------------------------------------------+
```

On wide windows it is one row; on a phone it wraps to a summary button plus Safety. Each segment is a
button that opens its detail list. Safety buttons are never collapsed into a menu.

VoiceOver: the strip is a container named "Status". Each segment has a full-sentence label
("Devices: Interface B missing, Controller A stale"). New errors such as Lost/Muted are announced
once, with high priority. Routine changes are announced politely and throttled, and an unchanged state is never re-announced.

## Lifecycle (engine lease, #62)

| State | Strip text | Editing | Live changes | Panic / Safe Mute |
|---|---|---|---|---|
| Stopped | "Engine stopped" | Drafts | Stored, not rendered | Available (no-op is announced) |
| Preparing | "Preparing rev 43..." | Drafts | Applied to the running set, if any | Available |
| Running | "Running (Host A)" | Drafts | Applied | Available |
| Degraded | "Running: Space Lost/Muted" | Drafts | Applied where routed | Available |
| Recovering | "Recovering engine..." | Drafts | Rejected with reason | Available; outputs muted |
| Lease held by another document | "Engine in use by Example Set" | Edit and prepare only | Not rendered | Available (acts on the running set) |
| Background (iOS) | "Running in background" or "Suspended" | — | Per policy | Available on return |

The lease `lse.host-a` covers `win.wiring` and `win.perform`. A second window never starts a second engine.

## OS permissions (asked in context, never at launch)

| Permission | Example state | Strip/effect | Manual alternative |
|---|---|---|---|
| Microphone | Host A granted | none | — |
| Local Network | Host A granted; Host B (phone) denied | Host B: "Peer control unavailable" | Local use unaffected; "Open Settings" |
| Bluetooth MIDI | Host B notDetermined | Nothing until a Bluetooth controller is added | Wired or on-screen controls |

## Peers

| State | Text | Effect |
|---|---|---|
| None | "No peers" | — |
| Connected | "Remote C connected (epoch 4)" | Scoped live control only |
| Resyncing | "Remote C resyncing" | Remote input disabled until a fresh snapshot |
| Stale epoch rejected | "Remote C: 2 stale commands discarded" | Shown once on the host and on the remote |
| Unavailable | "Local Network denied" | Host unaffected |

## Assistant eligibility (#118/#119)

| State | Text | Manual paths |
|---|---|---|
| Eligible | "Explain" buttons shown | Unaffected |
| Not eligible (device/model) | "Assistant unavailable on this device" | Unaffected |
| Off (user setting) | No assistant buttons | Unaffected |
| Busy | "Explaining..." with Cancel | Unaffected |

There is no cloud fallback. The assistant reads diagnostics (`diagnostics.read`) and proposes drafts (`draft.propose`). It never applies a change.

## Diagnostics list

```text
+-- Needs attention (4) ------------------------------------------------------+
| ! Error   Interface B is missing. Space outputs are muted;                  |
|           survivors are not boosted.                                        |
|           [Choose another device...] [Keep muted]               [Explain]   |
| ! Warn    Tape Echo is not installed. Its branch is silent; not bypassed.   |
|           [Locate plugin...] [Replace node...] [Keep placeholder] [Explain] |
| ! Warn    Controller A was last seen in a previous session.                 |
|           [Rescan] [Use on-screen controls]                     [Explain]   |
| i Info    Cue has no device route on this host.                             |
|           [Map Cue to outputs...]                               [Explain]   |
+-----------------------------------------------------------------------------+
```

- Manual actions come first and work without the assistant.
- **Explain** is read-only text grounded in the snapshot IDs (for example `dgn.space-lost` → `rte.space`).
- If the assistant suggests a structural fix, it appears as "Review proposed draft". That opens the
  normal review sheet ([draft-active-transactions.md](draft-active-transactions.md)), with an assistant provenance badge.
- Severity is text plus a glyph, never colour alone. Rows are sorted by severity, then by time first seen.

## Contract seams

Reads: lifecycle, lease, devices, clocks (nominal vs measured), peers, telemetry, diagnostics,
assistant eligibility. Writes: none, apart from safety commands, explicit rescans and opening a review.
