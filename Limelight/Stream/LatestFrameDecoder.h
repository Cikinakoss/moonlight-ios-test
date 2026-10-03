// Explicit VideoToolbox decode with one pending decoded presentation image.
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

@interface LatestFrameDecoder : NSObject
// Called only by the serial compressed-video consumer.
- (int)submitSampleBuffer:(CMSampleBufferRef)sample videoFormat:(int)videoFormat isIDR:(BOOL)isIDR;
// Called by the sole presentation consumer when its renderer can accept an image.
// Returns a +1 sample referencing the selected pixel buffer, or NULL if idle.
- (CMSampleBufferRef)copyPresentationSampleAtTime:(CFTimeInterval)time CF_RETURNS_RETAINED;
- (CMSampleBufferRef)copyPresentationSampleAtTime:(CFTimeInterval)time decodedAt:(CFTimeInterval*)decodedAt
    sequence:(uint64_t*)sequence generation:(uint64_t*)generation CF_RETURNS_RETAINED;
// The callback only signals a coalescer; it must not wait or do display work.
- (void)setOutputAvailableHandler:(dispatch_block_t)handler;
// Recheck freshness after sample wrapping, immediately before Immediate enqueue.
- (BOOL)isPresentationCurrentForSequence:(uint64_t)sequence generation:(uint64_t)generation;
- (void)recordEnqueueAt:(CFTimeInterval)time decodedAt:(CFTimeInterval)decodedAt
    selectedAt:(CFTimeInterval)selectedAt;
- (NSDictionary*)takeStatistics;
- (NSString*)fatalError;
// Off the main thread, after the compressed-video consumer has joined.
- (void)stop;
@end
