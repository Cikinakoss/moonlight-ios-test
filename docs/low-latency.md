# Low Latency preset

Enable **Low Latency (Experimental)** below the statistics overlay setting,
save, and reconnect. Requires iOS/iPadOS/tvOS 17 or later. It defaults to Off on
a fresh installation. Frame rate remains in its existing selector: choose
120 FPS separately for the tested iPad configuration. The preset neither changes
that selection nor caps requested stream FPS to the panel's refresh rate.

## Preserved configuration

| Previous experiment | Preset On |
| --- | --- |
| Latest Decoded Frame | On |
| Presentation Trigger | Immediate |
| Snappy Gamepad Input | On |
| Async Video Submission | On internally |
| Immediate Latest-Frame Presentation (old compressed-sample experiment) | Removed; the tested configuration used Off |

The standalone async/compressed-immediate experiments and the decoded-frame
Display Sync alternative have been removed. Off uses the standard compressed
AVSampleBufferDisplayLayer path and the existing frame-pacing preference.
Unsupported OS versions also use that standard path.

Saved Latest Decoded Frame + Immediate trigger + Snappy Gamepad On, with the old
Immediate Latest-Frame Presentation Off, automatically maps to preset On.
Async's saved value is immaterial because latest decoding already forced it On.
Other legacy combinations map to Off; enable the new switch to select the tested
combination. Saving Settings records the new preference and removes the five
obsolete preference keys. An explicit new Off always overrides legacy preferences.
The preset is sampled once into StreamConfiguration before startup; controller
callbacks, connection startup, and video rendering share that snapshot.

## Video and input behavior

The existing serial compressed-video worker submits ordered input to a hardware
VideoToolbox decoder. Codec parsing, timestamps, reference dependencies, native
pixel formats, and color/HDR metadata are preserved. There is no RGB conversion
or CPU pixel copy. One retained pending decoded image is replaceable by newer
output. Persistent PTS/sequence/generation ordering rejects late callbacks even
after presentation has consumed the slot.

Accepted output signals the existing coalescer on its serial presentation queue.
One outstanding worker selects the newest image and checks freshness again before
enqueueing through AVSampleBufferVideoRenderer. Decoded image samples retain the
DisplayImmediately attachment that was already unconditional in the tested path;
retiring the old compressed-sample toggle does not remove that attachment.
CADisplayLink collects diagnostics and never gates this presentation path.

When AVFoundation is not ready, a one-shot media-readiness callback retries through
the same coalescer, including during a network pause or after the last output.
Success, layer replacement, and shutdown cancel the registration; stale queued
callbacks cannot affect a newer registration. Layer creation and first-image
visibility stay on the main thread. Shutdown closes admission, joins compressed
submission, drains presentation and decoder callbacks, and releases pending image
ownership before core queues are destroyed.

Physical gamepads retain the Snappy policy: coalesce fresh analog state, preserve
button edges, request prompt transport servicing, and reject late physical
callbacks during teardown. On-screen controls retain their normal classification.
Physical and virtual updates for the same player seal a batch when its source
changes, so they cannot inherit each other's timestamps or send policy.

Startup cancellation remains sticky through HTTP launch/resume and the queued
main-thread handoff. Leaving the stream screen prevents a later connection from
starting against the dismissed view.

## Diagnostics and troubleshooting

Enable the existing statistics overlay to confirm **Low Latency: ON**,
**trigger: Immediate**, and the requested stream FPS. It reports decode latency,
output-to-enqueue age, pending slot/worker depth, VT in-flight count, readiness,
overwritten/rejected frames, and decoder/presentation errors. API enqueue counts
and frame ages do not measure physical refreshes or end-to-end display latency.

Reconnect after changing the preset. If a build behaves poorly, compare preset
Off with the same frame rate, codec, resolution, bitrate, host, and game scene.
Increasing VT backlog, decoder errors, and repeated not-ready checks are useful
evidence when diagnosing delay or judder. Keep the host/game producing enough
frames for the separately selected stream rate.

## Validation and remaining device checks

The unsigned IPA workflow builds iOS Release and runs sanitizer checks for:

- Production decoded-image ownership, freshness ordering, metadata, coalescing,
  readiness-only recovery, cancellation, and restart.
- Production gamepad queueing, button edges, mixed input sources, and teardown.
- Preference migration, explicit Off, save/obsolete-key cleanup.
- Startup cancellation before/during HTTP and during main-thread handoff, plus
  shared video/input preset propagation without changing selected frame rate.

The separate CI workflow builds iOS and tvOS Debug and Release. Download the
unsigned IPA artifact from this fork's **iPad 120 FPS IPA** workflow and sign it
using the same installation method as previous experiments.

Before marking the preset final, verify on the actual iPad:

- A longer play session with the previous best configuration, checking response,
  camera motion, memory use, and whether latency grows over time.
- Rapid exit/reconnect and cancellation while launch/resume is still pending.
- Background/foreground, host disconnect, and a temporary network pause.
- Physical-controller disconnect/reconnect and on-screen controls on the same slot.
- The SDR/HDR codecs and resolutions actually used, including changes on reconnect.

The pre-cleanup source is preserved as `working-before-low-latency-cleanup`
(`db21108`). Device results determine whether this consolidated build preserves
the feel of that version; compilation and synthetic tests cannot establish it.
