// Exercise the production mailbox and CF ownership on macOS without a codec/device.
#import "../Limelight/Stream/LatestFrameDecoder.m"
#include <stdlib.h>

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
        NSLog(@"Latest-frame tests passed: replacement, PTS ordering, consumed-slot watermark, CF ownership, concurrency, shutdown and recovery.");
    }
    return 0;
}
