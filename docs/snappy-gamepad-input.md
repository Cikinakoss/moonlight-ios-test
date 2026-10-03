# Snappy Gamepad Input experiment

Baseline: parent `1b6b294` on `ipad-120fps-test`; common-c `f900dd4767759c7b9d0e93bcea666b55c69ea62f`.
The video sources, renderer behavior, presentation choices, statistics, and prior video commits are unchanged.

## Before the change

`GCController` -> `GCExtendedGamepad.valueChangedHandler` -> ControllerSupport state setters ->
`updateFinished:` -> `LiSendMultiControllerEvent()` -> `sendControllerEventInternal()` ->
`currentQueuedControllerPacket[controllerNumber]` / `packetQueue` -> InputSend ->
`sendInputPacket()` -> `sendInputPacketOnControlStream()` -> `sendMessageEnet()` ->
ENet control stream -> Apollo/Sunshine. Host processing is outside these measurements.

1. Moonlight does not set `handlerQueue`; Apple documents its default as the main dispatch queue.
2. The extended-gamepad handler reads the complete state, updates it synchronously, and calls
   `updateFinished:` once per callback. There is no dispatch hop on this path. The legacy MFi
   pause handler separately dispatches an emulated 100 ms press/release to a high-priority queue.
3. `updateFinished:` takes `_controllerStreamLock`, synchronizes the controller state, reports
   arrival when necessary, merges OSC state where applicable, and calls common-c directly.
4. `batchedInputMutex` protects each controller slot's editable pending packet. With unchanged
   low/extended button masks, a new event overwrites the pending axes/triggers and active mask.
5. A button-mask change seals the old packet by publishing a new holder. The older holder stays
   in the FIFO so both press and release remain observable. All controller packets are reliable.
6. InputSend dequeues a holder, takes the batching mutex, and clears the slot only if it still
   points to that holder. If an edge already published a later holder, that newer pointer remains.
   After this claim the old holder is immutable, and the next event immediately queues a new one.
7. The queue signals its condition variable on an empty-to-nonempty transition. InputSend blocks
   normally when idle. There is no controller-specific batching timer or polling loop.
8. The send worker uses `moreData = packetQueue.count > 0`. With `moreData=false`,
   `sendMessageEnet()` calls `enet_host_service(..., 0)`. With true it queues the ENet packet
   and relies on later service. Reliable send-now requests retain stock backpressure: up to ten
   1 ms retries if the packet has not yet been sent. This does not wait for a new callback.
9. InputSend is created by `PltCreateThread()` with ordinary pthread attributes on Apple. It has
   no explicit requested QoS; actual inherited/system scheduling is not claimed to be a fixed class.
10. Stock stop closes admission, drains the input queue, joins InputSend, then destroys its queues.
    Inspection also found missing controller-pointer resets and dangling pointers on offer failure.

## What changes

The new settings switch is **Snappy Gamepad Input (Experimental)**, default **Off**. It is stored
in `NSUserDefaults` and snapshotted immediately before `LiStartConnection()`, after the previous
connection has stopped. Reconnect after changing it.

Physical controllers use `LiSendPhysicalGamepadEvent()`. OSC keeps `LiSendMultiControllerEvent()`.
The physical entry point records callback/enqueue/claim/send timing and serializes admission against
stop using a mutex that remains valid across connections. Late calls after destruction return `-2`.

When enabled:

- Physical controller holders pass `moreData=false` when dequeued, requesting immediate ENet
  service through the existing transport. There are no added `enet_host_flush()` calls, and no
  changes to control-stream backpressure or reliable delivery.
- InputSend requests public `QOS_CLASS_USER_INTERACTIVE` with relative priority 0, once at
  worker entry. The result is logged. No other thread's priority is changed.
- New physical holders are allocated/published/offered under the batching mutex, so another
  producer cannot create a second stale analog holder in an allocation/enqueue gap.
- Active-gamepad-mask changes also seal the pending physical packet, preserving connect/removal
  state even when the digital button mask is unchanged.
- Physical disconnect clears the removed controller's buttons, emulation, axes and triggers
  before reporting removal; OSC merging remains in effect.
- Pending Snappy physical holders are discarded after stop closes admission. A packet already
  handed to transport cannot be recalled; the worker is joined before teardown completes.

The existing newest-analog and digital-edge policies are retained. Stable-button analog input
normally has one claimed state plus at most one editable pending state per slot. Digital edges
intentionally require additional FIFO packets; a hard one-packet limit would lose them. The existing
150-packet input bound still applies, and failures are returned rather than silently treated as success.

Off retains stock packet contents, coalescing, send hints, ordinary thread attributes and stop drain
behavior. Diagnostics add small bookkeeping overhead; this is behavioral compatibility, not a claim
of zero overhead. Safety fixes in both modes reset slot pointers on initialize/destroy, clear a failed
offer's pointer before recycling the holder, and block submissions from a cleaned-up ControllerSupport.
The new physical API rejects negative controller numbers. No gamepad callback queue is changed.

Mouse, keyboard, touch, pen, controller touchpad/motion/battery and their batching are unchanged.
The worker remains shared, so InputSend's higher QoS may also benefit other input on that worker.
Mouse/pen retain their existing 1 ms waits. Shared FIFO waits (including Unicode's existing waits)
and transport backpressure can still delay a controller packet; this is not a promise of zero latency.

## Diagnostics

Client logs contain a `Gamepad client ON/OFF` report after at least one second, emitted on a physical
packet send. Each line includes the measured interval length; divide its counts by that length for
per-second rates. Idle periods do not create a timer or wake the worker merely to print diagnostics.

Tracked timestamps use common-c's monotonic microsecond clock:

1. GCController extended-gamepad callback entry (`LiRecordGamepadCallback()`).
2. Most recent physical enqueue/coalesced update on a holder.
3. InputSend's claim under the batching mutex, after dequeue and before it becomes immutable.
4. Handoff immediately before `sendInputPacket()`.
5. Return from the send path. For a send-now control packet, the existing path has attempted ENet
   service by this point. This is not an exact flush timestamp or proof the host received the packet.

Queue Age = claim time minus the newest physical callback carried by that packet.
Send Age = transport handoff minus that same newest callback. Analog supersession updates this
callback timestamp. `oldest-event/send` additionally measures handoff from the first original event
that created/promoted the packet, so coalescing cannot hide a long-lived pending holder.
`send-return` includes time in the transport, including existing backpressure.

The report contains callback, created/promoted physical holder, coalesced-update, sent-holder,
button-forced-packet, successful controller dequeue (`dequeue-wakes`), and send-now-request counts;
pending physical-holder count and its high-water mark; average/max Queue Age and Send Age; and a
histogram p95 Queue Age bound. `dequeue-wakes` counts successful tracked controller queue waits,
not actual scheduler wakeups, which may be fewer when the worker drains an existing backlog.
The p95 histogram has 250 us buckets with an overflow bucket starting at 15.75 ms.
Counters can span packet boundaries between intervals; created includes attempted offers.

No metric includes Bluetooth/USB delay before callback delivery, host game processing, host video,
network return, decode, display presentation, or input-to-photon latency.

## Tests and builds

`moonlight-common/moonlight-common-c/tests/gamepad-input-tests.c` includes the actual InputStream
implementation and runs its real blocking queue, mutexes and send worker. Host transport and crypto
are stubbed to inspect outgoing state/hints. Both modes cover rapid analog updates and triggers;
empty/editable/claimed states; rapid A down/up, alternating A/B, D-pad, RB and extended-button edges;
two player slots; disconnect masks; overflow and interrupted offers; pending shutdown/reconnect;
late calls after destroy; transport failure; unchanged virtual-controller hints; immutable connection
configuration; diagnostics; and a concurrent live worker receiving 4,000 callbacks.

The fork's gamepad workflow runs AddressSanitizer and UndefinedBehaviorSanitizer on Linux and macOS.
The parent unsigned-IPA workflow runs the same gamepad tests and the existing latest-frame tests
before packaging. Existing iOS/tvOS Debug/Release jobs and recursive submodule checkout are retained.
The unsigned IPA's Payload/app layout and upload artifact name remain compatible with AltStore;
physical installation and perceived latency must be tested on the user's iPad.

Common-c fork: https://github.com/Cikinakoss/moonlight-common-c, branch `snappy-gamepad-input`.
The parent gitlink pins the exact published commit rather than following a branch at build time.

Changed parent files: `.gitmodules`, `.github/workflows/ipad-120fps.yml`,
`Limelight/Input/ControllerSupport.h`, `Limelight/Input/ControllerSupport.m`,
`Limelight/Stream/Connection.m`, `Limelight/ViewControllers/SettingsViewController.m`,
this report and the common-c gitlink. Changed common-c files: `src/InputStream.c`, `src/Limelight.h`,
`src/PlatformThreads.h`, `tests/gamepad-input-tests.c`, `.github/workflows/gamepad-tests.yml`.

Stop after producing this build. Compare Off/On with identical video settings on the physical iPad
before adding any further input experiments.

## Apple references

- [GameController handlerQueue (default main queue)](https://developer.apple.com/documentation/gamecontroller/gcdevice/handlerqueue)
- [Public pthread QoS configuration](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/PrioritizeWorkWithQoS.html)
