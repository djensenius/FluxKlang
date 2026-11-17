# Refusal caller ownership prerequisite

Part of #768, #190 and #64; roadmap #48. Parent issues remain open.
K-RC1 adds a tested capability, **not counter coverage or application integration**.

## 1. Construction and lifetime bound

`Shared/Audio/Kernel/Memory/RefusalCaller.swift` owns one private, nongeneric,
process-global `FanInIdentityAllocator`. Its seed is `UInt64.max - Kmax`, where
`Kmax = 2^38 - 1`. Swift initializes that global once. The existing allocator
reserves by compare-exchange from `last` to `last + 1` only while `last < .max`.
Thus it grants exactly Kmax nonzero, distinct identities, including `.max`, then
refuses forever. Concurrent preparation cannot grant the same identity twice.
The retry belongs to control-side preparation, not token transfer.

`RefusalCaller.prepare()` is the only factory. The role's initializer and stored
fields are private. The token's initializer is fileprivate to the implementation,
and its stored identity is private, not a writable field exposed to extensions.
Neither same-module code nor `@testable` clients can forge either value, including
via an extension initializer. There is no injected mint, reset, refund, default
token, inspection API or test constructor. An independently created allocator
cannot construct a role. No identity is reclaimed when a role or token dies.

## 2. Exclusive slot protocol

Each Sendable role owns one `Atomic<UInt64>` slot, initially its identity.
Zero means unavailable. A token contains only a scalar identity, not a reference
whose last release could destroy a role on the hot path.

| Operation | Transition | Work |
|---|---|---|
| `take()` succeeds | identity → zero; creates one token | one acquiring exchange |
| `take()` fails | zero → zero; no token | one acquiring exchange |
| matching consuming `put` | zero → identity; destroys the capability value | identity check, one releasing store |
| foreign consuming `put` | destination unchanged, available or held | identity check, no store |
| drop token | source stays zero forever | no recovery |
| drop role | identity budget stays spent | no refund |

Inductively there is at most one token per role: only an exchange reading the
identity creates one, and only consuming that same token can restore the slot.
Atomic modification order gives at most one successful taker of a full slot.
Foreign returns cannot overwrite a held destination or duplicate an available
destination's token. They consume the foreign token, permanently stranding its
source. A role lost while its token is held cannot be replaced with that identity.

Tokens are noncopyable and explicitly non-Sendable. Operations using them must
borrow with exclusive `inout`; ownership/exclusivity disallows copying, reuse
after consume, overlapping borrows, escaping an active borrow and concurrent
sharing. This does **not** claim that Swift rejects every exclusive `sending`
transfer: compiler-permitted transfers with their own HB edge are compatible.
The supported cross-worker protocol is return to, then take from, the slot.
Unsafe casts, unchecked Sendable boxes around tokens, unsafe pointers to tokens,
and disabling exclusivity are outside this model.

## 3. Happens-before argument

All work while holding a token is sequenced before its matching releasing store.
The successful acquiring exchange that reads that identity synchronizes with
that store. Prior holder work therefore happens before successor holder work,
including on a different worker. Failed exchanges write zero, so a successful
exchange must read the available identity rather than a failed exchange's zero.
No retry, mutex, allocation, mint or destructor is part of production take/put.
This is a Swift atomic/ownership reference-model argument, not qualification of
target atomic lowering or platform callback scheduling.

The canonical transfer test prestarts two owned pthreads behind a start barrier.
They alternate using plain `turn`, `value` and `lastWorker` fields only under the
token. Each worker checks the predecessor's value **before** any join; all 1,999
cross-worker transitions must actually occur. There is no post-write auxiliary
mutex, release/acquire flag or join ordering those reads. Cancellation and
diagnostic atomics are relaxed. Deadlines bound worker loops; every created
worker is joined, including failed setup and cancellation paths. Final joins
protect only the test thread's result inspection, not the tested worker reads.
TSan is schedule-dependent evidence, not a weak-memory proof; removing ordering
need not fail deterministically.

## 4. What K-RC1 does not establish

No counter-writing API takes this token yet. `FanInRefusalCounter.bump`,
`FanInHandoff.claimProducer`, `tryPush`, `releaseProducer`,
`ProducerAdmission.push` and `KernelAdmissionRefusals.record` remain unchanged.
Their existing conditional saturation contracts remain requirements, not
enforced premises. Fault-chain tokens do not cover these separate counters.

K-RC2 must require one exclusive borrowed token throughout every such operation
and migrate all callers without tokenless overloads. Only then can every
counter's lifetime caller set (including retained tables and foreign aggregates)
be shown a subset of this one global mint. With ordered nonoverlapping calls,
each role can admit at most one stale addition past saturation; for
`cap = 2^63 - 1`, `raw <= max(initial, cap + Kmax) < 2^64`.
This is the intended future composition, **not a proof of current counter coverage**.

An unavailable role means failure to acquire a capability, not an ordinary event
refusal and not an uncounted `.notOwner` event result. K-RC1 adds no busy-drop
wrapper. Application callback entry ownership, recovery, actual integration,
platform progress and full #190/#64 qualification are separate obligations.
`ProducerToken` and existing fault-chain/fallback contracts are unchanged.

## 5. Evidence boundaries

Canonical lifecycle tests cover repeated exclusive take/return, simultaneous
takers, both foreign-return destination states, source stranding and dropped
tokens/roles. Compiler fixtures separately test construction and ownership
rejections with compiling positive controls; the Sendable helper accepts
`~Copyable` so it cannot fail merely on an implicit Copyable requirement.

Lifetime exhaustion is impractical to enumerate at the production bound.
A separately labelled, fresh-process **modified mirror** changes only the
production lifetime budget constant to a small N, retaining the factory and
seed expression. It checks exact N grants, concurrent reservations, persistent
exhaustion and no refunds after dropping roles/tokens. That evidence is not a
byte-identical canonical run. All canonical copies must be restored and compared
before final clean Debug/Release validation. Mutation and compiler recipes and
actual results accompany the K-RC1 review evidence.

Related contracts: [fault-chain tokens](fault-latch-chain-tokens.md),
[raise-site inventory](fault-latch-raise-sites.md),
[platform callback evidence](fault-latch-platform-callbacks.md).
