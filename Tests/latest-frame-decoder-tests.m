// Exercise the production mailbox and CF ownership on macOS without a codec/device.
#import "../Limelight/Stream/LatestFrameDecoder.m"
#import "../Limelight/Stream/LatestFramePresentationScheduler.m"
#include <stdlib.h>
#include <math.h>

static atomic_uint releasedImages;
static unsigned int idrRequests;
void LiRequestIdrFrame(void) { idrRequests++; }

#define CHECK(value) do { if (!(value)) { NSLog(@"CHECK failed at line %d: %s", __LINE__, #value); abort(); } } while (0)

static void releasePixels(void* refcon, const void* bytes) {
    free((void*)bytes);
    atomic_fetch_add(&releasedImages, 1);
}

static CVPixelBufferRef createImage(void) {
    CVPixelBufferRef image = NULL;
    void* bytes = calloc(16 * 16, 4);
    CHECK(bytes != NULL);
    CHECK(CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
        bytes, 16 * 4, releasePixels, NULL, NULL, &image) == kCVReturnSuccess);
    return image;
}

static void output(LatestFrameDecoder* decoder, CVPixelBufferRef image, int pts, uint64_t sequence) {
    [decoder receiveImage:image pts:CMTimeMake(pts, 120) sequence:sequence generation:1 metadata:@{}
        submittedAt:CACurrentMediaTime() status:noErr flags:kVTDecodeInfo_Asynchronous];
}

static void testImmediatePresentation(void) {
    @autoreleasepool {
        LatestFrameDecoder* decoder = [[LatestFrameDecoder alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("test.latest-presentation", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(queue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        __block int enqueues = 0;
        LatestFramePresentationScheduler* scheduler = [[LatestFramePresentationScheduler alloc] initWithQueue:queue handler:^{
            CFTimeInterval decodedAt;
            uint64_t sequence, generation;
            CMSampleBufferRef sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()
                decodedAt:&decodedAt sequence:&sequence generation:&generation];
            CHECK(sample != NULL);
            CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(102, 120)) == 0);
            CHECK([decoder isPresentationCurrentForSequence:sequence generation:generation]);
            // Known times verify selection and completed-enqueue ages stay distinct.
            [decoder recordEnqueueAt:decodedAt + 0.006 decodedAt:decodedAt
                selectedAt:decodedAt + 0.002];
            enqueues++;
            CFRelease(sample);
        }];
        [scheduler start];
        [decoder setPresentationWakeHandler:^{ [scheduler requestPresentation]; }];
        CVPixelBufferRef image = createImage();
        output(decoder, image, 100, 1);
        output(decoder, image, 102, 2);
        output(decoder, image, 101, 3); // Rejected callbacks must not request presentation.
        dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
            [scheduler requestPresentation];
        });
        NSDictionary* stats = [scheduler takeStatistics];
        CHECK([stats[@"requests"] intValue] == 1002 && [stats[@"coalesced"] intValue] == 1001);
        CHECK([stats[@"outstanding"] intValue] == 1 && [stats[@"passes"] intValue] == 0);
        dispatch_semaphore_signal(gate);
        dispatch_sync(queue, ^{});
        CHECK(enqueues == 1); // All queued requests read the newest image once.
        stats = [scheduler takeStatistics];
        CHECK([stats[@"outstanding"] intValue] == 0 && [stats[@"passes"] intValue] == 1);
        stats = [decoder takeStatistics];
        CHECK([stats[@"enqueues"] intValue] == 1 && [stats[@"slotDepth"] intValue] == 0);
        CHECK(fabs([stats[@"enqueueAgeMs"] doubleValue] - 6) < 0.01);
        CHECK(fabs([stats[@"enqueueSelectionAgeMs"] doubleValue] - 2) < 0.01);
        [scheduler stop];
        [decoder setPresentationWakeHandler:nil];

        // A newer output during wrapping makes the selected Immediate candidate stale.
        output(decoder, image, 103, 4);
        CFTimeInterval decodedAt;
        uint64_t sequence, generation;
        CMSampleBufferRef sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()
            decodedAt:&decodedAt sequence:&sequence generation:&generation];
        CHECK(sample != NULL);
        output(decoder, image, 104, 5);
        output(decoder, image, 103, 6);
        CHECK(![decoder isPresentationCurrentForSequence:sequence generation:generation]);
        CFRelease(sample);
        sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()
            decodedAt:&decodedAt sequence:&sequence generation:&generation];
        CHECK(sample && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(104, 120)) == 0);
        CHECK([decoder isPresentationCurrentForSequence:sequence generation:generation]);
        [decoder recordEnqueueAt:decodedAt + 0.001 decodedAt:decodedAt selectedAt:decodedAt + 0.0005];
        CFRelease(sample);
        stats = [decoder takeStatistics];
        CHECK([stats[@"staleCandidates"] intValue] == 1 && [stats[@"late"] intValue] == 1);
        CHECK([stats[@"enqueues"] intValue] == 1);
        [decoder stop];
        CHECK(![decoder isPresentationCurrentForSequence:sequence generation:generation]);
        CVPixelBufferRelease(image);
    }
}

static void testTerminalDecoderErrorWake(void) {
    @autoreleasepool {
        LatestFrameDecoder* decoder = [[LatestFrameDecoder alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("test.terminal-error", DISPATCH_QUEUE_SERIAL);
        __block int failures = 0;
        LatestFramePresentationScheduler* scheduler = [[LatestFramePresentationScheduler alloc] initWithQueue:queue handler:^{
            CHECK([decoder fatalError] != nil);
            CHECK([decoder copyPresentationSampleAtTime:CACurrentMediaTime()] == NULL);
            failures++;
        }];
        [scheduler start];
        [decoder setPresentationWakeHandler:^{ [scheduler requestPresentation]; }];
        unsigned int initialIDRs = idrRequests;
        for (uint64_t generation = 1; generation <= 3; generation++) {
            if (generation > 1) {
                // Exercise actual generation/slot reset and output admission without
                // requiring a hardware codec in the synthetic callback harness.
                [decoder closeSession];
                [decoder acceptOutputsAfterSessionCreation];
                [decoder receiveImage:NULL pts:kCMTimeInvalid sequence:99 generation:generation - 1 metadata:nil
                    submittedAt:CACurrentMediaTime() status:-1 flags:0];
                CHECK(idrRequests == initialIDRs + generation - 1); // Old errors cannot escalate.
            }
            [decoder receiveImage:NULL pts:kCMTimeInvalid sequence:generation generation:generation metadata:nil
                submittedAt:CACurrentMediaTime() status:-1 flags:0];
            dispatch_sync(queue, ^{});
            CHECK(failures == (generation == 3 ? 1 : 0));
        }
        CHECK(idrRequests == initialIDRs + 3);
        CHECK([[decoder fatalError] containsString:@"Low Latency"]);
        // No new compressed input or decoded image was needed to wake the worker.
        [decoder receiveImage:NULL pts:kCMTimeInvalid sequence:4 generation:3 metadata:nil
            submittedAt:CACurrentMediaTime() status:-1 flags:0];
        dispatch_sync(queue, ^{});
        CHECK(failures == 1 && idrRequests == initialIDRs + 3);
        [scheduler stop];
        [decoder stop];
        [decoder receiveImage:NULL pts:kCMTimeInvalid sequence:5 generation:4 metadata:nil
            submittedAt:CACurrentMediaTime() status:-1 flags:0];
        CHECK(idrRequests == initialIDRs + 3);
        CHECK([[scheduler takeStatistics][@"requests"] intValue] == 1);
    }
}

static void testConcurrentPresentationShutdown(void) {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("test.active-shutdown", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        __block int passes = 0;
        LatestFramePresentationScheduler* scheduler = [[LatestFramePresentationScheduler alloc] initWithQueue:queue handler:^{
            passes++;
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        }];
        [scheduler start];
        [scheduler requestPresentation];
        CHECK(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            [scheduler cancel];
            dispatch_semaphore_signal(cancelled);
            [scheduler stop]; // Must wait for the active presentation handler.
            dispatch_semaphore_signal(stopped);
        });
        CHECK(dispatch_semaphore_wait(cancelled, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
            [scheduler requestPresentation]; // Concurrent late output/readiness requests.
        });
        CHECK(dispatch_semaphore_wait(stopped, DISPATCH_TIME_NOW) != 0);
        NSDictionary* stats = [scheduler takeStatistics];
        CHECK([stats[@"requests"] intValue] == 1 && [stats[@"outstanding"] intValue] == 1);
        dispatch_semaphore_signal(release);
        CHECK(dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        CHECK(passes == 1 && [[scheduler takeStatistics][@"outstanding"] intValue] == 0);
        [scheduler stop]; // Repeated cleanup remains safe after the concurrent stop.
    }
}

static void testPresentationSchedulerLifecycle(void) {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("test.presentation-lifecycle", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(queue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        __block int passes = 0;
        __block int active = 0;
        __block __weak LatestFramePresentationScheduler* weakScheduler;
        LatestFramePresentationScheduler* scheduler = [[LatestFramePresentationScheduler alloc] initWithQueue:queue handler:^{
            CHECK(++active == 1); // Never two concurrent presentation handlers.
            passes++;
            if (passes == 1) {
                for (int i = 0; i < 1000; i++) { [weakScheduler requestPresentation]; }
            }
            active--;
        }];
        weakScheduler = scheduler;
        [scheduler start];
        [scheduler requestPresentation];
        [scheduler cancel]; // Close deterministically while the task is queued.
        [scheduler requestPresentation]; // Closed gate must ignore this request.
        dispatch_semaphore_signal(gate);
        [scheduler stop];
        CHECK(passes == 0);
        NSDictionary* stats = [scheduler takeStatistics];
        CHECK([stats[@"outstanding"] intValue] == 0 && [stats[@"requests"] intValue] == 1);
        [scheduler start];
        [scheduler requestPresentation];
        dispatch_sync(queue, ^{});
        CHECK(passes == 2); // Arrivals during a pass coalesce into exactly one more pass.
        stats = [scheduler takeStatistics];
        CHECK([stats[@"requests"] intValue] == 1001 && [stats[@"coalesced"] intValue] == 1000);
        CHECK([stats[@"passes"] intValue] == 2 && [stats[@"outstanding"] intValue] == 0);
        [scheduler requestPresentation]; // New work after the idle transition is not lost.
        dispatch_sync(queue, ^{});
        CHECK(passes == 3);
        [scheduler stop];
        [scheduler stop];
        [scheduler requestPresentation];
        stats = [scheduler takeStatistics];
        CHECK([stats[@"requests"] intValue] == 1 && [stats[@"outstanding"] intValue] == 0);
    }
}

@interface TestReadinessSource : NSObject <LatestFrameReadinessSource>
@property BOOL ready;
@property int registrations;
@property int cancellations;
@property (copy) dispatch_block_t callback;
@end
@implementation TestReadinessSource
- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)block {
    self.registrations++;
    self.callback = block;
}
- (void)stopRequestingMediaData {
    self.cancellations++;
    self.callback = nil;
}
@end

static void testReadinessRetry(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.readiness-retry", DISPATCH_QUEUE_SERIAL);
    LatestFrameDecoder* decoder = [[LatestFrameDecoder alloc] init];
    TestReadinessSource* source = [[TestReadinessSource alloc] init];
    __block LatestFrameReadinessRetry* retry;
    __block int enqueues = 0;
    LatestFramePresentationScheduler* scheduler = [[LatestFramePresentationScheduler alloc] initWithQueue:queue handler:^{
        if (!source.ready) { [retry waitForRenderer:source]; return; }
        [retry cancel];
        CMSampleBufferRef sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()];
        CHECK(sample != NULL);
        enqueues++;
        CFRelease(sample);
    }];
    retry = [[LatestFrameReadinessRetry alloc] initWithQueue:queue handler:^{ [scheduler requestPresentation]; }];
    [scheduler start];
    CVPixelBufferRef image = createImage();
    output(decoder, image, 100, 1);
    [scheduler requestPresentation];
    dispatch_sync(queue, ^{});
    CHECK(enqueues == 0 && source.registrations == 1);
    dispatch_sync(queue, ^{
        [retry waitForRenderer:source];
        CHECK(source.registrations == 1); // No duplicate readiness subscription.
        source.ready = YES;
        source.callback(); // Readiness alone, with no new decoded frame.
    });
    dispatch_sync(queue, ^{});
    CHECK(enqueues == 1 && source.callback == nil);
    dispatch_sync(queue, ^{
        source.ready = NO;
        [retry waitForRenderer:source];
        dispatch_block_t oldCallback = source.callback;
        [retry cancel];
        [retry waitForRenderer:source];
        dispatch_block_t newCallback = source.callback;
        oldCallback();
        CHECK(source.callback == newCallback); // Old callback cannot cancel new registration.
        [scheduler cancel];
        [retry cancel];
        newCallback(); // A queued callback after teardown must be inert.
    });
    [scheduler stop];
    CHECK(enqueues == 1 && source.registrations == source.cancellations);
    retry = nil; // Break the test's intentional handler capture before releasing owners.
    [decoder stop];
    CVPixelBufferRelease(image);
}

int main(void) {
    @autoreleasepool {
        atomic_init(&releasedImages, 0);
        LatestFrameDecoder* decoder = [[LatestFrameDecoder alloc] init];
        CVPixelBufferRef first = createImage();
        output(decoder, first, 100, 1);
        CVPixelBufferRelease(first); // Only the pending slot now owns it.
        CHECK(atomic_load(&releasedImages) == 0);
        CVPixelBufferRef second = createImage();
        output(decoder, second, 102, 2);
        CVPixelBufferRelease(second);
        CHECK(atomic_load(&releasedImages) == 1); // Overwritten image released.
        CVPixelBufferRef late = createImage();
        output(decoder, late, 101, 3); // Higher submission sequence, older display PTS.
        CVPixelBufferRelease(late);
        CHECK(atomic_load(&releasedImages) == 2);
        CMSampleBufferRef sample;
        @autoreleasepool {
            sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()];
            CHECK(sample != NULL);
            CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(102, 120)) == 0);
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
            CHECK(attachments && CFArrayGetCount(attachments) == 1);
            CHECK(CFDictionaryGetValue(CFArrayGetValueAtIndex(attachments, 0),
                kCMSampleAttachmentKey_DisplayImmediately) == kCFBooleanTrue);
            CHECK(atomic_load(&releasedImages) == 2); // Sample retains the selected image.
            LatestDecodeContext* context = [[LatestDecodeContext alloc] initWithSample:sample];
            void (^retainedInput)(void) = ^{ CHECK(CMSampleBufferDataIsReady(context->sample)); };
            CFRelease(sample);
            context = nil;
            CHECK(atomic_load(&releasedImages) == 2); // Async context owns input until handler release.
            retainedInput();
            retainedInput = nil;
        } // Drain ARC block temporaries before checking final input/image release.
        CHECK(atomic_load(&releasedImages) == 3);
        CVPixelBufferRef olderAfterSelection = createImage();
        output(decoder, olderAfterSelection, 101, 4);
        CVPixelBufferRelease(olderAfterSelection);
        CHECK([decoder copyPresentationSampleAtTime:CACurrentMediaTime()] == NULL);
        NSDictionary* stats = [decoder takeStatistics];
        CHECK([stats[@"slotDepth"] intValue] == 0);
        CHECK([stats[@"overwritten"] intValue] == 1);
        CHECK([stats[@"late"] intValue] == 2);
        CHECK([stats[@"presented"] intValue] == 1);
        [decoder stop];

        // Invalid/tied PTS use sequence ordering, with the same single-slot ownership.
        decoder = [[LatestFrameDecoder alloc] init];
        CVPixelBufferRef shared = createImage();
        [decoder receiveImage:shared pts:kCMTimeInvalid sequence:10 generation:1 metadata:@{}
            submittedAt:CACurrentMediaTime() status:noErr flags:0];
        [decoder receiveImage:shared pts:kCMTimeInvalid sequence:9 generation:1 metadata:@{}
            submittedAt:CACurrentMediaTime() status:noErr flags:0];
        stats = [decoder takeStatistics];
        CHECK([stats[@"slotDepth"] intValue] == 1 && [stats[@"late"] intValue] == 1);
        [decoder stop];
        [decoder stop]; // Idempotent cleanup.
        output(decoder, shared, 999, 999); // Callback after stop cannot populate the slot.
        stats = [decoder takeStatistics];
        CHECK([stats[@"slotDepth"] intValue] == 0);
        CVPixelBufferRelease(shared);

        // Source metadata survives decode/presentation wrapping without RGB conversion code.
        decoder = [[LatestFrameDecoder alloc] init];
        CMVideoFormatDescriptionRef sourceFormat = NULL;
        NSDictionary* sourceMetadata = @{
            (__bridge NSString*)kCMFormatDescriptionExtension_ColorPrimaries: (__bridge NSString*)kCVImageBufferColorPrimaries_ITU_R_709_2,
            (__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo: [NSData dataWithBytes:"\0\0\0\0" length:4]
        };
        CHECK(CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_HEVC, 16, 16,
            (__bridge CFDictionaryRef)sourceMetadata, &sourceFormat) == noErr);
        NSDictionary* imageMetadata = [decoder imageMetadataFromFormat:sourceFormat];
        CHECK([imageMetadata[(__bridge NSString*)kCVImageBufferContentLightLevelInfoKey]
            isEqual:sourceMetadata[(__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo]]);
        CFRelease(sourceFormat);
        shared = createImage();
        [decoder receiveImage:shared pts:CMTimeMake(1, 120) sequence:1 generation:1
            metadata:@{(__bridge NSString*)kCVImageBufferColorPrimariesKey: imageMetadata[(__bridge NSString*)kCVImageBufferColorPrimariesKey]}
            submittedAt:CACurrentMediaTime() status:noErr flags:0];
        sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()];
        CHECK(sample != NULL);
        CFTypeRef primaries = CMFormatDescriptionGetExtension(CMSampleBufferGetFormatDescription(sample),
            kCMFormatDescriptionExtension_ColorPrimaries);
        CHECK(primaries && CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2));
        CFRelease(sample);
        [decoder stop];
        CVPixelBufferRelease(shared);

        // Concurrent old callbacks cannot replace a newer accepted image.
        decoder = [[LatestFrameDecoder alloc] init];
        shared = createImage();
        output(decoder, shared, 2000, 2000);
        dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
            @autoreleasepool { output(decoder, shared, (int)i, i + 1); }
        });
        stats = [decoder takeStatistics];
        CHECK([stats[@"late"] intValue] == 1000 && [stats[@"slotDepth"] intValue] == 1);
        sample = [decoder copyPresentationSampleAtTime:CACurrentMediaTime()];
        CHECK(sample && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(2000, 120)) == 0);
        CFRelease(sample);
        [decoder stop];
        CVPixelBufferRelease(shared);

        // Error callbacks coalesce IDR recovery and stop prevents later recovery requests.
        decoder = [[LatestFrameDecoder alloc] init];
        for (int i = 0; i < 2; i++) {
            [decoder receiveImage:NULL pts:kCMTimeInvalid sequence:i generation:1 metadata:nil
                submittedAt:CACurrentMediaTime() status:-1 flags:0];
        }
        CHECK(idrRequests == 1);
        [decoder stop];
        [decoder receiveImage:NULL pts:kCMTimeInvalid sequence:3 generation:1 metadata:nil
            submittedAt:CACurrentMediaTime() status:-1 flags:0];
        CHECK(idrRequests == 1);
        testImmediatePresentation();
        testPresentationSchedulerLifecycle();
        testConcurrentPresentationShutdown();
        testReadinessRetry();
        testTerminalDecoderErrorWake();
        NSLog(@"Latest-frame tests passed: ownership/ordering, coalesced presentation, stale candidates, ages, concurrent shutdown, restart, readiness recovery, and terminal error wake.");
    }
    return 0;
}
