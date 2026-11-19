# Fixed carry planning (#837; #715 E5d prerequisite, #64)

`KernelCarryReadmission.init` now immediately uses `KernelCarryPlan`; the previous
array/dictionary/set/sort planner is removed. The plan uses one
`InlineArray<256, Entry>` and scalar accounting. Its private preparation helpers
are callable only inside the type; callers can only construct and read the result.
There is no concurrent replanning API.

**Only planning and fixed-result reads are allocation-free.** The readmission
object, its render slots/head/counters, and the rest of `KernelCycle` construction
remain control-side allocations. This does not enable overlap, remove the
takeover gap, or qualify any render deadline. Claim, retirement, flush watermark,
takeover release, acknowledgement and happens-before contracts are unchanged.
There is no production render/transport activation here.

The [inheritance-publication contract](transformation/kernel-cycle-inheritance-publication.md)
keeps unbound staging outside the ready-cycle/report interface and records the
remaining binding, publication and cancellation proof obligations (#843).
It is a documentation prerequisite, not implemented overlap machinery.

## Algorithm and accounting

1. Read the bounded carry through `event(at:)`, never its allocating `events`
   getter. Visit re-carried entries before own entries, preserving recorded index
   within each group. Remove nonfinite ramp targets before any key/overflow work.
2. Stable insertion by **original** frame produces exactly `(frame, re-carried
   before own, recorded index)` order; negative frames are not clamped.
3. Walk backwards, matching only later survivors. Controls use scope/channel/CC,
   programs scope/channel, ramps scope/parameter. These are **not** render's
   cross-scope ramp-target matching rules. CC 6, 38, 96–101 and 121 never coalesce.
   Each superseded event increments its survivor's weight; zero weight marks a
   removed entry.
4. Check every surviving ramp's completion before cutting capacity. Negative
   finite durations remain jumps. A superseded overflow is irrelevant; a
   surviving overflow beyond the capacity cut refuses the whole plan, with zero
   planned/cut/superseded counts, as before. Invalid/drop-at-record counts remain.
5. Compact survivors in place, keeping the earliest capacity entries (clamped to
   1...256); count later survivors by kind, not weight. The constructor consumes
   indexed entries into its existing render slots. Delivered/superseded weights
   feed the unchanged unresolved-loss accounting; cut/refused/re-carried state
   stays lost under the existing per-hop rules.

## Storage, work and copy exposure

Measured with Swift 6.4.2, arm64, macOS 27.2 SDK, in the focused SwiftPM mirror
(`-c release -Xswiftc -enable-testing`); Debug layout agrees:

| Value | Stride, bytes |
| --- | ---: |
| `KernelEvent` | 48 |
| `KernelCarryPlan.Entry` (event + weight) | 56 |
| Inline entries (256 × 56) | 14,336 |
| Complete plan (entries + metadata/padding) | 14,416 |
| Input `KernelRetirementCarry` | 12,320 |

One input plus one result is 26,736 bytes of value storage, **not** an upper bound
on generated stack use. `borrowing` the initializer argument does not guarantee
copy elimination. Inspection of the optimized object (`llvm-objdump -dr`) found:

- Specialized plan initializer: 26,752-byte local area + 96 saved-register bytes.
  The public initializer wrapper adds 14,416 + 32 bytes and a result copy.
- Coalescing helper: 32 saved-register bytes, no nested calls on the normal path.
- Indexed result accessor: 14,352 + 48 bytes; it copies the 14,336-byte inline
  buffer on a successful read. Input reads likewise copy 12,288 bytes in the
  optimized planner loop. Both remain bounded and heap-allocation-free.
- The probe's non-inlined consumer has 14,480 + 64 bytes; summing its active
  consumer → wrapper → specialized initializer → coalescing frames gives **55,872
  bytes**. The production readmission constructor has 28,768 + 64 bytes and calls
  the specialized initializer directly: **55,712 bytes** for that chain.
  These are observed application-frame sums, excluding upstream callers, caller
  input storage, runtime/stack-probe/memcpy frames and instrumentation—not a
  portable total stack guarantee. Debug/TSan/other toolchains can use more.
- At 256 input/output entries, whole-buffer indexed-read copies alone can move
  3,145,728 + 3,670,016 bytes, plus up to two 14,416-byte return copies on the
  public initializer path. Do not equate zero allocations with low copy cost.

For `n <= 256`, initialization writes 256 fillers; input visitation, reverse
survivor checking, compaction and result consumption each visit at most 256
entries (plus one terminating nil result read). Stable insertion performs at most
`n(n-1)/2 = 32,640` frame comparisons and shifts; coalescing performs at most
32,640 later-entry visits/key comparisons. At most 256 ramp overflow checks,
255 weight increments, and 256 cut/accounting operations occur. Each shift
moves one 56-byte entry; there is no recursion, hash collision behavior,
unbounded retry or dynamically growing collection. Compiler-generated fixed
buffer copies above are additional bounded work. **None of these bounds is a
deadline or native callback ownership/cardinality qualification.**

## Evidence and remaining gates

`RealtimeHandoffTests.CycleCarryPlanning` covers boundary sizes/capacities,
reverse ordering, ties, keys, data entry, invalid ramps, overflow precedence,
weights/cuts, and integrated replacement/two-hop emissions and per-hop loss.
Existing carry/readmission/retirement/gap tests remain unchanged.

The Release allocation probe uses the existing process-wide `allocations(_:)`
gate, a positive control, separate warm-up and preallocated sinks. It measures
the actual canonical planner plus result metadata/entry consumption, requires
**zero**, and does not include object/slot construction. The planner and its
small shared helpers have a source scan; existing render checks remain.
These probes cover the calling thread after warm-up, not `mmap`, other threads,
or all possible future compiler transformations.

Hosted kernel-mirror CI requires the new probe to **pass, not skip** in Release,
and the planner scan in Debug and Release, retaining all prior selectors and
three TSan runs. Local evidence is focused only. Full hosted mirror, exact-head
Apple/Lint/Mac observation and independent review remain required. #715, #64,
#190 and #48 remain open.
