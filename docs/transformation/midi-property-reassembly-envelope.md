# Property Exchange reassembly envelope (#838)

## Compatibility change

This is intentionally tighter **local receive policy**, not a claimed MIDI
standards requirement. M2-102/M2-103 normative text was unavailable. The original
#802 acceptance and #808 review supplied no interoperability rationale requiring
changed-envelope acceptance. No live Property Exchange consumer is activated.

Previously an assembly keyed by source MUID and request ID could accept changed
destination, device ID or CI format on a continuation, then return the combined
body labelled with chunk 1's header. That discrepancy was irrecoverable by the
content decoder. Such input now fails closed with
`envelopeChanged(expected:received:)`, carrying both complete `MIDICIHeader`
values. Senders relying on the former behavior are no longer accepted.

## Boundary and order

Every appended continuation must equal chunk 1's full header, using existing
`MIDICIHeader` value equality (device, format, source and destination). The check
is after kind validation and before later header data validation or body append.
Unknown count, sender abort, duplicate/order, changed count and changed kind keep
their earlier precedence. The existing drop mechanism removes only the affected
source/request key; no partial content is returned.

Keying is unchanged. A different source addresses a different request, not the
original assembly's envelope check. Single chunks still pass through without a
slot; factory ceilings, byte/chunk/open-request limits and discard APIs are
unchanged. Consistently noncanonical device IDs remain receive-lenient; individual
codec validation is not tightened.

Header equality is **not** transport/endpoint/group isolation, peer authentication,
capability authorization or inquiry/reply correlation. Earlier abort and refusal
paths remain keyed only by source/request and can disrupt an incorrectly shared
assembler. A future transport owner must partition instances appropriately. This
change prevents inconsistent successful content; it does not solve admission,
unsolicited messages, request-ID lifecycle, timers or resource policy. No output,
discovery, hardware, compression, production RT or UI changes are included.

## Evidence boundary

The canonical `MIDICIPropertyReassemblerTests` audited root owns `+Envelope.swift`.
Tests cover independent destination/device/format changes on intermediate and
final chunks, the exact formerly accepted combined change, refusal precedence,
drop/restart, unrelated request completion and source isolation. Consistent
two-/three-chunk assemblies cover both formats; noncanonical device fixtures pass
through the receive codec. Bounded seeded sequences check exact refusals and an
independent field-by-field successful-assembly invariant. Existing PXO helpers
exercise codec/reassembler/content round trips, including Mcoded7 group cuts.

A focused exact-source SwiftPM mirror is local algorithm evidence only. Any audit
trait stub does not exercise production-access receipts or prove Apple target
membership. Coordinator-owned project/audit registration must include the new
extension in the existing root (no new root). Exact-head hosted Apple, Lint and
Mac gates, Copilot and independent review remain required; local evidence does
not replace them. The work-session evidence records actual runs and fidelity.
