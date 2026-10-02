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
