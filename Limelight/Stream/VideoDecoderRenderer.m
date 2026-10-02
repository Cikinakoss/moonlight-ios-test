//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "StreamView.h"
#import "LatestFrameDecoder.h"
#import "LatestFramePresentationScheduler.h"

#include <stdatomic.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

NSString* const MLAsyncVideoSubmissionDefaultsKey = @"ExperimentalAsyncVideoSubmission";
NSString* const MLImmediatePresentationDefaultsKey = @"ExperimentalImmediatePresentation";
NSString* const MLLatestDecodedFrameDefaultsKey = @"ExperimentalLatestDecodedFrame";
NSString* const MLLatestPresentationImmediateDefaultsKey = @"ExperimentalLatestPresentationImmediate";

// The connection's existing compressed-frame submission function.
int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

@implementation VideoDecoderRenderer {
    StreamView* _view;
    id<ConnectionCallbacks> _callbacks;
    float _streamAspectRatio;
    
    AVSampleBufferDisplayLayer* displayLayer;
    int videoFormat;
    int frameRate;
    
    NSMutableArray *parameterSetBuffers;
    NSData *masteringDisplayColorVolume;
    NSData *contentLightLevelInfo;
    CMVideoFormatDescriptionRef formatDesc;
    
    CADisplayLink* _displayLink;
    BOOL framePacing;

    // The mode is fixed for the renderer's lifetime. Only one path consumes frames.
    BOOL _asyncSubmission;
    BOOL _immediatePresentation;
    BOOL _latestDecodedMode;
    BOOL _immediateLatestPresentation;
    LatestFrameDecoder* _latestDecoder;
    LatestFramePresentationScheduler* _latestPresentationScheduler;
    BOOL _immediateLayerShown; // Owned by the serial presentation queue.
    NSUInteger _syncPresentationRequests; // Main thread only.
    double _displayIntervalTotal;
    NSUInteger _displayIntervalSamples;
    BOOL _reportedLatestFailure;
    AVSampleBufferVideoRenderer* _sampleBufferRenderer;
    dispatch_queue_t _videoSubmitQueue;
    dispatch_group_t _videoSubmitGroup;
    NSLock* _decoderLock;
    atomic_bool _stopping;
    atomic_uint _submittedFrames;
    atomic_uint _enqueuedFrames;
    atomic_uint _backpressureDrops;
    atomic_uint _immediateEnqueues;
    atomic_int _rendererReady; // -1 = unknown; otherwise last pre-enqueue readiness.
    NSUInteger _displayCallbacks;
    CFTimeInterval _lastStatisticsTime;
    NSString* _submissionStatistics;
}

- (void)reinitializeDisplayLayer
{
    CALayer *oldLayer = displayLayer;
    
    displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    if (@available(iOS 17.0, tvOS 17.0, *)) {
        _sampleBufferRenderer = displayLayer.sampleBufferRenderer;
    }
    displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    
    // Ensure the AVSampleBufferDisplayLayer is sized to preserve the aspect ratio
    // of the video stream. We used to use AVLayerVideoGravityResizeAspect, but that
    // respects the PAR encoded in the SPS which causes our computed video-relative
    // touch location to be wrong in StreamView if the aspect ratio of the host
    // desktop doesn't match the aspect ratio of the stream.
    CGSize videoSize;
    if (_view.bounds.size.width > _view.bounds.size.height * _streamAspectRatio) {
        videoSize = CGSizeMake(_view.bounds.size.height * _streamAspectRatio, _view.bounds.size.height);
    } else {
        videoSize = CGSizeMake(_view.bounds.size.width, _view.bounds.size.width / _streamAspectRatio);
    }
    displayLayer.position = CGPointMake(CGRectGetMidX(_view.bounds), CGRectGetMidY(_view.bounds));
    displayLayer.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
    displayLayer.videoGravity = AVLayerVideoGravityResize;

    // Hide the layer until we get an IDR frame. This ensures we
    // can see the loading progress label as the stream is starting.
    displayLayer.hidden = YES;
    
    if (oldLayer != nil) {
        // Switch out the old display layer with the new one
        [_view.layer replaceSublayer:oldLayer with:displayLayer];
    }
    else {
        [_view.layer addSublayer:displayLayer];
    }
    
    if (!_latestDecodedMode && formatDesc != nil) {
        CFRelease(formatDesc);
        formatDesc = nil;
    }
}

- (id)initWithView:(StreamView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing
{
    self = [super init];
    
    _view = view;
    _callbacks = callbacks;
    _streamAspectRatio = aspectRatio;
    framePacing = useFramePacing;
    _immediatePresentation = [[NSUserDefaults standardUserDefaults] boolForKey:MLImmediatePresentationDefaultsKey];
    // Unlike CALayer mutations, this iOS 17+ API explicitly supports background enqueueing.
    if (@available(iOS 17.0, tvOS 17.0, *)) {
        _asyncSubmission = [[NSUserDefaults standardUserDefaults] boolForKey:MLAsyncVideoSubmissionDefaultsKey];
        // Requiring a hardware VT decoder is also a public iOS/tvOS 17+ API.
        _latestDecodedMode = [[NSUserDefaults standardUserDefaults] boolForKey:MLLatestDecodedFrameDefaultsKey];
    }
    if (_latestDecodedMode) {
        _latestDecoder = [[LatestFrameDecoder alloc] init];
        _immediateLatestPresentation = [[NSUserDefaults standardUserDefaults] boolForKey:MLLatestPresentationImmediateDefaultsKey];
        if (_immediateLatestPresentation) {
            dispatch_queue_t presentationQueue = dispatch_queue_create("com.moonlight.latest-presentation",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
            __weak VideoDecoderRenderer* weakSelf = self;
            _latestPresentationScheduler = [[LatestFramePresentationScheduler alloc] initWithQueue:presentationQueue
                handler:^{ [weakSelf presentLatestDecodedFrameImmediately]; }];
        }
        // This mode always decodes asynchronously and supersedes both old toggles.
        _asyncSubmission = YES;
    }
    _decoderLock = [[NSLock alloc] init];
    atomic_init(&_stopping, true);
    atomic_init(&_submittedFrames, 0);
    atomic_init(&_enqueuedFrames, 0);
    atomic_init(&_backpressureDrops, 0);
    atomic_init(&_immediateEnqueues, 0);
    atomic_init(&_rendererReady, -1);
    _videoSubmitGroup = dispatch_group_create();
    _videoSubmitQueue = dispatch_queue_create("com.moonlight.video-submit",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    
    parameterSetBuffers = [[NSMutableArray alloc] init];
    
    [self reinitializeDisplayLayer];
    
    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate
{
    self->videoFormat = videoFormat;
    self->frameRate = frameRate;
}

- (void)start
{
    if (!atomic_exchange(&_stopping, false)) {
        return;
    }
    [self performOnMainThread:^{
        self->_displayCallbacks = 0;
        self->_syncPresentationRequests = 0;
        self->_displayIntervalTotal = 0;
        self->_displayIntervalSamples = 0;
        self->_lastStatisticsTime = CACurrentMediaTime();
        atomic_store(&self->_submittedFrames, 0);
        atomic_store(&self->_enqueuedFrames, 0);
        atomic_store(&self->_backpressureDrops, 0);
        atomic_store(&self->_immediateEnqueues, 0);
        atomic_store(&self->_rendererReady, -1);
        @synchronized (self) {
            if (self->_latestDecodedMode) {
                self->_submissionStatistics = [NSString stringWithFormat:@"Latest decoded: ON; trigger: %@; requested: %d FPS",
                    self->_immediateLatestPresentation ? @"Immediate" : @"Display Sync", self->frameRate];
            }
            else {
                self->_submissionStatistics = [NSString stringWithFormat:@"Requested: %d FPS; submission: %@; immediate: %@",
                    self->frameRate, self->_asyncSubmission ? @"Async" : @"Display link", self->_immediatePresentation ? @"ON" : @"OFF"];
            }
        }
        self->_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        int displayFPS = self->_latestDecodedMode
            ? MIN(self->frameRate, (int)[UIScreen mainScreen].maximumFramesPerSecond) : self->frameRate;
        if (@available(iOS 15.0, tvOS 15.0, *)) {
            self->_displayLink.preferredFrameRateRange = CAFrameRateRangeMake(displayFPS, displayFPS, displayFPS);
        }
        else {
            self->_displayLink.preferredFramesPerSecond = displayFPS;
        }
        [self->_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    }];
    Log(LOG_I, @"Stream FPS configured: %d; async video submission: %@; immediate presentation: %@",
        frameRate, _asyncSubmission ? @"ON" : @"OFF", (_latestDecodedMode || _immediatePresentation) ? @"ON" : @"OFF");
    if (_latestDecodedMode) {
        Log(LOG_I, @"Latest Decoded Frame: ON; async decode and immediate uncompressed presentation supersede previous toggles");
        Log(LOG_I, @"Latest-frame Presentation Trigger: %@", _immediateLatestPresentation ? @"Immediate" : @"Display Sync");
    }
    if (_immediateLatestPresentation) {
        _immediateLayerShown = NO;
        [_latestPresentationScheduler start];
        __weak VideoDecoderRenderer* weakSelf = self;
        [_latestDecoder setOutputAvailableHandler:^{
            VideoDecoderRenderer* renderer = weakSelf;
            if (renderer && !atomic_load(&renderer->_stopping)) {
                [renderer->_latestPresentationScheduler requestPresentation];
            }
        }];
    }

    if (_asyncSubmission) {
        dispatch_group_async(_videoSubmitGroup, _videoSubmitQueue, ^{
            // Wait uses the core's condition variable. No timer, sleep, or spin loop.
            while (!atomic_load(&self->_stopping)) {
                VIDEO_FRAME_HANDLE handle;
                PDECODE_UNIT du;
                if (!LiWaitForNextVideoFrame(&handle, &du)) {
                    break;
                }
                @autoreleasepool {
                    // A frame acquired during shutdown still needs exactly one completion.
                    int status = atomic_load(&self->_stopping) ? DR_OK : [self submitVideoFrame:du];
                    LiCompleteVideoFrame(handle, status);
                }
            }
        });
    }
}

- (void)performOnMainThread:(dispatch_block_t)block
{
    if ([NSThread isMainThread]) {
        block();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (int)submitVideoFrame:(PDECODE_UNIT)du
{
    // HDR updates arrive on a core thread. Serialize metadata with frame construction.
    [_decoderLock lock];
    int status = DrSubmitDecodeUnit(du);
    [_decoderLock unlock];
    atomic_fetch_add(&_submittedFrames, 1);
    return status;
}

- (NSString*)getVideoSubmissionStats
{
    @synchronized (self) {
        return _submissionStatistics ?: @"";
    }
}

- (void)updateSubmissionStatistics
{
    CFTimeInterval now = CACurrentMediaTime();
    double interval = now - _lastStatisticsTime;
    if (interval < 1.0) {
        return;
    }
    double submitted = atomic_exchange(&_submittedFrames, 0) / interval;
    double enqueued = atomic_exchange(&_enqueuedFrames, 0) / interval;
    unsigned int backpressure = atomic_exchange(&_backpressureDrops, 0);
    double immediateEnqueues = atomic_exchange(&_immediateEnqueues, 0) / interval;
    int ready = atomic_load(&_rendererReady);
    NSString* readiness = ready < 0 ? @"Unknown" : (ready ? @"Ready" : @"Not ready");
    double callbacks = _displayCallbacks / interval;
    if (_latestDecodedMode) {
        NSDictionary* stats = [_latestDecoder takeStatistics];
        NSDictionary* presentationStats = [_latestPresentationScheduler takeStatistics];
        double requests = _immediateLatestPresentation ? [presentationStats[@"requests"] doubleValue] : _syncPresentationRequests;
        NSString* syncTiming = _immediateLatestPresentation ? @"N/A (Immediate)" : [NSString stringWithFormat:
            @"%.2f ms; target lead: %.2f ms", [stats[@"syncSelectionAgeMs"] doubleValue], [stats[@"targetLeadMs"] doubleValue]];
        NSString* text = [NSString stringWithFormat:
            @"Latest decoded: ON; trigger: %@; requested: %d FPS\nVT submitted/decoded: %.1f/%.1f FPS; async outputs: %.1f/s\nPresentation requests/enqueues: %.1f/%.1f per s; coalesced: %.1f/s\nOverwritten: %.1f/s; late rejected: %.1f/s; stale candidates: %.1f/s\nSlot depth: %@; presentation request depth: %d; VT in flight: %@\nDisplay callbacks: %.1f/s; link interval: %.2f ms\nVT drops/errors/resets: %@/%@/%@; presentation errors: %@\nDecode latency: %.2f ms; Presented Frame Age (selection): %.2f ms\nDecode Output -> Enqueue Age: %.2f ms\nDisplay Sync selection age: %@\nDisplay not-ready checks: %u; readiness: %@; pixel format: %08x",
            _immediateLatestPresentation ? @"Immediate" : @"Display Sync", frameRate,
            [stats[@"submitted"] doubleValue] / interval, [stats[@"decoded"] doubleValue] / interval,
            [stats[@"asyncOutputs"] doubleValue] / interval, requests / interval,
            [stats[@"enqueues"] doubleValue] / interval, [presentationStats[@"coalesced"] doubleValue] / interval,
            [stats[@"overwritten"] doubleValue] / interval, [stats[@"late"] doubleValue] / interval,
            [stats[@"staleCandidates"] doubleValue] / interval, stats[@"slotDepth"],
            [presentationStats[@"outstanding"] intValue], stats[@"inFlight"], callbacks,
            _displayIntervalSamples ? 1000 * _displayIntervalTotal / _displayIntervalSamples : 0,
            stats[@"vtDropped"], stats[@"errors"],
            stats[@"resets"], stats[@"presentationErrors"], [stats[@"decodeMs"] doubleValue],
            [stats[@"enqueueSelectionAgeMs"] doubleValue], [stats[@"enqueueAgeMs"] doubleValue],
            syncTiming, backpressure, readiness, [stats[@"pixelFormat"] unsignedIntValue]];
        @synchronized (self) { _submissionStatistics = text; }
        Log(LOG_I, @"%@", text);
        _displayCallbacks = 0;
        _syncPresentationRequests = 0;
        _displayIntervalTotal = 0;
        _displayIntervalSamples = 0;
        _lastStatisticsTime = now;
        return;
    }
    @synchronized (self) {
        _submissionStatistics = [NSString stringWithFormat:
            @"Requested: %d FPS; submission: %@; immediate: %@\nSubmitted/enqueued: %.1f/%.1f FPS; display callbacks: %.1f/s\nRenderer backpressure drops: %u; readiness (last check): %@\nImmediate-tagged enqueues: %.1f/s",
            frameRate, _asyncSubmission ? @"Async" : @"Display link", _immediatePresentation ? @"ON" : @"OFF",
            submitted, enqueued, callbacks, backpressure, readiness, immediateEnqueues];
    }
    Log(LOG_I, @"Video submission (%@): requested=%d FPS, immediate=%@, submitted=%.1f/s, enqueued=%.1f/s, immediate-tagged=%.1f/s, display callbacks=%.1f/s, backpressure drops=%u, readiness (last check)=%@",
        _asyncSubmission ? @"Async" : @"Display link", frameRate, _immediatePresentation ? @"ON" : @"OFF",
        submitted, enqueued, immediateEnqueues, callbacks, backpressure, readiness);
    _displayCallbacks = 0;
    _lastStatisticsTime = now;
}

- (void)displayLinkCallback:(CADisplayLink *)sender
{
    if (atomic_load(&_stopping)) {
        return;
    }
    _displayCallbacks++;
    if (_latestDecodedMode && sender.targetTimestamp > sender.timestamp) {
        _displayIntervalTotal += sender.targetTimestamp - sender.timestamp;
        _displayIntervalSamples++;
    }
    [self updateSubmissionStatistics];
    if (_latestDecodedMode) {
        if (!_immediateLatestPresentation) {
            _syncPresentationRequests++;
            [self presentLatestDecodedFrameForDisplayTarget:sender.targetTimestamp];
        }
        return;
    }
    if (_asyncSubmission) {
        // Keep the display link for measurement, never consume frames in this mode.
        return;
    }
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    
    while (!atomic_load(&_stopping) && LiPollNextVideoFrame(&handle, &du)) {
        LiCompleteVideoFrame(handle, [self submitVideoFrame:du]);
        
        if (framePacing) {
            // Calculate the actual display refresh rate
            double displayRefreshRate = 1 / (_displayLink.targetTimestamp - _displayLink.timestamp);
            
            // Only pace frames if the display refresh rate is >= 90% of our stream frame rate.
            // Battery saver, accessibility settings, or device thermals can cause the actual
            // refresh rate of the display to drop below the physical maximum.
            if (displayRefreshRate >= frameRate * 0.9f) {
                // Keep one pending frame to smooth out gaps due to
                // network jitter at the cost of 1 frame of latency
                if (LiGetPendingVideoFrames() == 1) {
                    break;
                }
            }
        }
    }
}

- (void)stop
{
    if (atomic_exchange(&_stopping, true)) {
        return;
    }
    [_latestPresentationScheduler cancel];
    if (_asyncSubmission) {
        // DrStop is called by the core on the connection/termination operation,
        // never the main thread. The main queue stays free for layer recovery.
        NSAssert(![NSThread isMainThread], @"Async video shutdown must run off the main thread");
        LiWakeWaitForVideoFrame();
        dispatch_group_wait(_videoSubmitGroup, DISPATCH_TIME_FOREVER);
    }
    if (_latestDecodedMode) {
        // Close/drain presentation before decoder teardown. Callbacks can only
        // signal the closed coalescer, and the main queue stays free for its work.
        [_latestPresentationScheduler stop];
        // No further compressed submissions; drain callbacks before releasing the slot.
        [_latestDecoder stop];
        [_decoderLock lock];
        if (formatDesc) {
            CFRelease(formatDesc);
            formatDesc = NULL;
        }
        [parameterSetBuffers removeAllObjects];
        [_decoderLock unlock];
    }
    // Stop returns only after the consumer and its main-thread layer work finish.
    // The core calls DrStop BEFORE shutting down/destroying its decode-unit queue.
    [self performOnMainThread:^{
        [self->_displayLink invalidate];
        self->_displayLink = nil;
    }];
}

- (void)presentLatestDecodedFrameForDisplayTarget:(CFTimeInterval)displayTarget
{
    // Main thread only. Layer failure recovery does not touch the VT format/session.
    if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        Log(LOG_E, @"Latest-frame presentation layer failed: %@", displayLayer.error);
        [self reinitializeDisplayLayer];
    }
    BOOL ready = displayLayer.readyForMoreMediaData;
    atomic_store(&_rendererReady, ready);
    if (!ready) {
        // Leave the one slot replaceable; never withhold compressed input from VT.
        atomic_fetch_add(&_backpressureDrops, 1);
        return;
    }
    CFTimeInterval selectedAt = CACurrentMediaTime();
    CFTimeInterval decodedAt = 0;
    CMSampleBufferRef sample = [_latestDecoder copyPresentationSampleAtTime:selectedAt decodedAt:&decodedAt sequence:NULL generation:NULL];
    if (!sample) {
        return;
    }
    [displayLayer enqueueSampleBuffer:sample];
    CFTimeInterval enqueueAt = CACurrentMediaTime();
    [_latestDecoder recordEnqueueAt:enqueueAt decodedAt:decodedAt selectedAt:selectedAt displayTarget:displayTarget];
    CFRelease(sample);
    atomic_fetch_add(&_enqueuedFrames, 1);
    if (displayLayer.hidden) {
        displayLayer.hidden = NO;
        [_callbacks videoContentShown];
    }
}

- (void)presentLatestDecodedFrameImmediately
{
    // Sole consumer on the dedicated serial queue. No layer access on VT threads.
    if (atomic_load(&_stopping)) {
        return;
    }
    if (@available(iOS 17.0, tvOS 17.0, *)) {
        AVSampleBufferVideoRenderer* renderer = _sampleBufferRenderer;
        if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            Log(LOG_E, @"Immediate latest-frame renderer failed: %@", renderer.error);
            [self performOnMainThread:^{
                if (!atomic_load(&self->_stopping)) { [self reinitializeDisplayLayer]; }
            }];
            if (atomic_load(&_stopping)) { return; }
            renderer = _sampleBufferRenderer;
            _immediateLayerShown = NO;
        }
        BOOL ready = renderer.readyForMoreMediaData;
        atomic_store(&_rendererReady, ready);
        if (!ready) {
            // Keep the slot replaceable. A new decoded output requests a retry;
            // do not spin, queue frame payloads, or gate retries on CADisplayLink.
            atomic_fetch_add(&_backpressureDrops, 1);
            return;
        }
        CFTimeInterval selectedAt = CACurrentMediaTime();
        CFTimeInterval decodedAt = 0;
        uint64_t sequence = 0, generation = 0;
        CMSampleBufferRef sample = [_latestDecoder copyPresentationSampleAtTime:selectedAt decodedAt:&decodedAt
            sequence:&sequence generation:&generation];
        if (!sample) { return; }
        // New output during wrapping signals another coalesced pass. Avoid enqueueing
        // a superseded candidate; preserve the shared PTS/sequence freshness rule.
        if (atomic_load(&_stopping) || ![_latestDecoder isPresentationCurrentForSequence:sequence generation:generation]) {
            CFRelease(sample);
            return;
        }
        [renderer enqueueSampleBuffer:sample]; // Apple's background-safe 17+ API.
        CFTimeInterval enqueueAt = CACurrentMediaTime();
        [_latestDecoder recordEnqueueAt:enqueueAt decodedAt:decodedAt selectedAt:selectedAt displayTarget:0];
        CFRelease(sample);
        atomic_fetch_add(&_enqueuedFrames, 1);
        if (!_immediateLayerShown) {
            // Only first-image visibility and layer recreation need the main queue.
            // Neither captures a frame or builds per-frame main-queue work.
            [self performOnMainThread:^{
                if (!atomic_load(&self->_stopping) && self->displayLayer.hidden) {
                    self->displayLayer.hidden = NO;
                    [self->_callbacks videoContentShown];
                }
            }];
            _immediateLayerShown = YES;
        }
    }
}

#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (void)updateAnnexBBufferForRange:(CMBlockBufferRef)frameBuffer dataBlock:(CMBlockBufferRef)dataBuffer offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(frameBuffer);
    
    // Append a 4 byte buffer to the frame block for the length prefix
    status = CMBlockBufferAppendMemoryBlock(frameBuffer, NULL,
                                            NAL_LENGTH_PREFIX_SIZE,
                                            kCFAllocatorDefault, NULL, 0,
                                            NAL_LENGTH_PREFIX_SIZE, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
        return;
    }
    
    // Write the length prefix to the new buffer
    const int dataLength = nalLength - NALU_START_PREFIX_SIZE;
    const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
        (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
    status = CMBlockBufferReplaceDataBytes(lengthBytes, frameBuffer,
                                           oldOffset, NAL_LENGTH_PREFIX_SIZE);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
        return;
    }
    
    // Attach the data buffer to the frame buffer by reference
    status = CMBlockBufferAppendBufferReference(frameBuffer, dataBuffer, offset + NALU_START_PREFIX_SIZE, dataLength, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
        return;
    }
}

- (NSData*)getAv1CodecConfigurationBox:(NSData*)frameData  {
    AVIOContext* ioctx = NULL;
    int err;
    
    err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t*)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
        // Fall-through to close and free buffer
    }
    
    // Close the dynbuf and get the underlying buffer back (which we must free)
    uint8_t* av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);
    
    Log(LOG_I, @"av1C block is %d bytes", av1cBufLen);
    
    // Only return data if ff_isom_write_av1c() was successful
    NSData* data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }
    else {
        data = nil;
    }
    
    av_free(av1cBuf);
    return data;
}

// Much of this logic comes from Chrome
- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData*)frameData {
    NSMutableDictionary* extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext* cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return nil;
    }
    
    AVPacket avPacket = {};
    avPacket.data = (uint8_t*)frameData.bytes;
    avPacket.size = (int)frameData.length;
    
    // Read the sequence header OBU
    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }
    
#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (__bridge NSString*)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");
    
    // We use the value for YUV without alpha, same as Chrome
    // https://developer.apple.com/library/archive/qa/qa1183/_index.html
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);
    
    CodedBitstreamAV1Context* bitstreamCtx = (CodedBitstreamAV1Context*)cbsCtx->priv_data;
    AV1RawSequenceHeader* seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame!");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }
    
    switch (seqHeader->color_config.color_primaries) {
        case 1: // CP_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;
            
        case 6: // CP_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;
            
        case 9: // CP_BT_2020
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;
            
        default:
            Log(LOG_W, @"Unsupported color_primaries value: %d", seqHeader->color_config.color_primaries);
            break;
    }
    
    switch (seqHeader->color_config.transfer_characteristics) {
        case 1: // TC_BT_709
        case 6: // TC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;
            
        case 7: // TC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;
            
        case 8: // TC_LINEAR
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_Linear);
            break;
            
        case 14: // TC_BT_2020_10_BIT
        case 15: // TC_BT_2020_12_BIT
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;
            
        case 16: // TC_SMPTE_2084
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;
            
        case 17: // TC_HLG
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;
            
        default:
            Log(LOG_W, @"Unsupported transfer_characteristics value: %d", seqHeader->color_config.transfer_characteristics);
            break;
    }
    
    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: // MC_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;
            
        case 6: // MC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;
            
        case 7: // MC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;
            
        case 9: // MC_BT_2020_NCL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;
            
        default:
            Log(LOG_W, @"Unsupported matrix_coefficients value: %d", seqHeader->color_config.matrix_coefficients);
            break;
    }
    
    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));
    
    // Progressive content
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));
    
    switch (seqHeader->color_config.chroma_sample_position) {
        case 1: // CSP_VERTICAL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_Left);
            break;
            
        case 2: // CSP_COLOCATED
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_TopLeft);
            break;
            
        default:
            Log(LOG_W, @"Unsupported chroma_sample_position value: %d", seqHeader->color_config.chroma_sample_position);
            break;
    }
    
    if (contentLightLevelInfo) {
        SET_EXTENSION(kCMFormatDescriptionExtension_ContentLightLevelInfo, contentLightLevelInfo);
    }
    
    if (masteringDisplayColorVolume) {
        SET_EXTENSION(kCMFormatDescriptionExtension_MasteringDisplayColorVolume, masteringDisplayColorVolume);
    }
    
    // Referenced the VP9 code in Chrome that performs a similar function
    // https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/mac/vt_config_util.mm;drc=977dc02c431b4979e34c7792bc3d646f649dacb4;l=155
    extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
    @{
        @"av1C" : [self getAv1CodecConfigurationBox:frameData],
    };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);
    
#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION
    
    // AV1 doesn't have a special format description function like H.264 and HEVC have, so we just use the generic one
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width, bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &formatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }
    
    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du
{
    OSStatus status;
    
    // Construct a new format description object each time we receive an IDR frame
    if (du->frameType == FRAME_TYPE_IDR) {
        if (bufferType != BUFFER_TYPE_PICDATA) {
            if (bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS) {
                // Add new parameter set into the parameter set array
                int startLen = data[2] == 0x01 ? 3 : 4;
                [parameterSetBuffers addObject:[NSData dataWithBytes:&data[startLen] length:length - startLen]];
            }
            
            // Data is NOT to be freed here. It's a direct usage of the caller's buffer.
            
            // No frame data to submit for these NALUs
            return DR_OK;
        }
        
        // Create the new format description when we get the first picture data buffer of an IDR frame.
        // This is the only way we know that there is no more CSD for this frame.
        //
        // NB: This logic depends on the fact that we submit all picture data in one buffer!
        
        // Free the old format description
        if (formatDesc != NULL) {
            CFRelease(formatDesc);
            formatDesc = NULL;
        }
        
        if (videoFormat & VIDEO_FORMAT_MASK_H264) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }
            
            Log(LOG_I, @"Constructing new H264 format description");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &formatDesc);
            if (status != noErr) {
                Log(LOG_E, @"Failed to create H264 format description: %d", (int)status);
                formatDesc = NULL;
            }
            
            // Free parameter set buffers after submission
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }
            
            Log(LOG_I, @"Constructing new HEVC format description");
            
            NSMutableDictionary* videoFormatParams = [[NSMutableDictionary alloc] init];
            
            if (contentLightLevelInfo) {
                [videoFormatParams setObject:contentLightLevelInfo forKey:(__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo];
            }
            
            if (masteringDisplayColorVolume) {
                [videoFormatParams setObject:masteringDisplayColorVolume forKey:(__bridge NSString*)kCMFormatDescriptionExtension_MasteringDisplayColorVolume];
            }
            
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         (__bridge CFDictionaryRef)videoFormatParams,
                                                                         &formatDesc);
            
            if (status != noErr) {
                Log(LOG_E, @"Failed to create HEVC format description: %d", (int)status);
                formatDesc = NULL;
            }
            
            // Free parameter set buffers after submission
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
            NSData* fullFrameData = [NSData dataWithBytesNoCopy:data length:length freeWhenDone:NO];
            
            Log(LOG_I, @"Constructing new AV1 format description");
            formatDesc = [self createAV1FormatDescriptionForIDRFrame:fullFrameData];
        }
        else {
            // Unsupported codec!
            abort();
        }
    }
    
    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_NEED_IDR;
    }
    
    if (!_latestDecodedMode) {
        // Check for previous decoder errors before doing anything
        AVQueuedSampleBufferRenderingStatus renderingStatus = AVQueuedSampleBufferRenderingStatusUnknown;
        NSError* renderingError = nil;
        if (_asyncSubmission) {
            if (@available(iOS 17.0, tvOS 17.0, *)) {
                renderingStatus = _sampleBufferRenderer.status;
                renderingError = _sampleBufferRenderer.error;
            }
        }
        else {
            renderingStatus = displayLayer.status;
            renderingError = displayLayer.error;
        }
        if (renderingStatus == AVQueuedSampleBufferRenderingStatusFailed) {
            atomic_store(&_rendererReady, -1);
            Log(LOG_E, @"Display layer rendering failed: %@", renderingError);
        
            // Layer-tree and view changes stay on the main thread. The sole submitter
            // waits for recreation, so the old renderer cannot receive another sample.
            [self performOnMainThread:^{ [self reinitializeDisplayLayer]; }];
        
            // Request an IDR frame to initialize the new decoder
            free(data);
            return DR_NEED_IDR;
        }

        if (_asyncSubmission) {
            if (@available(iOS 17.0, tvOS 17.0, *)) {
                BOOL ready = _sampleBufferRenderer.readyForMoreMediaData;
                atomic_store(&_rendererReady, ready);
                if (!ready) {
                    // Never build an unbounded AVFoundation queue. Dropping compressed
                    // reference frames needs the core's existing IDR recovery path.
                    atomic_fetch_add(&_backpressureDrops, 1);
                    free(data);
                    return DR_NEED_IDR;
                }
            }
        }
        else {
            atomic_store(&_rendererReady, displayLayer.readyForMoreMediaData);
        }
    }
    
    // Now we're decoding actual frame data here
    CMBlockBufferRef frameBlockBuffer;
    CMBlockBufferRef dataBlockBuffer;
    
    status = CMBlockBufferCreateWithMemoryBlock(NULL, data, length, kCFAllocatorDefault, NULL, 0, length, 0, &dataBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        free(data);
        return DR_NEED_IDR;
    }
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    
    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &frameBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return DR_NEED_IDR;
    }
    
    // H.264 and HEVC formats require NAL prefix fixups from Annex B to length-delimited
    if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        int lastOffset = -1;
        for (int i = 0; i < length - NALU_START_PREFIX_SIZE; i++) {
            // Search for a NALU
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                // It's the start of a new NALU
                if (lastOffset != -1) {
                    // We've seen a start before this so enqueue that NALU
                    [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:i - lastOffset];
                }
                
                lastOffset = i;
            }
        }
        
        if (lastOffset != -1) {
            // Enqueue the remaining data
            [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:length - lastOffset];
        }
    }
    else {
        // For formats that require no length-changing fixups, just append a reference to the raw data block
        status = CMBlockBufferAppendBufferReference(frameBlockBuffer, dataBlockBuffer, 0, length, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
            return DR_NEED_IDR;
        }
    }
        
    CMSampleBufferRef sampleBuffer;
    
    CMSampleTimingInfo sampleTiming = {kCMTimeInvalid, CMTimeMake(du->presentationTimeUs, 1000000), kCMTimeInvalid};
    
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  formatDesc, 1, 1,
                                  &sampleTiming, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        return DR_NEED_IDR;
    }

    if (_latestDecodedMode) {
        // Reuse the existing codec/sample preparation. VT needs correct sync flags;
        // inter frames must retain their compressed reference dependencies.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        int result = DR_NEED_IDR;
        if (attachments && CFArrayGetCount(attachments) == 1) {
            CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync,
                du->frameType == FRAME_TYPE_IDR ? kCFBooleanFalse : kCFBooleanTrue);
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers,
                du->frameType == FRAME_TYPE_IDR ? kCFBooleanFalse : kCFBooleanTrue);
            result = [_latestDecoder submitSampleBuffer:sampleBuffer videoFormat:videoFormat isIDR:du->frameType == FRAME_TYPE_IDR];
        }
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        CFRelease(sampleBuffer);
        NSString* fatal = [_latestDecoder fatalError];
        if (fatal && !_reportedLatestFailure) {
            _reportedLatestFailure = YES;
            Log(LOG_E, @"%@", fatal);
            // Existing connection failure callback stops the stream off this worker.
            [_callbacks connectionTerminated:-1];
        }
        return result;
    }

    if (_immediatePresentation) {
        // Keep PTS and compressed decode ordering intact. This sample-level key
        // asks AVFoundation to supersede older images instead of waiting for PTS.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        if (attachments == NULL || CFArrayGetCount(attachments) != 1) {
            Log(LOG_E, @"Unable to create immediate presentation sample attachment");
            CFRelease(dataBlockBuffer);
            CFRelease(frameBlockBuffer);
            CFRelease(sampleBuffer);
            return DR_NEED_IDR;
        }
        CFMutableDictionaryRef sampleAttachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(sampleAttachments, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    // Enqueue the next frame
    if (_asyncSubmission) {
        if (@available(iOS 17.0, tvOS 17.0, *)) {
            [_sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        }
    }
    else {
        [displayLayer enqueueSampleBuffer:sampleBuffer];
    }
    atomic_fetch_add(&_enqueuedFrames, 1);
    if (_immediatePresentation) {
        // This counts tagged enqueues, not decoded or physically displayed frames.
        atomic_fetch_add(&_immediateEnqueues, 1);
    }
    
    if (du->frameType == FRAME_TYPE_IDR) {
        // Ensure the layer is visible now
        [self performOnMainThread:^{
            self->displayLayer.hidden = NO;
            // Tell our parent VC to hide the progress indicator.
            [self->_callbacks videoContentShown];
        }];
    }
    
    // Dereference the buffers
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);
    
    return DR_OK;
}

- (void)setHdrMode:(BOOL)enabled {
    [_decoderLock lock];
    SS_HDR_METADATA hdrMetadata;
    
    BOOL hasMetadata = enabled && LiGetHdrMetadata(&hdrMetadata);
    BOOL metadataChanged = NO;
    
    if (hasMetadata && hdrMetadata.displayPrimaries[0].x != 0 && hdrMetadata.maxDisplayLuminance != 0) {
        // This data is all in big-endian
        struct {
          vector_ushort2 primaries[3];
          vector_ushort2 white_point;
          uint32_t luminance_max;
          uint32_t luminance_min;
        } __attribute__((packed, aligned(4))) mdcv;

        // mdcv is in GBR order while SS_HDR_METADATA is in RGB order
        mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata.displayPrimaries[1].x);
        mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata.displayPrimaries[1].y);
        mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata.displayPrimaries[2].x);
        mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata.displayPrimaries[2].y);
        mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata.displayPrimaries[0].x);
        mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata.displayPrimaries[0].y);

        mdcv.white_point.x = __builtin_bswap16(hdrMetadata.whitePoint.x);
        mdcv.white_point.y = __builtin_bswap16(hdrMetadata.whitePoint.y);

        // These luminance values are in 10000ths of a nit
        mdcv.luminance_max = __builtin_bswap32((uint32_t)hdrMetadata.maxDisplayLuminance * 10000);
        mdcv.luminance_min = __builtin_bswap32(hdrMetadata.minDisplayLuminance);

        NSData* newMdcv = [NSData dataWithBytes:&mdcv length:sizeof(mdcv)];
        if (masteringDisplayColorVolume == nil || ![newMdcv isEqualToData:masteringDisplayColorVolume]) {
            masteringDisplayColorVolume = newMdcv;
            metadataChanged = YES;
        }
    }
    else if (masteringDisplayColorVolume != nil) {
        masteringDisplayColorVolume = nil;
        metadataChanged = YES;
    }
    
    if (hasMetadata && hdrMetadata.maxContentLightLevel != 0 && hdrMetadata.maxFrameAverageLightLevel != 0) {
        // This data is all in big-endian
        struct {
            uint16_t max_content_light_level;
            uint16_t max_frame_average_light_level;
        } __attribute__((packed, aligned(2))) cll;

        cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
        cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

        NSData* newCll = [NSData dataWithBytes:&cll length:sizeof(cll)];
        if (contentLightLevelInfo == nil || ![newCll isEqualToData:contentLightLevelInfo]) {
            contentLightLevelInfo = newCll;
            metadataChanged = YES;
        }
    }
    else if (contentLightLevelInfo != nil) {
        contentLightLevelInfo = nil;
        metadataChanged = YES;
    }
    
    // If the metadata changed, request an IDR frame to re-create the CMVideoFormatDescription
    if (metadataChanged) {
        LiRequestIdrFrame();
    }
    [_decoderLock unlock];
}

@end
