# Complete SysEx forwarding in the reference translation driver (#852)

This is new software behavior at the test-constructed `UMPTranslationStreamDriver`:
`MIDI1Event.sysEx` → stream API → unchanged `UMPSysEx7Packet` packetizer → existing
ordered sink. It is not application MIDI-input adoption, a regression fix, or hardware
output. It contributes to #83 and #48; it does not reopen completed #80/#362.

## Local policy

- Payloads exclude F0/F7 framing. The inclusive 4,096-byte bound is a translator
  policy, not a normative MIDI limit or a dependency on a source-profile setting.
- Stopped drivers ignore calls before validation. Otherwise refusals are ordered:
  size (`sysExPayloadTooLarge(count:limit:)`), seven-bit packetizer validation
  (wrapped `translation` refusal), then existing admission-time validation.
  Refusals change neither stream state nor timer nor sink, even if a held deadline
  has passed.
- Successful admission sends the held CC6, if any, before every SysEx7 packet in
  one synchronous sink batch. Group and stream ID are preserved. The maximum batch
  is 683 packets plus one held voice. No fragments are retained or separately timed.
- As with System Common, a flush before the event-time deadline is uncounted.
  At or after it, exactly one idle flush is counted. The deadline clears, but bank,
  parameter selection and Data Entry MSB survive; a later CC38 uses that MSB.
  There is no implicit translator reset or payload interpretation.
- Existing event/admission-time separation remains: a late poll can advance the
  admission baseline without changing the event stamp used for flush accounting.
  Genuinely backward events remain refusals. Real-time and lifecycle behavior is
  unchanged. Complete-event forwarding cannot recover real-time byte positions
  within a previously received SysEx payload.

The existing root stream suite covers the new path with fake clocks/timers and
independent packet-word expectations. Exact-source selective SwiftPM Debug/optimized
Release checks are focused software evidence only, not native or iOS qualification.
Coordinator-owned registration and generated-project updates, native gates and
independent review remain separate. This does not complete #60, #83 or #48.

No receive-codec leniency, Property Exchange policy, whole-body-before-chunking
sender assumptions, endpoint/session correlation, authority, persistence, audio/UI,
cloud or hardware behavior changes here.
