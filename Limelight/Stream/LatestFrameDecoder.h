// Explicit VideoToolbox decode with one pending decoded presentation image.
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

@interface LatestFrameDecoder : NSObject
// Called only by the serial compressed-video consumer.
- (int)submitSampleBuffer:(CMSampleBufferRef)sample videoFormat:(int)videoFormat isIDR:(BOOL)isIDR;
// Called on the display thread only when its renderer can accept an image.
// Returns a +1 sample referencing the selected pixel buffer, or NULL if idle.
- (CMSampleBufferRef)copyPresentationSampleAtTime:(CFTimeInterval)time CF_RETURNS_RETAINED;
- (NSDictionary*)takeStatistics;
- (NSString*)fatalError;
// Off the main thread, after the compressed-video consumer has joined.
- (void)stop;
@end
