# Async video submission experiment

In Settings, scroll below Statistics Overlay to **Async Video Submission
(Experimental)**. It defaults to Off and requires iOS/iPadOS 17 or newer. The
preference is stored locally in NSUserDefaults and is sampled when a renderer is
created. Stop the stream, change the setting, then reconnect to compare modes.
Changing settings never switches consumers inside a running stream.

## Pipeline verified at the pinned core revision

The existing 120 FPS setting still flows through SettingsViewController's
getChosenFrameRate(), the saved settings, MainFrameViewController's frameRate,
Connection's STREAM_CONFIGURATION.fps, and LiStartConnection(). The display
refresh rate does not cap it.

With the experiment Off, the core's network thread assembles compressed frames
into its decode-unit queue. VideoDecoderRenderer creates CADisplayLink and adds
it to the main run loop. displayLinkCallback() polls queued frames using
LiPollNextVideoFrame(), calls DrSubmitDecodeUnit(), then completes each handle
using LiCompleteVideoFrame(). All four operations happen on the main thread.
DrSubmitDecodeUnit() gathers the compressed picture data and passes it to
submitDecodeBuffer(), which creates the format/sample buffers and calls
AVSampleBufferDisplayLayer's enqueueSampleBuffer:. AVFoundation performs the
actual decode/display internally. No other submission callback is registered
in Connection: CAPABILITY_PULL_RENDERER is already enabled.

With the experiment On, one serial dispatch queue at public
QOS_CLASS_USER_INTERACTIVE priority blocks in LiWaitForNextVideoFrame(). It
submits and completes each frame before requesting the next. The core's queue
condition variable wakes it on frame arrival; there is no sleep or polling
timer. Its public pull API is intended for a client-managed decoding thread;
it has no main-thread requirement. The core's IDR validation/completion state
does require sequential processing, so there is exactly one consumer and one
outstanding handle. CADisplayLink returns before polling in this mode and is
retained only to measure physical display callbacks.

The same compressed buffers, codec format descriptions, sample timestamps,
color/HDR metadata and AVSampleBufferDisplayLayer are used. The experiment feeds
the layer's sampleBufferRenderer, which Apple explicitly documents as safe for
background enqueueing starting with iOS 17. View/layer creation, replacement,
visibility, and videoContentShown() remain on the main thread. A decoder lock
serializes HDR metadata changes from the core with compressed frame submission.
The Off path retains its existing enqueue API and frame-pacing logic.
Async mode bypasses the display-driven Smoothest Video pacing branch; use
Lowest Latency for this experiment.

## Lifecycle

The core's DrStart callback starts the sole worker. DrStop sets an atomic stop
flag, calls LiWakeWaitForVideoFrame(), and waits for the dispatch group before
invalidating the display link on the main thread. The core invokes DrStop
before shutting down or destroying its frame queue, making an explicit wake
necessary. The wake is sticky in LinkedBlockingQueue, so a wake immediately
before the worker waits is not lost. A handle acquired as shutdown begins is
completed once without submitting it; an already-running submission finishes
before DrStop returns.

DrStop runs on the connection/termination operation, never the main thread or
the video worker. No UI callback waits for termination: Connection.terminate
already dispatches LiStopConnection() off-thread. Main-thread layer recovery
can therefore finish while shutdown waits. A failed display layer is recreated
synchronously on the main thread by the sole submitter, followed by the existing
DR_NEED_IDR recovery. There is no second consumer during recreation. Stream
exit, backgrounding and connection failures retain the existing stopStream /
Connection.terminate lifecycle. Each subsequent renderer samples the preference
again and creates its own worker; the stopped worker cannot consume later frames.

Connection now keeps its renderer/callbacks per instance and replaces the core's
global callback targets only inside the existing initialization lock, after
LiStopConnection() has joined the previous consumer. A connection-owner check
prevents an old pending terminate operation from stopping a newer connection.
Cancellation before startup is also remembered. This matters because the old
initializer replaced the global renderer before the old stream had necessarily
stopped, which could otherwise redirect a background consumer on rapid reconnect.

## Buffering limits and what this experiment does not prove

AVFoundation has internal decode/presentation queues. Neither its API nor these
submission counters guarantees newest-frame-wins presentation, an exact number
of decoded/displayed frames, or elimination of all internal latency. Existing
sample timestamps are preserved; no DisplayImmediately attachment, custom
timebase, pixel-buffer slot or new late-frame algorithm is added. The original
renderer has no explicit stale decoded-frame drop mechanism.

The pinned core bounds its compressed decode-unit queue to 15 entries and uses
IDR recovery on overflow. In async mode, AVFoundation's readyForMoreMediaData
signal is checked before enqueueing. If it refuses more data, the sample is not
enqueued and the existing DR_NEED_IDR path is used: compressed reference frames
cannot safely be discarded while continuing to decode dependent frames. This
avoids continuing to feed an overloaded renderer or introducing an application
presentation backlog. Saturation could still produce visible IDR recovery
stutters; the backpressure counter makes this observable. Internal AVFoundation
queue depth and its treatment of obsolete decoded frames remain device-test
questions. The experiment does not guarantee a smooth 120-to-60 FPS conversion.

## A/B test

1. Use the same host scene, 1080p, 120 FPS, bitrate, codec, and Lowest Latency
   preference for both runs. Keep the Apollo virtual display at 120 Hz and game
   FPS at least 120. Enable the existing Statistics Overlay.
2. Run with Async Video Submission Off, then stop, enable it, and reconnect.
   Verify the overlay reports Requested: 120 FPS and the appropriate mode.
3. Both runs may submit approximately 120 frames/s with approximately 60 display
   callbacks/s. In Off mode those submissions occur in display-callback batches;
   in On mode their scheduling is driven by frame availability. The counts alone
   do not measure submission spacing, decoded FPS or presented FPS.
4. Compare rapid camera pans and input response. Check submitted/enqueued rates,
   renderer backpressure drops, network drops and latency. Normal async operation
   should show close to 120 enqueues/s and zero backpressure drops. Watch for
   increasing delay or repeated decoder/IDR errors over several minutes.
5. Repeat exit/reconnect, background/foreground and host disconnect/reconnect.
   There should be no hangs, lingering worker, duplicate submissions or black
   screen on restart. A decoder-error recovery also needs physical-device testing.

The overlay and one aggregated log entry per second report configured FPS,
submission attempts, accepted enqueues, display callbacks and backpressure
drops. These are not hardware decoder or presentation counters.

The existing unsigned IPA workflow remains unchanged: Moonlight.xcodeproj,
Moonlight scheme, Release, generic iOS device, artifact Moonlight-iPad-120FPS.

References:

- [Apple: background-safe sampleBufferRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer)
- [Apple: queued sample-buffer readiness](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/requestmediadatawhenready(on:using:))
- [Apple: user-interactive QoS](https://developer.apple.com/documentation/dispatch/dispatchqos/qosclass-swift.enum/userinteractive)
- Core API and implementation: moonlight-common/moonlight-common-c/src/Limelight.h,
  VideoDepacketizer.c, VideoStream.c and LinkedBlockingQueue.c at
  f900dd4767759c7b9d0e93bcea666b55c69ea62f.
