#import "LatestFrameDecoder.h"
#import <QuartzCore/QuartzCore.h>
#include "Limelight.h"
#include <stdatomic.h>

// Retain input through async completion, including synchronous error/drop paths.
@interface LatestDecodeContext : NSObject {
@public
    CMSampleBufferRef sample;
    uint64_t sequence;
    uint64_t generation;
    CFTimeInterval submittedAt;
    NSDictionary* metadata;
    atomic_bool handled;
}
- (id)initWithSample:(CMSampleBufferRef)input;
@end

@implementation LatestDecodeContext
- (id)initWithSample:(CMSampleBufferRef)input {
    self = [super init];
    sample = (CMSampleBufferRef)CFRetain(input);
    atomic_init(&handled, false);
    return self;
}
- (void)dealloc {
    CFRelease(sample);
}
@end

@implementation LatestFrameDecoder {
    // Session/input state belongs exclusively to the serial submitter.
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _sessionFormat;
    uint64_t _nextSequence;
    CMTime _lastInputPTS;
    NSUInteger _creationFailures;
    NSUInteger _consecutiveDecodeErrors; // Protected by _slotLock.

    // Output callbacks, display selection and diagnostics share this short lock.
    NSLock* _slotLock;
    BOOL _acceptingOutputs;
    BOOL _needsReset;
    NSString* _fatalError;
    uint64_t _generation;
    CVPixelBufferRef _pendingImage;
    CMTime _pendingPTS;
    uint64_t _pendingSequence;
    CFTimeInterval _pendingReadyAt;
    NSDictionary* _pendingMetadata;
    CMTime _newestPTS;
    uint64_t _newestSequence; // Persists after selection, so late output stays stale.

    uint64_t _submitted, _decoded, _overwritten, _presented, _late, _vtDropped;
    uint64_t _asyncOutputs, _errors, _resets, _presentationErrors;
    NSUInteger _inFlight;
    double _decodeTimeTotal, _ageTotal;
    OSType _outputPixelFormat;
    dispatch_block_t _outputAvailableHandler;
    uint64_t _enqueues, _syncEnqueues, _staleCandidates;
    double _enqueueAgeTotal, _enqueueSelectionAgeTotal, _syncAgeTotal, _targetLeadTotal;
}

- (id)init {
    self = [super init];
    _slotLock = [[NSLock alloc] init];
    _acceptingOutputs = YES;
    _generation = 1;
    _lastInputPTS = _newestPTS = kCMTimeInvalid;
    return self;
}

- (void)dealloc {
    // stop() must drain the session before the last owner releases this object.
    NSAssert(_session == NULL, @"Latest-frame decoder released before stop");
    if (_pendingImage) {
        CVPixelBufferRelease(_pendingImage);
    }
}

// Caller holds _slotLock. Only decoded images are discarded here.
- (void)clearPendingImage {
    if (_pendingImage) {
        CVPixelBufferRelease(_pendingImage);
        _pendingImage = NULL;
    }
    _pendingMetadata = nil;
}

// Never called from an output callback or while holding _slotLock.
- (void)closeSession {
    [_slotLock lock];
    _acceptingOutputs = NO;
    _generation++;
    [_slotLock unlock];
    if (_session) {
        // This also finishes delayed frames. Callbacks need no main-thread work.
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_sessionFormat) {
        CFRelease(_sessionFormat);
        _sessionFormat = NULL;
    }
    [_slotLock lock];
    [self clearPendingImage];
    _newestPTS = kCMTimeInvalid;
    _newestSequence = 0;
    _inFlight = 0;
    [_slotLock unlock];
    _lastInputPTS = kCMTimeInvalid;
}

- (void)stop {
    [self closeSession];
    [self setOutputAvailableHandler:nil];
}

- (void)setOutputAvailableHandler:(dispatch_block_t)handler {
    [_slotLock lock];
    _outputAvailableHandler = [handler copy];
    [_slotLock unlock];
}

- (NSString*)fatalError {
    [_slotLock lock];
    NSString* result = _fatalError;
    [_slotLock unlock];
    return result;
}

- (NSDictionary*)imageMetadataFromFormat:(CMVideoFormatDescriptionRef)format {
    NSDictionary* extensions = (__bridge NSDictionary*)CMFormatDescriptionGetExtensions(format);
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    const CFStringRef sourceKeys[] = {
        kCMFormatDescriptionExtension_ColorPrimaries,
        kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix,
        kCMFormatDescriptionExtension_ChromaLocationTopField,
        kCMFormatDescriptionExtension_ChromaLocationBottomField,
        kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
        kCMFormatDescriptionExtension_ContentLightLevelInfo
    };
    const CFStringRef imageKeys[] = {
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
        kCVImageBufferMasteringDisplayColorVolumeKey,
        kCVImageBufferContentLightLevelInfoKey
    };
    for (size_t i = 0; i < sizeof(sourceKeys) / sizeof(sourceKeys[0]); i++) {
        id value = extensions[(__bridge NSString*)sourceKeys[i]];
        if (value) {
            result[(__bridge NSString*)imageKeys[i]] = value;
        }
    }
    return result;
}

- (OSStatus)createSessionForFormat:(CMVideoFormatDescriptionRef)format videoFormat:(int)videoFormat {
    NSDictionary* extensions = (__bridge NSDictionary*)CMFormatDescriptionGetExtensions(format);
    BOOL fullRange = [extensions[(__bridge NSString*)kCMFormatDescriptionExtension_FullRangeVideo] boolValue];
    BOOL tenBit = (videoFormat & VIDEO_FORMAT_MASK_10BIT) != 0;
    OSType pixelFormat = tenBit
        ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (videoFormat & VIDEO_FORMAT_MASK_YUV444) {
        pixelFormat = tenBit
            ? (fullRange ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange);
    }
    NSDictionary* specification;
    if (@available(iOS 17.0, tvOS 17.0, *)) {
        specification = @{
            (__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES
        };
    }
    else {
        return kVTPropertyNotSupportedErr;
    }
    NSDictionary* attributes = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, format,
        (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)attributes, NULL, &_session);
    if (status != noErr) {
        return status;
    }
    _sessionFormat = (CMVideoFormatDescriptionRef)CFRetain(format);
    OSStatus realtime = VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    NSLog(@"Latest decoder created: pixel format=%08x; RealTime status=%d", (unsigned)pixelFormat, (int)realtime);
    [_slotLock lock];
    _acceptingOutputs = YES;
    _needsReset = NO;
    _resets++;
    [_slotLock unlock];
    return noErr;
}

// Also used by focused tests with synthetic decoded images, without a hardware codec.
- (void)receiveImage:(CVPixelBufferRef)image pts:(CMTime)pts sequence:(uint64_t)sequence
         generation:(uint64_t)generation metadata:(NSDictionary*)metadata
        submittedAt:(CFTimeInterval)submittedAt status:(OSStatus)status flags:(VTDecodeInfoFlags)flags {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL requestIDR = NO;
    dispatch_block_t notify = nil;
    [_slotLock lock];
    if (_inFlight > 0) {
        _inFlight--;
    }
    if (flags & kVTDecodeInfo_FrameDropped) {
        _vtDropped++;
    }
    if (status != noErr) {
        _errors++;
        if (_acceptingOutputs && generation == _generation && !_needsReset) {
            _needsReset = YES;
            requestIDR = YES;
            if (++_consecutiveDecodeErrors >= 3) {
                _fatalError = @"VideoToolbox repeatedly failed to decode. Disable Latest Decoded Frame to compare the previous renderer.";
            }
        }
    }
    else if (image && !(flags & kVTDecodeInfo_FrameDropped)) {
        _decoded++;
        _decodeTimeTotal += MAX(0, now - submittedAt);
        _outputPixelFormat = CVPixelBufferGetPixelFormatType(image);
        if (flags & kVTDecodeInfo_Asynchronous) {
            _asyncOutputs++;
        }
        BOOL newer = _newestSequence == 0;
        if (!newer) {
            if (CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(_newestPTS)) {
                int comparison = CMTimeCompare(pts, _newestPTS);
                newer = comparison > 0 || (comparison == 0 && sequence > _newestSequence);
            }
            else {
                newer = sequence > _newestSequence;
            }
        }
        if (_acceptingOutputs && !_needsReset && generation == _generation && newer) {
            _consecutiveDecodeErrors = 0;
            if (_pendingImage) {
                _overwritten++;
            }
            [self clearPendingImage];
            _pendingImage = CVPixelBufferRetain(image);
            _pendingPTS = _newestPTS = pts;
            _pendingSequence = _newestSequence = sequence;
            _pendingReadyAt = now;
            _pendingMetadata = metadata;
            notify = _outputAvailableHandler;
        }
        else {
            _late++;
        }
    }
    [_slotLock unlock];
    if (notify) {
        notify(); // Never wait for presentation on a VideoToolbox callback thread.
    }
    if (requestIDR) {
        NSLog(@"Latest decoder output failed: %d; requesting IDR and reset", (int)status);
        LiRequestIdrFrame();
    }
}

- (int)submitSampleBuffer:(CMSampleBufferRef)sample videoFormat:(int)videoFormat isIDR:(BOOL)isIDR {
    [_slotLock lock];
    BOOL reset = _needsReset;
    BOOL fatal = _fatalError != nil;
    [_slotLock unlock];
    if (fatal) {
        return DR_NEED_IDR;
    }
    CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (reset || (_sessionFormat && !CMFormatDescriptionEqual(_sessionFormat, format))) {
        [self closeSession];
    }
    if (!_session) {
        if (!isIDR) {
            return DR_NEED_IDR;
        }
        OSStatus creation = [self createSessionForFormat:format videoFormat:videoFormat];
        if (creation != noErr) {
            NSLog(@"Latest decoder creation failed: %d", (int)creation);
            [_slotLock lock];
            _errors++;
            if (++_creationFailures >= 3) {
                _fatalError = [NSString stringWithFormat:@"VideoToolbox cannot create the latest-frame hardware decoder (%d). Disable Latest Decoded Frame to use the previous renderer.", (int)creation];
            }
            [_slotLock unlock];
            return DR_NEED_IDR;
        }
        _creationFailures = 0;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    LatestDecodeContext* context = [[LatestDecodeContext alloc] initWithSample:sample];
    context->sequence = ++_nextSequence;
    context->submittedAt = CACurrentMediaTime();
    context->metadata = [self imageMetadataFromFormat:format];
    [_slotLock lock];
    // Detect large timeline discontinuities (including RTP rollover), not normal
    // small B-frame PTS reordering. Old-epoch callbacks cannot revive stale images.
    if (CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(_lastInputPTS)
        && CMTimeCompare(CMTimeAdd(pts, CMTimeMake(1, 1)), _lastInputPTS) < 0) {
        _generation++;
        [self clearPendingImage];
        _newestPTS = kCMTimeInvalid;
        _newestSequence = 0;
    }
    _lastInputPTS = pts;
    context->generation = _generation;
    _submitted++;
    _inFlight++;
    [_slotLock unlock];
    VTDecodeInfoFlags info = 0;
    OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(_session, sample,
        kVTDecodeFrame_EnableAsynchronousDecompression, &info,
        ^(OSStatus outputStatus, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime outputPTS, CMTime duration) {
            @autoreleasepool {
                // One compressed sample per call; claim its outcome exactly once.
                if (!atomic_exchange(&context->handled, true)) {
                    [self receiveImage:image pts:CMTIME_IS_NUMERIC(outputPTS) ? outputPTS : pts sequence:context->sequence generation:context->generation
                        metadata:context->metadata submittedAt:context->submittedAt status:outputStatus flags:flags];
                }
            }
        });
    if (status != noErr || (info & kVTDecodeInfo_FrameDropped)) {
        if (!atomic_exchange(&context->handled, true)) {
            [self receiveImage:NULL pts:pts sequence:context->sequence generation:context->generation
                metadata:nil submittedAt:context->submittedAt status:status flags:info];
        }
        return status == noErr ? DR_OK : DR_NEED_IDR;
    }
    return DR_OK;
}

- (CMSampleBufferRef)copyPresentationSampleAtTime:(CFTimeInterval)time {
    return [self copyPresentationSampleAtTime:time decodedAt:NULL sequence:NULL generation:NULL];
}

- (CMSampleBufferRef)copyPresentationSampleAtTime:(CFTimeInterval)time decodedAt:(CFTimeInterval*)decodedAt
    sequence:(uint64_t*)sequence generation:(uint64_t*)generation {
    [_slotLock lock];
    if (!_pendingImage || !_acceptingOutputs || _needsReset) {
        [_slotLock unlock];
        return NULL;
    }
    // Transfer the slot's +1 reference to this display selection; no pixel copy.
    CVPixelBufferRef image = _pendingImage;
    CMTime pts = _pendingPTS;
    double age = MAX(0, time - _pendingReadyAt);
    NSDictionary* metadata = _pendingMetadata;
    if (decodedAt) { *decodedAt = _pendingReadyAt; }
    if (sequence) { *sequence = _pendingSequence; }
    if (generation) { *generation = _generation; }
    _pendingImage = NULL;
    _pendingMetadata = nil;
    [_slotLock unlock];
    // Preserve decoder-supplied attachments; fill/override only source color/HDR keys.
    for (NSString* key in metadata) {
        CVBufferSetAttachment(image, (__bridge CFStringRef)key, (__bridge CFTypeRef)metadata[key], kCVAttachmentMode_ShouldPropagate);
    }
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &description);
    if (status == noErr) {
        CMSampleTimingInfo timing = { kCMTimeInvalid, pts, kCMTimeInvalid };
        status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, description, &timing, &sample);
    }
    if (description) {
        CFRelease(description);
    }
    CVPixelBufferRelease(image);
    if (status != noErr && sample) {
        CFRelease(sample);
        sample = NULL;
    }
    if (status == noErr) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments && CFArrayGetCount(attachments) == 1) {
            CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        else {
            CFRelease(sample);
            sample = NULL;
        }
    }
    [_slotLock lock];
    if (sample) {
        _presented++;
        _ageTotal += age;
    }
    else {
        _presentationErrors++;
    }
    [_slotLock unlock];
    return sample;
}

- (BOOL)isPresentationCurrentForSequence:(uint64_t)sequence generation:(uint64_t)generation {
    [_slotLock lock];
    BOOL current = _acceptingOutputs && !_needsReset && generation == _generation && sequence == _newestSequence;
    if (!current) { _staleCandidates++; }
    [_slotLock unlock];
    return current;
}

- (void)recordEnqueueAt:(CFTimeInterval)time decodedAt:(CFTimeInterval)decodedAt
    selectedAt:(CFTimeInterval)selectedAt displayTarget:(CFTimeInterval)displayTarget {
    [_slotLock lock];
    _enqueues++;
    _enqueueAgeTotal += MAX(0, time - decodedAt);
    _enqueueSelectionAgeTotal += MAX(0, selectedAt - decodedAt);
    if (displayTarget > 0) {
        _syncEnqueues++;
        _syncAgeTotal += MAX(0, selectedAt - decodedAt);
        _targetLeadTotal += displayTarget - selectedAt; // Negative means selection was late.
    }
    [_slotLock unlock];
}

- (NSDictionary*)takeStatistics {
    [_slotLock lock];
    NSDictionary* stats = @{
        @"submitted": @(_submitted), @"decoded": @(_decoded), @"overwritten": @(_overwritten),
        @"presented": @(_presented), @"late": @(_late), @"vtDropped": @(_vtDropped),
        @"asyncOutputs": @(_asyncOutputs), @"errors": @(_errors), @"resets": @(_resets),
        @"presentationErrors": @(_presentationErrors), @"slotDepth": @(_pendingImage ? 1 : 0),
        @"inFlight": @(_inFlight), @"pixelFormat": @(_outputPixelFormat),
        @"decodeMs": @(_decoded ? 1000 * _decodeTimeTotal / _decoded : 0),
        @"ageMs": @(_presented ? 1000 * _ageTotal / _presented : 0),
        @"enqueues": @(_enqueues), @"staleCandidates": @(_staleCandidates), @"syncEnqueues": @(_syncEnqueues),
        @"enqueueAgeMs": @(_enqueues ? 1000 * _enqueueAgeTotal / _enqueues : 0),
        @"enqueueSelectionAgeMs": @(_enqueues ? 1000 * _enqueueSelectionAgeTotal / _enqueues : 0),
        @"syncSelectionAgeMs": @(_syncEnqueues ? 1000 * _syncAgeTotal / _syncEnqueues : 0),
        @"targetLeadMs": @(_syncEnqueues ? 1000 * _targetLeadTotal / _syncEnqueues : 0)
    };
    _submitted = _decoded = _overwritten = _presented = _late = _vtDropped = 0;
    _asyncOutputs = _errors = _resets = _presentationErrors = 0;
    _decodeTimeTotal = _ageTotal = 0;
    _enqueues = _syncEnqueues = _staleCandidates = 0;
    _enqueueAgeTotal = _enqueueSelectionAgeTotal = _syncAgeTotal = _targetLeadTotal = 0;
    [_slotLock unlock];
    return stats;
}
@end
