# Latest Decoded Frame experiment

Enable **Latest Decoded Frame (Experimental)** at the bottom of Settings, then
reconnect. It requires iOS/tvOS 17 or newer and defaults to Off. On selects explicit VideoToolbox decoding and a
single pending decoded image. It supersedes the saved Async/Immediate preferences
and normal frame pacing for that session: compressed input always uses the serial
worker, and final uncompressed samples always use DisplayImmediately. Saved
preferences remain intact when Latest is switched Off.

**Presentation Trigger** now offers Display Sync (the original/default behavior
described below) and Immediate. See [presentation-trigger.md](presentation-trigger.md)
for the new coalesced serial presentation worker and precise age/count semantics.

The known working baseline is dc03a0c, also tagged working-immediate-presentation.
This experiment preserves the existing 120 FPS stream request and the previous
A/B/C pipelines. The rendering backend remains AVSampleBufferDisplayLayer.

## Reused compressed input

Connection.DrSubmitDecodeUnit() allocates one picture-data buffer and gathers the
Moonlight decode unit's picture entries into it. VPS/SPS/PPS entries are copied
into the existing parameter-set array. VideoDecoderRenderer builds H.264/HEVC
format descriptions from those parameter sets; the existing AV1 parser creates
the AV1 description and av1C configuration. HEVC and AV1 format extensions carry
existing mastering-display/content-light metadata. Codec VUI/format extensions
carry color primaries, transfer function, matrix and full-range information.

Existing Annex-B scanning creates length-prefixed H.264/HEVC NAL references in
CMBlockBuffers; AV1 uses the picture block directly. The picture allocation is
owned by CMBlockBuffer, then CMSampleBuffer. PTS remains presentationTimeUs from
the core. This same compressed sample is suitable for VTDecompressionSession;
the new branch adds correct NotSync/DependsOnOthers attachments and submits it
instead of enqueueing compressed input to the display layer. Moonlight's frame
handle is completed only after VT submission returns. A per-submission Objective-C
context retains the sample through output-handler lifetime, so the compressed
memory remains valid after Moonlight releases its network frame handle.

## Decoder, formats and ordering

LatestFrameDecoder owns one VTDecompressionSession on the serial video-submit
queue with public user-interactive QoS. Hardware decoding is required using the
iOS/tvOS 17+ RequireHardwareAcceleratedVideoDecoder key; older systems keep the
previous pipeline and the new selector is disabled. The
RealTime property is requested and its result logged. DecodeFrameWithOutputHandler
uses EnableAsynchronousDecompression, without EnableTemporalProcessing. Apple
permits asynchronous decode with this flag but may finish synchronously; actual
asynchronous callback flags are counted. Output callbacks do short lock/reference
operations on Apple's decoder threads without private scheduling changes.

Requested output is native bi-planar YUV with IOSurface-backed buffers: NV12 for
8-bit 4:2:0, P010 for 10-bit 4:2:0, and corresponding native bi-planar 4:4:4
formats for a negotiated 4:4:4 stream. Full/video range follows the compressed
format description. Actual output FourCC is shown in diagnostics. There is no
RGB conversion or pixel-data memcpy in the new decoded/presentation path.

The core labels only IDR versus non-IDR frames, not B-frame dependency details.
The running host's actual encoder settings cannot be determined from this source;
we do not assert that every Apollo stream has no B-frames. Existing compressed
submission order is preserved. Selection compares output PTS first, and a
monotonic submission sequence breaks ties or handles invalid PTS. An invalid
output PTS falls back to the input PTS. Temporal processing is not requested to
introduce intentional output-order buffering. A large backward input PTS jump
(over one second, including RTP rollover) starts a new output generation without
discarding compressed dependencies; old-generation callbacks are rejected.

## One slot and ownership

A short NSLock protects the pending CVPixelBuffer, PTS, sequence, completion time,
source metadata and newest-accepted watermark. A successful newer output takes
one CVPixelBufferRetain, releases the previously pending image and increments
overwrites. An older output is rejected without taking ownership. The watermark
persists after display selection, so a late callback cannot resurrect an old
frame just because the slot is empty. Slot depth is always zero or one.

On each physical CADisplayLink callback, the main thread first checks the display
layer's readiness. If not ready, it leaves the slot replaceable and does not
withhold compressed input from VT. If ready, it transfers the slot's retained
image reference, fills source color/HDR attachments, and creates the uncompressed
format description using CMVideoFormatDescriptionCreateForImageBuffer. The
sample is created using CMSampleBufferCreateReadyWithImageBuffer with the original
PTS and a sample-level DisplayImmediately attachment. The sample retains the
pixel buffer; the selection reference is released. After enqueue, the sample
reference is released. No image is selected/enqueued when the slot is empty.

The display link requests at most the real display's maximum refresh rate for
this mode. This affects presentation clock selection, never STREAM_CONFIGURATION
FPS. No display FIFO, smoothing frame or custom render backend is introduced.
AVFoundation still owns internal compositing/current-image retention. Its
documented immediate replacement behavior does not measure scanout latency or
prove the absence of every internal queue. Physical-device testing must check
for growing delay even when application slot depth stays at zero or one.

## Lifecycle and recovery

Format descriptions are compared for actual changes, so ordinary IDRs and
overwritten decoded frames do not continuously recreate the decoder. Parameter,
codec, resolution or HDR-extension changes close the old session, reject its
generation, wait for asynchronous/delayed output, invalidate/release, clear the
slot, and create a session from a new IDR's format.

Output errors coalesce an IDR request and mark the session for reset by the serial
submitter. Reset is never performed from the output callback, where waiting
could deadlock. Three repeated hardware-creation failures or consecutive decode
failures produce a logged fatal error and terminate through the existing
connection-failure callback rather than leaving a permanently frozen stream.
Normal decoded-frame overwrites and stale-output rejections never request IDRs.

Stop first prevents compressed submission, wakes and joins the existing worker,
drains the Immediate presentation worker when selected, then waits for all VT callbacks, invalidates/releases the session and clears the
slot. The main queue does no VT wait. Display-layer recovery in this mode changes
only the presentation layer and does not release the concurrently used compressed
format description. Compressed format/parameter storage is released after stop.
Existing background/disconnect/reconnect ownership rules remain in use. Old
generation/stopped-session callbacks cannot refill the slot.

## Diagnostics and tests

Approximately once per second, the overlay/log reports:

- configured FPS and Latest ON;
- VT submissions and successful decoded output per second;
- outputs reporting asynchronous decode per second;
- presentation submissions, overwritten pending images and late rejects per second;
- slot depth, outstanding VT input count and actual display callbacks per second;
- VT-reported drops, decode errors, resets and presentation-wrapper errors;
- mean submission-to-output decode latency;
- mean **Presented Frame Age**, output completion to display selection;
- display-not-ready ticks, last readiness and actual output pixel FourCC.

Presentation submissions are samples handed to AVFoundation, not measured physical
scanouts. No physical-display or API-overwritten-image count is invented. Decoder
latency and frame age are separate local measurements. In-flight input count
helps expose a decoder backlog; the mailbox cannot erase latency inside VT.

CI runs the production mailbox implementation with synthetic CVPixelBuffers.
Tests cover PTS/sequence ordering, an old output after slot consumption, concurrent
stale callbacks, reference release on overwrite/selection, input-context retention,
color/HDR mapping, idempotent stop and coalesced error recovery. These do not claim
to exercise hardware decoding, HDR visual correctness or physical presentation.

Use 120 FPS, Lowest Latency, the same host scene/codec/bitrate and reconnect for
each test:

| Test | Async | Immediate | Latest |
| --- | --- | --- | --- |
| A | Off | Off | Off |
| B | On | Off | Off |
| C | On | On | Off |
| D | Superseded | Superseded | On |

For D on a 60 Hz iPad, target approximately 120 decoded outputs/s, 60 presentation
submissions/s and 60 overwritten images/s, with slot depth 0/1. Check frame age,
VT in-flight count and decoder latency over several minutes. Test rapid reconnect,
background/foreground, host disconnect and resolution/HDR changes. Stop here and
physically compare the build before adding another renderer experiment.

References:

- [Apple: asynchronous and temporal decode flags](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessiondecodeframe(_:samplebuffer:flags:framerefcon:infoflagsout:))
- [Apple: drain asynchronous output](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessionwaitforasynchronousframes(_:))
- [Apple: image-buffer sample creation](https://developer.apple.com/documentation/coremedia/cmsamplebuffercreatereadywithimagebuffer(allocator:imagebuffer:formatdescription:sampletiming:samplebufferout:))
- [Apple: immediate image replacement](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:))
