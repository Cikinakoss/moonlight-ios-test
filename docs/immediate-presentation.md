# Immediate presentation experiment

In Settings, scroll below Async Video Submission to **Immediate Latest-Frame
Presentation (Experimental)**. It defaults to Off and works independently of
the async and frame-pacing preferences. The renderer samples both experimental
preferences once when a stream is created. Stop, change settings and reconnect
to compare modes in the same IPA.

## Inspected presentation path

VideoDecoderRenderer.submitDecodeBuffer() constructs CMSampleTimingInfo using
CMTimeMake(du->presentationTimeUs, 1000000) for PTS. Duration and DTS are invalid,
as before. CMSampleBufferCreateReady() creates a sample buffer containing one
compressed video sample. The normal path enqueues on AVSampleBufferDisplayLayer
on the main thread; async mode enqueues on that layer's sampleBufferRenderer on
the existing serial video-submit queue. AVFoundation owns the decode and display
stages. There is no application-held decoded-image queue or output-frame slot.

No controlTimebase is assigned. Apple's documented default is the host-time
clock. With Immediate Off, the API schedules using the sample's output PTS.
The core describes presentationTimeUs as relative to the first captured frame,
and derives it from the RTP timestamp or, for hosts without valid PTS, relative
receive time. The app does not translate that epoch to host time. Therefore
those PTS values may already appear late against the host clock; this is an
inference from the source and documentation, not a measurement of actual iPad
presentation. We must not assume that all observed delay comes from future PTS
waiting. This experiment leaves the timestamp values and timebase untouched.

Before this change there was no DisplayImmediately or DoNotDisplay attachment,
flush/flushAndRemoveImage call, explicit late-image replacement, or decoded-frame
drop policy. The async experiment already checks readyForMoreMediaData and uses
the core's DR_NEED_IDR recovery if the renderer cannot accept more input. The
normal path does not gate submission on readiness; this remains unchanged.
The core's compressed-frame queue is bounded to 15 entries and recovers with an
IDR on overflow. AVFoundation has internal decode/presentation queues whose
depths are not exposed by these diagnostics.

## Minimal change

When enabled, after CMSampleBufferCreateReady() succeeds and before either
enqueue API, the renderer obtains the sample attachment array using
CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true). The buffer contains
one sample, so it sets the first sample dictionary's
kCMSampleAttachmentKey_DisplayImmediately to kCFBooleanTrue using
CFDictionarySetValue(). The returned array/dictionary are borrowed references;
they are not released separately. If attachment creation fails, the sample and
its buffers are released and the existing decode-error result is returned.

PTS remains present. No sample-buffer-level CMSetAttachment() call is used.
The Off path does not create or change the sample attachment dictionary. No
compressed-frame filtering, flushing, smoothing buffer or output-image queue is
introduced. Codec/color/HDR/aspect/audio/input handling and 120 FPS configuration
remain unchanged.

Apple documents that this attachment causes the decoded image to be shown as
soon as possible and to replace previously enqueued images regardless of their
timestamps. That supplies a documented presentation replacement request while
preserving the ordered compressed input. It does not prove a particular decode
queue depth, physical scanout latency, number of replaced images, or that every
60 Hz refresh receives the newest possible image. Readiness/backpressure and
decode throughput can still limit freshness. The existing async overload/IDR
recovery is preserved; this experiment adds no new compressed-frame drop rule.

## Frame pacing and lifecycle

This repository has Lowest Latency and Smoothest Video, but no Balanced option.
Lowest Latency drains available frames during a display callback when async is
Off. Smoothest Video can keep one compressed frame pending when physical display
refresh is at least 90 percent of configured stream FPS. At 60 Hz versus 120 FPS,
that smoothing branch does not retain the pending frame. Async mode already
bypasses that display-driven pacing branch entirely.

Immediate Presentation does not change or force any frame-pacing preference.
With async Off, it cannot eliminate the wait for a display callback to submit
compressed frames. With Smoothest Video it cannot undo any upstream retention
of compressed frames. Use Lowest Latency and Async On for the primary test.

Every newly created sample is tagged based on the renderer's immutable session
preference, so display-layer recreation needs no separate presentation-mode
state restoration. Existing start, stop, wake/join, background/disconnect and
reconnect ownership logic is unchanged. No new worker or pending sample buffer
is introduced. Physical-device lifecycle verification remains necessary.

## Diagnostics and test matrix

The existing overlay and one log entry per second now include Immediate ON/OFF,
the rate of immediate-tagged enqueues, and readiness at the last pre-enqueue
check. Existing configured FPS, submitted/enqueued rates, display callback rate
and async backpressure-drop count remain. Readiness is a cached observation, not
continuous queue-depth telemetry. Tagged enqueues are not decoded/displayed or
overwritten-frame counts; AVFoundation exposes no such trustworthy counter here.

Use a 60 Hz iPad, Apollo display at 120 Hz, game at least 120 FPS, the same
resolution/bitrate/codec, a 120 FPS stream and Lowest Latency for all three tests:

| Test | Async | Immediate |
| --- | --- | --- |
| A | Off | Off |
| B | On | Off |
| C | On | On |

Reconnect after each change. In C, expect approximately 120 submitted/enqueued
and immediate-tagged samples per second, about 60 display callbacks per second,
and ideally zero renderer backpressure drops. Compare input response and rapid
camera pans, and watch for increasing delay over several minutes. Also test
background/foreground, exit/reconnect and host disconnect/reconnect. A successful
IPA build verifies compilation, not presentation smoothness on physical hardware.

References:

- [Apple: DisplayImmediately semantics](https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately)
- [Apple: enqueue replacement semantics and correct attachment API](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:))
- [Apple: default controlTimebase and host clock](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/controltimebase)
- Pinned core: src/Limelight.h, RtpVideoQueue.c and VideoDepacketizer.c at
  f900dd4767759c7b9d0e93bcea666b55c69ea62f.
