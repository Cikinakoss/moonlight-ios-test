#import <Foundation/Foundation.h>

// No frames are captured by requests. The handler reads the newest slot at execution.
@interface LatestFramePresentationScheduler : NSObject
- (id)initWithQueue:(dispatch_queue_t)queue handler:(dispatch_block_t)handler;
- (void)start;
- (void)requestPresentation;
- (NSDictionary*)takeStatistics;
- (void)cancel; // Close the request gate without waiting; safe on any thread.
// Caller must be off the presentation queue and leave the main queue free.
- (void)stop;
@end

// AVSampleBufferVideoRenderer implements these public readiness methods.
@protocol LatestFrameReadinessSource <NSObject>
- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)block;
- (void)stopRequestingMediaData;
@end

// All methods and the readiness callback run on the presentation queue.
@interface LatestFrameReadinessRetry : NSObject
- (id)initWithQueue:(dispatch_queue_t)queue handler:(dispatch_block_t)handler;
- (void)waitForRenderer:(id<LatestFrameReadinessSource>)renderer;
- (void)cancel;
@end
