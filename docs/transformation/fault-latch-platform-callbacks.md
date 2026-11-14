# FaultLatch raise contexts: platform callback evidence

| Field | Value |
|---|---|
| Issue | #190 (slice FLP2); roadmap #48, parent #64 |
| Status | Evidence only. Nothing in this document is a proof. #190 remains open |
| Source baseline | main at `3e27e228`. Platform sources: Xcode 27.2 SDK headers (macOS 27.2, iOS 27.2), plus Apple DocC and WWDC pages, fetched 2026-11-14 |
| Scope | Answers questions 1 to 5 of [FLP1](fault-latch-raise-sites.md) section 7 for audio render, CoreMIDI, and Network/Dispatch callbacks |

## 1. Status and scope

This document is documentation only. It changes no code, adds no caller and
weakens no check. No build, test, hosted run, audio, MIDI, OSC, WING, service or
hardware was used. It records what Apple's own sources say about the callbacks a
future `FaultLatch` raiser would run in, so that the caller proofs that
[`fault-latch-raise-sites.md`](fault-latch-raise-sites.md) (FLP1) section 8 asks
for can start from cited platform text instead of from assumption.

The contract being served is `FaultLatch`'s "Raise-context contract"
(`FaultLatch.swift:123` to `:130`, summarised in FLP1 section 2): at most
K < 2^39 logical chains over the latch's whole life, each chain non-reentrant,
each completed `raise` happening before the chain's next one, and a chain moving
between threads only through a real happens-before (HB) handoff. FLP1 section 7
asks five questions about the platform callbacks that would carry those chains.
Sections 2 to 4 record the evidence, and section 6 answers the questions.

What counts as authoritative here:

- Doc comments in the Apple SDK headers shipped with Xcode 27.2: the macOS 27.2
  SDK, and the iOS 27.2 SDK for iOS-only text. Cited as `Framework/Header.h:line`
  relative to the framework's `Headers` directory, or as `dispatch/...` and
  `os/...` relative to the SDK's `usr/include`. Line numbers hold for these SDKs
  only.
- Apple DocC reference pages, cited by full URL.
- WWDC session transcripts, cited by URL and timestamp (mm:ss).

Classification legend, used in every table:

- **G**: an explicitly documented guarantee.
- **W**: a documented warning or non-guarantee.
- **N**: not documented in the sources read. Section 7 lists what was not read.
  N records an absence of evidence. It is not evidence of the opposite behaviour.

How to read the tables:

- Quotes are short excerpts copied from the cited source, with header line breaks
  joined. Nothing about Apple's behaviour is asserted beyond quoted text. The
  "Finding" column paraphrases only the quote and its surrounding doc comment, or
  records that nothing was found.
- Observed behaviour is not evidence. As FLP1 section 7 says, a finite run on a
  target can look for a counterexample, but it is not evidence of serialization,
  of thread stability or of a chain bound. No such run was used.
- Section 5 lists design implications. They are not platform facts.

## 2. Audio render

Covers AUv3 `renderBlock` and `internalRenderBlock`, AUv2 `AudioUnitRender` and
`AURenderCallback`, `AVAudioSourceNode`, `AVAudioSinkNode` and `AVAudioEngine`
manual rendering. FLP1 section 7 found no production render callback.

| # | Question | Finding | Class | Source | Quote |
|---|---|---|---|---|---|
| A1 | Can one AUv3 render block be called concurrently with itself? | No statement either way. The only sequencing text is a buffer-lifetime rule about the "next" render call | N | `AudioToolbox/AUAudioUnit.h:132-133`; `AudioToolbox/AUAudioUnit.h:479-492`; <https://developer.apple.com/documentation/audiotoolbox/auaudiounit/renderblock> | "until it is next called to render, or deallocateRenderResources is called" |
| A1b | AUv2 `AudioUnitRender` and `AURenderCallback`: concurrent with itself? | Render against render is not addressed. The host must keep `AudioUnitReset` and `AudioUnitRender` from running concurrently. Timestamps are expected to advance from the previous call. `AURenderCallback` has no threading text | Render/render N; reset/render W (host duty) | `AudioToolbox/AUComponent.h:1627-1628`; `AudioToolbox/AUComponent.h:1546-1552`; `AudioToolbox/AUComponent.h:1055-1063` | "host's responsibility to synchronize calls to AudioUnitReset() against calls to AudioUnitRender() so that they are not being called concurrently"; "incrementing sequentially from its previous call" |
| A1c | `AVAudioSourceNode` and `AVAudioSinkNode` blocks | Source block: realtime or non-realtime threads, depending on the engine's mode. Sink block: the realtime thread. For both, thread-safety is the client's job. Self-concurrency is not addressed. The realtime-safe block variants are unavailable from Swift | W; self-concurrency N | `AVFAudio/AVAudioSourceNode.h:69-70`; `AVFAudio/AVAudioSourceNode.h:97-98`; `AVFAudio/AVAudioSourceNode.h:88`; `AVFAudio/AVAudioSourceNode.h:116`; `AVFAudio/AVAudioSinkNode.h:73-74`; `AVFAudio/AVAudioSinkNode.h:87`; <https://developer.apple.com/documentation/avfaudio/avaudiosourcenode/init(renderblock:)> | "The block can be called on realtime or non-realtime threads"; "it is the client's responsibility to handle it in a thread-safe manner"; "The block will be called on the realtime thread" |
| A1d | `AVAudioEngineManualRenderingBlock` | Calling into the engine from a non-realtime thread can make the block return `AVAudioEngineManualRenderingStatusCannotDoInCurrentContext`. Synchronizing realtime and non-realtime threads is left to the client. Self-concurrency is not addressed | W; self-concurrency N | `AVFAudio/AVAudioEngine.h:126-136`; `AVFAudio/AVAudioEngine.h:721-732`; <https://developer.apple.com/documentation/avfaudio/avaudioengine/manualrenderingblock> | "the client could implement their own synchronization between their realtime and non-realtime threads" |
| A2 | Can successive calls come from different threads or contexts? | For AUs, Apple says the host calls the render block from an unknown thread context and that the workgroup can change between calls. The OS calls a context observer before a render request in a different workgroup. That is about context, not thread identity. Nothing equivalent is documented for source or sink nodes or manual rendering | W (AU); N (others) | <https://developer.apple.com/videos/play/wwdc2020/10224/> at 7:29-7:39 and 8:18-8:19; `AudioToolbox/AudioUnitProperties.h:1389-1391`; `AudioToolbox/AUAudioUnitImplementation.h:224-230` | "It's being called by the host in some unknown thread context."; "the workgroup may change from one render call to the next"; "immediately before any render request which is in a context (workgroup) differing from the previous one" |
| A3a | Does the render thread change across stop and start, a format change, or a resource reallocation? | The lifecycle is documented, and the rule against changing major state while initialized is itself hedged ("In common practice"). Thread identity across the lifecycle is not documented | N | `AudioToolbox/AUAudioUnit.h:426-444`; `AudioToolbox/AUComponent.h:1199-1237`; `AudioToolbox/AUComponent.h:32-50` | "Hosts must call this before beginning to render"; "In common practice, major state of an audio unit (such as its I/O formats, memory allocations) cannot be changed while an audio unit is initialized" |
| A3b | Route and configuration changes | On a hardware channel-count or sample-rate change, the engine stops itself and posts a notification from an internal dispatch queue. Nothing is said about the render thread afterwards. An I/O unit's workgroup changes when its device assignment changes | Notification queue W; render thread N; workgroup change G | `AVFAudio/AVAudioEngine.h:1050-1060`; `AudioToolbox/AudioWorkInterval.h:23-24` | "the engine stops itself"; "the callback happens on an internal dispatch queue"; "If an I/O unit's device assignment changes, as a side effect, its workgroup will also change." |
| A3c | Do input and output run on different threads? | On iOS, non-aggregated audio I/O uses separate threads for input and output. The header gives this in a paragraph about apps that use `AVCaptureSession` on devices that support Live Photos, which get non-aggregated I/O unless they opt out. It does not say how common non-aggregated I/O is otherwise | G (iOS, when I/O is not aggregated) | `AVFAudio/AVAudioSessionTypes.h:725-727` (context); `AVFAudio/AVAudioSessionTypes.h:727-728` (iOS 27.2 SDK) | "separate threads will be used to service audio I/O for input and output directions" |
| A4 | Workgroups (`os_workgroup_t`, `osWorkgroup`, `kAudioDevicePropertyIOThreadOSWorkgroup`) | A workgroup is a set of cooperating threads, used for scheduling. Nothing implies one thread or serialization. The device workgroup lives as long as the device. These APIs are unavailable from Swift | N (identity, serialization) | `os/workgroup_object.h:38-47`; `CoreAudio/AudioHardware.h:987-990`; `AudioToolbox/AudioWorkInterval.h:17-18`; `AudioToolbox/AudioWorkInterval.h:51-53`; `AudioToolbox/AUAudioUnit.h:1319-1328` | "tracks a collection of threads all working cooperatively"; "the Swift runtime is unsafe for use on realtime threads" |
| A4b | AU host blocks (`musicalContextBlock`, `transportStateBlock`, `scheduleParameterBlock`) | The musical-context and transport blocks may be called at the start of each render cycle and should be cached in realtime-safe storage. `scheduleParameterBlock` may be called from any thread. These are calls between host and AU; no ordering for the render block is documented | G (`scheduleParameterBlock`); N otherwise | `AudioToolbox/AUAudioUnit.h:236-238`; `AudioToolbox/AUAudioUnit.h:295-297`; `AudioToolbox/AUAudioUnit.h:501-502`; `AudioToolbox/AUAudioUnit.h:1062-1082` | "may be called at the beginning of each render cycle"; "safe to call from any thread context, including realtime audio render threads" |
| A5 | Platform HB edge between successive render calls | None stated. A1's "until it is next called" is a buffer-lifetime rule, not an ordering edge | N | Sources in A1 to A4 | - |
| A6 | Finite bound on distinct threads or contexts; restart counting | None stated. Of the audio headers listed in section 7, only `AudioToolbox/AUComponent.h:1628` matches `reentr` or `concurren`, and it is the reset/render rule in A1b | N | - | - |

Reading: no audio source read states that a render callback is non-reentrant
with itself, runs on one thread, or has an HB edge to its next call. For AU hosts,
Apple documents the opposite direction: the render context may change from one
call to the next (A2). The Swift-callable source and sink node blocks leave
thread-safety to the client (A1c). Incidentally, `AVFAudio/AVAudioNode.h:30` warns
that a tap block "may be invoked on a thread other than the main thread".

## 3. CoreMIDI

Covers input ports, virtual destinations, connections and client notifications.

| # | Question | Finding | Class | Source | Quote |
|---|---|---|---|---|---|
| M1 | Can one receive block be called concurrently with itself? | No statement either way. The wording is singular: CoreMIDI creates a high-priority receive thread and calls the block from it. The legacy `MIDIReadProc` and `MIDIReadBlock` use the same wording | N (suggestive wording, not a guarantee) | `CoreMIDI/MIDIServices.h:350-358`; `CoreMIDI/MIDIServices.h:371-379`; `CoreMIDI/MIDIServices.h:397-405`; <https://developer.apple.com/documentation/coremidi/midireceiveblock> | "will create a high-priority receive thread on your client's behalf, and from that thread, your MIDIReceiveBlock will be called" |
| M2 | Does it run on one thread for the port's life? | Each input-port creator says the block runs on a separate CoreMIDI-owned thread. That does not say the thread stays the same over time | N | `CoreMIDI/MIDIServices.h:1509`; `CoreMIDI/MIDIServices.h:1542`; `CoreMIDI/MIDIServices.h:1575`; <https://developer.apple.com/documentation/coremidi/midiinputportcreatewithprotocol(_:_:_:_:_:)> | "readBlock will be called on a separate high-priority thread owned by CoreMIDI." |
| M3a | `MIDIPortConnectSource`, `MIDIPortDisconnectSource`, `MIDIPortDispose`, `MIDIClientDispose` | Nothing about threads, about callbacks in flight when these return, or about callbacks after a disconnect or dispose. The `MIDIPortDispose` doc says a client's ports are disposed when the client is. The `MIDIClientDispose` doc covers only the client's own lifecycle | N | `CoreMIDI/MIDIServices.h:1631-1645` (connect); `CoreMIDI/MIDIServices.h:1652-1664` (disconnect); `CoreMIDI/MIDIServices.h:1623-1625` (`MIDIPortDispose`, quoted); `CoreMIDI/MIDIServices.h:1461-1477` (`MIDIClientDispose`); <https://developer.apple.com/documentation/coremidi/midiportconnectsource(_:_:_:)>; <https://developer.apple.com/documentation/coremidi/midiportdisconnectsource(_:_:)> | "the client's ports are automatically disposed at that time" |
| M3b | Notifications of setup changes | `MIDINotifyBlock` runs on an arbitrary thread chosen by the implementation, and the block owns its thread-safety. The legacy `MIDINotifyProc` runs on the run loop where `MIDIClientCreate` was first called. No ordering against receive callbacks is stated | W (block); G (legacy proc's run loop); N (order against receive) | `CoreMIDI/MIDIServices.h:335-341`; `CoreMIDI/MIDIServices.h:1450-1452`; `CoreMIDI/MIDIServices.h:320-325`; <https://developer.apple.com/documentation/coremidi/midinotifyblock>; <https://developer.apple.com/documentation/coremidi/midiclientcreatewithblock(_:_:_:)> | "called on an arbitrary thread chosen by the implementation; thread-safety is the responsibility of the block"; "called on the runloop (thread) on which MIDIClientCreate was first called" |
| M4 | SysEx across callbacks (MIDI 1.0 packets, UMP SysEx7 and SysEx8) | A packet may carry part of a SysEx message. UMP SysEx has Complete, Start, Continue and End statuses. Large SysEx must be sent in smaller event lists. No receive-side text says whether one message's parts stay within one callback or span several | G (partial SysEx exists in the data model); N (callback spanning) | `CoreMIDI/MIDIServices.h:469-471`; `CoreMIDI/MIDIServices.h:552-554`; `CoreMIDI/MIDIServices.h:2642-2643`; `CoreMIDI/MIDIServices.h:2731-2732`; `CoreMIDI/MIDIServices.h:2649-2650`; `CoreMIDI/MIDIMessages.h:98-103` | "a packet may only contain a single message, or portion of one"; "May be a single MIDI event, or a partial sys-ex event"; "Large sysex messages must be sent in smaller event lists." |
| M5 | Do all sources on one port share one callback? | One port takes any number of sources into one block, tagged by `srcConnRefCon`. Whether delivery from different sources is serialized is not stated. The deprecated `MIDIPacketList` is documented as coming from one endpoint; `MIDIEventList` has no such sentence | N (suggestive) | `CoreMIDI/MIDIServices.h:1506-1507`; `CoreMIDI/MIDIServices.h:362-364`; `CoreMIDI/MIDIServices.h:572-575` | "establish an input connection from any number of sources to your port" |
| M6 | Virtual destination (`MIDIDestinationCreateWithProtocol`) | Same `MIDIReceiveBlock` type. The header says only when the block is called. The DocC page repeats the separate-thread wording. Self-concurrency is not addressed | N (as M1 and M2) | `CoreMIDI/MIDIServices.h:1895-1916`; <https://developer.apple.com/documentation/coremidi/mididestinationcreatewithprotocol(_:_:_:_:_:)> | "gets called when clients send MIDI to your virtual destination"; DocC: "The system calls the read block on a separate high-priority thread owned by Core MIDI." |
| M7 | Platform HB edge between successive receive callbacks | None stated | N | - | - |
| M8 | Finite bound on threads or contexts; restart counting | None stated. A search of `MIDIServices.h` for `reentr`, `concurren`, `serial` and `queue` finds only unrelated serial-port text. CoreMIDI's DocC article list has no threading article | N | - | - |

Reading: the receive wording describes one CoreMIDI-owned thread, but no source
read promises non-reentrancy, a stable thread, or an HB edge between receive
callbacks (M1, M2, M7). The existing `Shared/MIDI/CoreMIDIInput.swift:50` uses
`MIDIInputPortCreateWithBlock`, the legacy `MIDIReadBlock` path
(`CoreMIDI/MIDIServices.h:1554-1576`). M1, M2 and M5 apply to it unchanged, and it
feeds no kernel type (FLP1 section 7).

`SysExAssembler.swift:28` to `:30` requires `accept` to run in one context at a
time on "the MIDI receive path", and leaves #81 to verify or serialise that. The
evidence above does not establish it. Event lists for a port reach that port's
one receive block (M1, M5), but the platform does not say that block is one
context, and one block receives every connected source. Whether one SysEx7
message's chunks arrive in one callback or in several is not documented (M4).

## 4. Network and Dispatch

Covers `NWConnection` and `NWListener` (`nw_connection_*` and `nw_listener_*` in
the C headers) and `DispatchSource` read sources: the Apple APIs a future OSC or
WING receive path could use.

| # | Question | Finding | Class | Source | Quote |
|---|---|---|---|---|---|
| N1 | On which queue do a connection's handlers run (state updates, receive completions)? | On the queue the client sets before start. The header wording is generic ("blocks for events"); receive completions are not named separately. The listener has the same rule | G (generic wording) | `Network/connection.h:219-223`; `Network/listener.h:162-167`; <https://developer.apple.com/documentation/network/nwconnection/start(queue:)>; <https://developer.apple.com/documentation/network/nwlistener/start(queue:)> | "Sets the client callback queue, on which blocks for events will be scheduled. This must be done before calling nw_connection_start()." |
| N2 | Are handlers for one connection serialized? | The header names no required queue type. Serialization is guaranteed with a serial queue: Dispatch invokes one block at a time, in FIFO order. A concurrent queue may run regular work items concurrently and in any order, and whether Network serializes its own callbacks on a concurrent queue is not documented | G for a serial queue (Dispatch); N for Network on a concurrent queue | `dispatch/queue.h:38-42`; `dispatch/queue.h:128-135`; `dispatch/queue.h:177-187`; <https://developer.apple.com/documentation/dispatch/dispatchqueue>; <https://developer.apple.com/documentation/dispatch/dispatchqueue/attributes/concurrent> | "it is guaranteed that only one block submitted to the FIFO dispatch queue will be invoked at a time"; "Regular workitems can be invoked concurrently for the same concurrent queue, in any order" |
| N2b | Several outstanding receives on one connection | Each receive's completion runs exactly once. The order among several outstanding receives is not stated | G (exactly once); N (order) | `Network/connection.h:381-385`; `Network/connection.h:416-418`; <https://developer.apple.com/documentation/network/nwconnection/receive(minimumincompletelength:maximumlength:completion:)> | "The completion handler will be invoked exactly once for each call" |
| N3 | Thread identity and HB on a queue | No thread is guaranteed for any block. The only ordering language is an analogy between a serial queue and a mutex. No explicit happens-before or memory-model sentence was found in `dispatch/queue.h`, `dispatch/source.h`, `dispatch/base.h` or `dispatch/dispatch.h` | Thread identity W; explicit HB N | `dispatch/queue.h:40-41`; `dispatch/queue.h:189-191` | "No guarantee is made regarding which thread a block will be invoked on"; "if a serial queue is equivalent to a mutex in the Dispatch world" |
| N4a | Reconnection of the same connection | A waiting connection "will normally re-attempt on network changes", which is hedged. `restart` forces a waiting connection to retry, even without a network change, and is ignored in any other state. Both act on the same connection object. Thread identity is still not guaranteed (N3) | W (automatic retry); G (`restart` mechanics) | `Network/connection.h:257-258` (automatic retry); `Network/connection.h:258-262` (`restart`); <https://developer.apple.com/documentation/network/nwconnection/restart()> | "force a connection in the waiting state to retry connection establishment even without a network change"; "Calls to restart for connections that are not in the waiting state will be ignored." |
| N4b | Cancel and teardown | Outstanding sends and receives get errors before the cancelled state, and the cancelled state is delivered last | G | `Network/connection.h:137-139`; `Network/connection.h:275-283` | "the nw_connection_state_cancelled state will be delivered last"; "Outstanding sends and receives will receive errors before the state changes to cancelled." |
| N4c | New connection objects (replacement on reconnect, listener-accepted) | The listener's new-connection handler runs on the listener's queue (N1). The new connection is not started; the client sets its handlers and queue before starting it. Connections sharing one serial queue are FIFO on that queue (N2). Ordering across different queues is not documented | G (mechanics); N (across queues) | `Network/listener.h:204-213`; <https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler>; <https://developer.apple.com/videos/play/wwdc2018/715/> at 29:26-29:36 | "This connection is not yet started. Set the event handler and other settings on the connection before calling start." |
| N5 | `DispatchSource` read sources on BSD sockets | A source is not reentrant: events that arrive while its handler runs are coalesced and delivered after it returns. The handler is submitted to the source's target queue; `DISPATCH_TARGET_QUEUE_DEFAULT` means the default-priority global queue. The rule is stated per source. Nothing about threads | G (one source is non-reentrant); N otherwise | `dispatch/source.h:356-359`; `dispatch/source.h:386-389`; `dispatch/source.h:414-415`; <https://developer.apple.com/documentation/dispatch/dispatchsource/makereadsource(filedescriptor:queue:)> | "Dispatch sources are not reentrant." |
| N6 | Finite bound on threads; restart counting | Blocks run on a system-managed pool. The system decides its size and creates threads when workers block. No bound per queue or per object is documented, and nothing about restarts | N (the pool is explicitly system-managed) | `dispatch/queue.h:38-46`; `dispatch/queue.h:59-60`; `dispatch/queue.h:80-85` | "invoked on a pool of threads fully managed by the system"; "will create new threads when too many existing worker threads block in system calls" |

Reading: with a serial queue, a connection's handlers are FIFO and do not
overlap (N1, N2). For callback-to-callback serialization of one receive path,
an app-supplied serial dispatch queue (N2) and `DispatchSource` non-reentrancy
(N5) are the only documented mechanisms in this document. Two other rules are
separate: the legacy `MIDINotifyProc` run loop (M3b) covers notifications only,
not receive, and the AUv2 reset/render rule (A1b) is a duty on the host, not a
platform guarantee between render calls. No thread is guaranteed for any
block (N3), and an HB claim rests on the mutex analogy, not on a stated
memory-model guarantee. Today's WING receive path does not use these APIs
directly: it builds a `SwiftOSC` `OSCUDPSocket` with `queue: nil`
(`Shared/WING/WingTransport.swift:190` to `:210`), a third-party type whose
threading this document did not consult (section 7).

## 5. Consequences for FaultLatch chains (design implications, not platform facts)

Everything in this section is a design implication drawn from sections 2 to 4.
None of it is implemented, none of it is a platform fact, and none of it is a
proof. It states what an app design would have to enforce, by its own structure,
for a future caller to meet the contract at `FaultLatch.swift:123` to `:130`.

Common rules, because the platform documents no chain bound in any area and no
HB edge for audio or CoreMIDI:

- A chain is an app-owned object, not a platform thread. Mint a chain token per
  callback instance and per generation. Publish it with a release store, and have
  the callback read it with an acquire load, before the callback can start
  (engine start, port connection, queue start).
- Non-reentrancy is enforced or detected by the app, not assumed. One shape is a
  busy flag taken by an acquiring exchange on entry and cleared by a releasing
  store on exit. A call that finds it taken is a separate chain, which must be
  counted, or it must not raise.
- Every restart is a new generation with new chains. K is the sum over every
  callback instance and every generation over the latch's life, plus every other
  raiser. The platform documents no bound on any of these terms (A6, M8, N6).
  The app must argue the restart count itself, for example with a counted cap on
  generations per latch. This document does not choose a mechanism.

Per FLP1 site:

| FLP1 site | Future feeder | Chain rule an app design would have to enforce | Platform basis |
|---|---|---|---|
| S1 `SysExAssembler` (`SysExAssembler.swift:339`; role at `:28` to `:30`) | The `MIDIReceiveBlock` of an input port or virtual destination | One chain per receive block and per generation; recreating a port or destination mints a new chain. Call `accept` only from that block, or only from one app-owned serial queue that the block feeds through an atomic handoff. Keep notifications on a separate chain that never calls `accept`. The latch and chain token must outlive the port, because late callbacks after a disconnect or dispose are not excluded. Never assume a SysEx message completes within one callback | M1, M2, M3a, M5, M7 (N); M3b (W); M4 (G for partial SysEx, N for spanning) |
| S2 `FanInHandoff.claimProducer` (`FanInHandoff.swift:365`) and S4 `ReservedCapacityRing.refuse` (`ReservedCapacityRing.swift:238`) | Producer contexts: MIDI receive blocks, network serial queues, an input render chain, control | Each producer context is its own chain for `claimProducer` and for its lane's pushes. Count every context over the latch's life, including each new port, queue and render generation. Separate chains for input render and output render, and for MIDI receive and MIDI notify. Release a token only after its holder stops pushing (`FanInHandoff.swift:230` to `:233`) | A3c (G, iOS); M3b (W); N2 (G with a serial queue; N with a concurrent queue) |
| S3 `DeferredReleaseQueue.retire` via `PreparedPlanSlot.beginCycle` (`DeferredRelease.swift:122`; `PreparedPlanSlot.swift:82` to `:85`) | The output render callback: AU render block, source node block or manual rendering block | One chain token per render block and per generation (resource allocation, engine start, restart after a configuration change, format change, reconnection), minted and published with release/acquire before start. Do not reuse a chain across stop and start: no HB between the last render before a stop and the first render after a start is documented. Detect reentry rather than assume it never happens | A1, A3a, A5 (N); A1c, A2 (W) |
| Unknown-scope aggregate (`FaultLatch.swift:405` to `:409`; FLP1 section 6) | Every raiser above, on a scope that was never prepared | Every chain above counts once toward the same global K, whether or not its scope is prepared. The per-area counts must be summed for one latch, and the restart-count bound must be argued by the app because the platform documents none | A6, M8, N6 (N) |
| C `FanInRefusalCounter` users: `refusedClaims` and `refusedNotOwner` (`FanInHandoff.swift:284`, `:283`), `KernelAdmissionRefusals` (`ProducerAdmission.swift:56`); FLP1 section 4 | The same producer contexts as S2 and S4, plus any thread holding any token, stale or foreign (`FanInHandoff.swift:196` to `:197`) | Follows the S2 and S4 producer-context rules. Each counter's own lifetime bound must be argued separately, over that counter's lifetime, not the latch's: these are not `raise` calls, and the latch neither limits nor reports the invalid-token paths (`FanInHandoff.swift:197` to `:199`). A stale or foreign token holder that reaches `refusedNotOwner` is a chain for that counter even though it raises nothing | As S2 and S4; A6, M8, N6 (N) for any bound |

Per area:

- Audio: assume nothing about self-concurrency, thread stability or HB between
  render calls (A1, A2, A5). Treat input and output render as separate chains,
  since iOS non-aggregated I/O uses separate threads (A3c). Apple states that the
  Swift runtime is unsafe on realtime threads (A4); whether a raise path may run
  in Swift on a render thread is a #64 qualification question, not answered here.
- CoreMIDI: keep receive and notify on separate chains (M3b). Keep SysEx
  reassembly state per port and per source, in app-owned storage (M4, M5).
  Tolerate late receive callbacks after a disconnect or dispose, so the latch
  and chain token outlive the port (M3a).
- Network: pass an app-owned serial queue to `start(queue:)` for every connection
  and listener, never a concurrent queue: serialization is guaranteed with a
  serial queue and not documented with a concurrent queue (N2). Set it before
  start (N1). One serial queue shared by every connection is one chain, with HB
  resting on the mutex analogy (N3); each further queue is another chain, and a
  new connection on a different queue is a new chain bounded only by the app's
  connection churn (N4c). Keep one outstanding receive per connection (N2b).
  Give a `DispatchSource` an explicit serial target queue (N5). If an argument
  needs HB rather than mutual exclusion, an app-owned release/acquire token in
  each handler states the edge explicitly instead of relying on the mutex
  analogy (N3).

Out of scope, recorded as a follow-up: `DeferredRelease.swift:44` to `:47` and
`PreparedPlanSlot.swift:86` to `:87` require "one render thread". The platform
text above does not document a single render thread (A2, A3a). That is a
single-producer role question, separate from the `FaultLatch` chain bound, and
this document does not settle it.

## 6. Answers to FLP1 section 7

| Q | Short answer | Class | Section |
|---|---|---|---|
| 1. Audio render: self-concurrency, thread changes between calls, across stop/start, format change, reallocation | Self-concurrency is not documented for any render callback. AU render context may change between calls. Source node blocks may run on realtime or non-realtime threads. Thread identity across lifecycle events is not documented. A device change changes the I/O unit's workgroup. iOS non-aggregated I/O uses separate input and output threads | N; W (A1c, A2); G (A3b workgroup, A3c) | 2 |
| 2. CoreMIDI: self-concurrency, one thread for the port's life, disconnect, source change, notifications; SysEx7 reaching one receive path | Self-concurrency and thread stability are not documented; the wording names one CoreMIDI-owned receive thread. Disconnect and dispose have no threading or in-flight text. Notify blocks run on an arbitrary thread. A port's event lists reach its one block for every source, but SysEx spanning callbacks is not documented | N (M1, M2, M3a, M5, M4 spanning); W (M3b) | 3 |
| 3. Network: handler queue, serialization per connection, reconnection | Handlers run on the queue set before start. Serialization is guaranteed with a serial queue and not documented with a concurrent queue. Thread identity is not guaranteed. A waiting connection "normally" retries on its own; `restart` forces a retry on the same object; new connections need their own queue, and ordering across queues is not documented | G (N1, N2 serial, N4a `restart`, N4b, N4c); W (N3, N4a automatic retry); N (concurrent queue, across queues) | 4 |
| 4. HB edge for a context handed between threads | Audio: none documented. CoreMIDI: none documented. Dispatch: a serial queue is described as equivalent to a mutex, with no explicit memory-model text. Any HB edge a proof needs must be app-owned or rest on that analogy, stated as such | N (A5, M7, N3) | 2 to 5 |
| 5. Finite bound on distinct chains over a latch's life, with a restart counting rule | None documented in any area. The Dispatch thread pool is explicitly system-managed and grows when workers block. The bound and the restart rule must come from the app's own structure | N (A6, M8, N6) | 2 to 5 |

## 7. Gaps

Not consulted. Each remains an open evidence item:

- The open-source libdispatch implementation, for the memory ordering of serial
  queues. The headers and DocC give no explicit HB sentence (N3).
- Apple Technical Notes and Technical Q&As, including TN2091.
- AUv3 extension hosting and creation articles. `AUAudioUnit.h`,
  `AUAudioUnitImplementation.h` and `AudioUnitProperties.h` were used instead.
- CoreMIDI WWDC sessions. No CoreMIDI session transcript was found, and the
  CoreMIDI DocC articles include no threading article.
- Other WWDC sessions. WWDC 2019 session 510 (AVAudioEngine) was read and has
  no threading text. Guessed session IDs (2015/508, 2016/507, 2017/501,
  2018/501, 2018/236) returned no transcript, so those sessions were not read.
- The `MIDIReceiveBlock` DocC text on `srcConnRefCon` for virtual inputs, which
  was not quoted.
- The `swift-osc` package (`project.yml:75`) that provides `OSCUDPSocket` for
  `WingTransport.swift:190`.
- Headers from other SDK versions. Line numbers above apply to the 27.2 SDKs.

Audio headers searched for A6: `AUAudioUnit.h`, `AUAudioUnitImplementation.h`,
`AUComponent.h`, `AudioUnitProperties.h`, `AudioWorkInterval.h` and
`AudioOutputUnit.h` (AudioToolbox); `AVAudioEngine.h`, `AVAudioSourceNode.h`,
`AVAudioSinkNode.h`, `AVAudioIONode.h` and `AVAudioNode.h` (AVFAudio);
`AudioHardware.h` (CoreAudio). An N means nothing was found in these sources. It
does not mean Apple has no such contract elsewhere.

## 8. What remains for #190

This slice discharges none of FLP1 section 8's items. They stay unchecked; they
are summarised here, and FLP1 section 8 holds the full wording:

- [ ] S1: a finite bound on contexts that call `SysExAssembler.accept`, and the
  ordering from one context's completed raise to its next `accept`.
- [ ] S2: a finite bound on contexts that call `claimProducer`, and the ordering
  from a refused claim's raise to that chain's next claim.
- [ ] S3: the render caller of `DeferredReleaseQueue.retire` shown to be one
  chain or a bounded set, and its ordering.
- [ ] S4: the producers that can hold a lane over the latch's life, their pushes
  ordered, and a hand-over ordering for successive holders of a lane.
- [ ] Global: the sum over every raiser sharing one latch, including raisers on
  unprepared scopes (`unknownScopeFaults`), is below 2^39.
- [ ] C: the same bound for each `FanInRefusalCounter` user, over each counter's
  own lifetime.
- [ ] A real caller for each of the above, identified from authoritative
  evidence. This document supplies platform evidence only; no production caller
  exists yet (FLP1 section 7).
- [ ] A check, test or model that fails if the bound or an edge is broken, on the
  real caller. It supplements the proofs and never replaces them.

The evidence shows no platform-provided chain bound and no platform-provided HB
edge for audio render or CoreMIDI receive callbacks. For callback-to-callback
serialization of one receive path, the only documented mechanisms are an
app-supplied serial dispatch queue (N2) and `DispatchSource` non-reentrancy
(N5). Neither has a documented bound, and HB on a serial queue rests on the
mutex analogy (N3). Two rules are noted separately: the legacy `MIDINotifyProc`
run loop (M3b) covers notifications only, not receive, and the AUv2
reset/render rule (A1b) is a duty on the host, not a platform guarantee between
render calls. A real caller proof must therefore come from app-owned structure,
such as the rules in section 5, and must cite this document only for what the
platform does or does not promise.

The rule stands: callers that have not proved the contract stay out of hot-path
integration. If the bound cannot be established for a real caller, the counter or
record algorithm must be revised and revalidated, not weakened, and #64's
acceptance is not waived.
