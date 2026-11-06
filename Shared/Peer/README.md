# Peer wire (provisional v1)

Pure framing and capability-hello negotiation for device-to-device control
(#93, child of #92). There is no listener, browser, connection, TLS or Bonjour
code here. A transport conforms to `PeerByteTransport` and is tested with
in-memory doubles. Pairing and trust belong to #94, and command sync and
authority to #95/#62. A negotiated control frame is only a *candidate* and never
authorizes anything by itself.

This layout is accepted as **provisional v1**. The golden-bytes test in
`FluxKlangTests/PeerTransportTests.swift` pins it.

## Frame

All integers are unsigned and big-endian. Each frame is a fixed 24-byte header
followed by `length` payload bytes.

| Offset | Size | Field | Rule |
|---:|---:|---|---|
| 0 | 4 | magic | `46 4B 50 57` ("FKPW"); checked as soon as 4 bytes are buffered |
| 4 | 2 | layout version | `1` only |
| 6 | 1 | kind | `1` hello, `2` helloAccept, `3` helloReject, `4` control, `5` close |
| 7 | 1 | flags | must be `0` |
| 8 | 8 | connection epoch | `0` = none; otherwise ≤ 2^53 − 1 |
| 16 | 4 | sequence | per direction, starts at `1`, +1 per frame, no wrap |
| 20 | 4 | payload length | ≤ the negotiated limit |

Limits:
- The maximum payload defaults to 16 384 bytes. It is configurable between
  1 024 and 1 048 576, so a frame is at most 24 + that maximum.
- The decoder never buffers more than one maximum frame.
- Queued frames drain FIFO through a head index, which is linear; no timing
  test covers that.

Any of the following latches the decoder failed: a bad magic, unknown version,
kind or flags, an invalid epoch, a sequence gap or repeat, an oversized length,
or truncation at end of stream. Frames completed before the defect are still
delivered and the error follows, so the result does not depend on how the bytes
were chunked. Nothing after a failure is ever delivered. Idle and read timeouts
are left to a later transport slice.

## Payloads

- **hello** (epoch must be 0): lower version `u16`, upper version `u16`, the
  offered capability set, then a required mask `u16`. Bit *i* of the mask
  selects offered token *i*.
- **capability set**: count `u8` (≤ 16), then for each token a length `u8` and
  its bytes. Tokens are strictly ascending, so the encoding is canonical.
- **helloAccept** (carries the assigned epoch): version `u16`, host epoch `u64`,
  connection epoch `u64`, then the agreed capability set.
- **helloReject** (epoch must be 0): reason `u8`. The reasons are
  `1` incompatibleVersion, `2` missingRequiredCapability, `3` malformedHello,
  `4` ineligible and `5` denied.
- **control**: opaque bytes, at the negotiated connection epoch.
- **close**: empty, at the negotiated connection epoch.

### Capability tokens

A token is 1–32 ASCII bytes from `[a-z0-9.-]`. It must start with a letter,
end with a letter or digit, and must not contain two separators (`.` or `-`) in
a row.

The initial vocabulary is frozen as exactly `control`, `status` and `telemetry`
(`PeerCapability.initialVocabulary`). Unknown well-formed tokens are carried but
never agreed unless both sides offer them. A required token that the peer lacks
refuses the hello.

## Negotiation

1. The initiator sends a hello. The acceptor picks the highest common version
   and intersects the offered capabilities, then replies with an accept that
   assigns the connection epoch, or with a reject.
2. Control frames are admitted, and `control(_:)` can send, only when the agreed
   capabilities contain `control`. Otherwise the session refuses with
   `missingRequiredCapability`, or `control(_:)` throws `controlNotNegotiated`.
3. Close is **one-way with no acknowledgement**. After a close, current-epoch
   control and close frames already in flight are dropped silently, and any
   other frame refuses.
4. Refusal is terminal. `negotiate` on a refused or closed session returns
   without reading the transport.

`AcceptorContext` is computed by the host before the hello and is never taken
from peer bytes:
- `connectionEpoch` must be fresh for every connection. The host issues it with
  `Generation.next()`; the epoch ledger is owned by #95/#97.
- `availability` reports `ineligible` from host platform state (#57, e.g. Local
  Network) and `denied` from trust/pairing policy (#94).

## Discovery

The Bonjour service type is deferred. `_fluxklang._tcp` is a working name only
and is not advertised or browsed by anything in this lane.

## Reconnect (`Reliability/`, #97 R1)

Pure values only; no sockets, timers or Bonjour.
- `PeerConnectionEpochIssuer` (host) issues each peer's connection epoch from one
  host-wide `Generation.next()` counter, so an epoch is never reused. Currency is
  equality with the live epoch only. Live peers are bounded (64 by default) and a
  full issuer refuses instead of evicting.
- `PeerOutboundQueue` (remote) holds up to 256 intents of the current session,
  queued and sent-but-unanswered together, in strict order with no coalescing. An
  intent of any other epoch is refused, and a full queue refuses instead of evicting.
- `PeerReconnectState` moves connected → synced → resyncing → synced, with
  disconnected from any phase. It reads the session from the receiver it observes.
  Input and sending are enabled only when synced and resumed. After an in-session
  resync, held intents wait for an explicit `resume(_:)` from the sync layer; nothing
  flushes on its own. A reconnect is allowed only after `connectionLost(_:)` and only
  to the same host, whose (host generation, connection generation) pair must
  strictly increase over the current session; another host is adopted only through
  the explicit `changeHost(to:)`, which restarts that order. Adoption drops the
  whole queue, never replays it, and returns one `PeerDiscardReport`: never-sent intents are
  *discarded*, and sent intents without a result are *outcome unknown*. Events of
  an old session are ignored and reported.
- Sends are `PeerCommandEnvelope`s numbered from 1 per session. A
  `PeerCommandResult` is accepted only when its session, command ID and envelope
  sequence all match an awaiting send; a delayed duplicate for an earlier send of a
  reused ID is `sequenceMismatch` and changes nothing. An ID is a `duplicate` only
  while queued or awaiting; once answered (e.g. a transient refusal) it may be
  enqueued again and is sent under a new sequence. `PeerCommandResult` names no
  session and sequences restart at 1 per session, so the transport must bind each
  result to the connection it arrived on and pass that session to `acknowledge`.
  When a session's sequences run out, enqueue and send refuse with
  `sequenceExhausted` and input is disabled until a reconnect.
- Every adoption and every current-session resync request (even while already
  resyncing) starts a new `PeerResyncLatch` (equality only), so earlier stamps go
  stale. Sync events and receiver phases are stamped with `stamp(_:)` when
  produced; only the snapshot answering the current latch, while the receiver is
  still synced, clears it. Every observed current `.resyncRequired` phase (a poll
  included) starts a new latch, so an `.applied` stamped before it is ignored;
  recovery completes on the next `.synced` read or `.applied` stamped after the
  last observed request. Exhausted generations fail closed (`latchExhausted`,
  input off, every signal ignored) until a reconnect. A late signal of an earlier latch or session (event,
  receiver phase, `resume(_:)`, `connectionLost(_:)`, backoff tick) is a typed
  ignore or refusal and changes nothing.
- `PeerReconnectBackoff` is pure math: 250 ms × 2^attempt, capped at 30 s, with
  equal jitter from a caller-supplied unit in [0, 1). `PeerReconnectAttempts`
  counts attempts (saturating at 32) and is reset by a successful sync.
