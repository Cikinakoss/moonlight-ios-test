# Latest-frame presentation trigger experiment

The preserved control is commit `1b714a9`, tagged
`working-latest-decoded-frame`. In Settings, enable **Latest Decoded Frame**,
choose **Presentation Trigger: Display Sync / Immediate**, save and reconnect.
Display Sync defaults on a fresh install. The trigger selector is disabled when
Latest is Off or unavailable (requires iOS/tvOS 17+). Its saved preference survives
turning Latest Off. Previous Async/Immediate experiments remain unchanged with
Latest Off.

## Display Sync: control

Decoded outputs replace the same single pending CVPixelBuffer under the existing
lock and PTS/sequence/generation ordering rules. Each physical CADisplayLink
callback checks the display layer's readiness, takes the newest pending image,
wraps it and enqueues on the main thread. An empty slot does nothing. Presentation
selection/readiness/layer recovery follow the previous implementation; added
timestamps and counters measure it without adding pacing.

## Immediate: decoded output triggers presentation

An accepted newer decoded output signals LatestFramePresentationScheduler after
releasing the mailbox lock. The VT callback never wraps an image, touches a layer,
waits for the main queue or waits for presentation. Late/rejected outputs do not
signal presentation.

The scheduler uses a dedicated serial user-interactive GCD queue, one outstanding
worker flag and one dirty flag. The first request queues a worker. Requests while
it is queued/running set the dirty flag and count as coalesced; they do not queue
another block or retain a per-request frame. A worker clears the dirty flag before
reading the mailbox. Outputs arriving during its pass request another pass of
the same worker. Clearing outstanding and accepting a new request share the same
lock, preventing a lost wakeup at the idle transition. Group entry occurs under
that lock, so stop cannot miss a newly dispatched task.

For example, outputs 100 and 102 before worker execution produce one selected
image, 102. A late 101 remains rejected by the shared freshness rules. A newer
image arriving during sample wrapping makes the selected candidate stale: the
worker checks sequence and generation again immediately before enqueue, releases
the superseded sample and services the coalesced request for the newer slot.
An output arriving after that last check signals another pass; it cannot retract
a sample already being handed to AVFoundation.

There is exactly one pending decoded slot and at most one outstanding presentation
worker/request. A selected image is temporarily owned by the current pass's
sample while being wrapped/handed off; it is not stored in a presentation FIFO.
Samples reference the existing decoded CVPixelBuffer, with no new image buffer,
RGB conversion or CPU pixel copy. Original PTS and the sample-level
DisplayImmediately attachment remain intact in both strategies.

Immediate uses AVSampleBufferVideoRenderer (displayLayer.sampleBufferRenderer),
whose public iOS/tvOS 17+ API supports background enqueue. All enqueues in this
strategy use the single serial presentation queue. CALayer creation/replacement
and first-image visibility remain on the main thread. Only startup/recovery
needs synchronous main work, and VT callbacks continue coalescing while the
presentation worker waits. No per-frame main-queue block is added.

If the renderer is not ready, the worker leaves the slot replaceable and arms
a one-shot requestMediaDataWhenReady callback on the same serial queue. Readiness
recovery cancels that subscription before signaling the existing coalescer, so
even a final frame or network pause can recover without new decoded output.
Accepted outputs also request attempts. Success, layer replacement and shutdown
cancel the subscription; tokens reject callbacks queued by an older registration.
No polling, sleep, compressed-reference dropping or display-link retry is used.

CADisplayLink remains active for aggregate statistics, callback rate and timing
observations in Immediate. It never selects or enqueues a decoded image there.
Immediate can hand off more than 60 images/s to AVFoundation while the physical
panel stays 60 Hz. API enqueue counts are not physical refresh counts.

## Lifecycle and decoder settings

Stop atomically closes the renderer and cancels presentation requests, wakes and
joins compressed submission, drains the presentation worker off the main thread,
then drains/invalidate/releases VT and clears its slot/output notification. The
main queue remains available to finish any first-image/recovery operation. Queued
cancelled workers do no presentation. Request/dirty state is cleared when drained;
start resets counters and the gate. Production callbacks hold weak renderer
references, and dispatch groups retain running scheduler work through completion.
Reconnect uses the existing connection ownership rules.

Presentation-layer failure is recovered on the main thread without resetting the
compressed decoder. VT format/error reset still uses the existing generation and
IDR handling; an Immediate candidate from a stopped/reset generation is rejected.
Background/foreground retains the app's existing stop/reconnect behavior.

The previous decoder already explicitly wrote RealTime=true and logged its status
once per session. Apple documents realtime playback (true) as the default; the
existing write remains unchanged to keep this a presentation-trigger experiment.
EnableAsynchronousDecompression remains enabled and EnableTemporalProcessing is
not requested. No decoder tuning or intentional reorder-buffer setting was added.
Actual VT internal buffering/reordering cannot be inferred from source or these
synthetic tests; device decode latency and in-flight counters remain the evidence.

## Measurements

The overlay/log identifies the trigger and reports roughly once per second:

- Compressed submissions and decoded/asynchronous outputs per second.
- Presentation requests and completed API enqueues per second. Display Sync
  counts one attempt per display callback, including an empty/not-ready slot;
  Immediate counts accepted-output and readiness-retry requests, including those coalesced.
- Overwritten pending images, coalesced requests, late decoder rejects and
  selected candidates superseded before Immediate enqueue, per second.
- Latest slot depth (0/1), outstanding presentation worker/request depth (0/1),
  VT in-flight count, display callbacks/s and mean link targetTimestamp-timestamp.
- VT drops/errors/resets, wrapper errors, not-ready checks and output pixel format.
- Decode latency: submission to decoded callback entry.
- **Presented Frame Age (selection)**: callback entry to presentation selection,
  averaged over samples actually handed to the API. This retains the old local
  selection-age meaning, now made explicit, and works for either trigger.
- **Decode Output -> Enqueue Age**: callback entry to the time immediately after
  the enqueue call returns; includes scheduling, selection, wrapping and API call.
- **Display Sync selection age** and **target lead**: callback entry to selection,
  and targetTimestamp minus selection time, for enqueued Display Sync samples.
  Negative lead means selection was after the estimated target. Both are N/A for
  Immediate, rather than assigning a display callback to its independent worker.

None of these ages measures photons, host rendering or network delay. Apple's
targetTimestamp is an approximate display-update target, not actual scanout
feedback. AVFoundation/compositor retention remains outside our application slot.

## Validation and physical comparison

The existing macOS AddressSanitizer harness imports the production scheduler and
mailbox. Added deterministic tests hold its queue, send a concurrent burst of
requests and verify one pass presents the newest image. Tests also cover rejected
outputs not signaling, a newer output during wrapping, distinct enqueue/selection
ages, output during an active pass, idle wakeup, cancellation of queued work,
restart and idempotent stop. Existing CF ownership, metadata, PTS ordering and
error-recovery tests remain enabled. CI builds iOS/tvOS Debug/Release and unsigned
iOS Release, runs the harness, and packages/uploads the unsigned IPA.

Compare Latest ON with Display Sync against Latest ON with Immediate, reconnecting
between settings. Keep the same 60 Hz iPad, Apollo virtual display at 120 Hz,
120 FPS stream, 120 FPS+ game, codec/bitrate/scene and Lowest Latency setting.
Check responsiveness and judder, enqueue and selection ages, overwrite/coalesce
rates, not-ready checks and decoder backlog over several minutes. Test quick
stop/reconnect, disconnect, background/foreground and resolution/HDR changes.
Keep Display Sync as the default regardless of this build's synthetic results;
physical-device evidence determines the better strategy. Stop at this experiment
before adding custom pacing or decoder tuning.

Sources:

- [Apple: background-safe sampleBufferRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer)
- [Apple: sample-buffer enqueue and DisplayImmediately](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/enqueue(_:))
- [Apple: RealTime defaults](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_realtime)
- [Apple: CADisplayLink targetTimestamp](https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp)
