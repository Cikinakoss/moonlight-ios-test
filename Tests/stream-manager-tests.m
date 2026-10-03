// Compile the actual StreamManager body with only HTTP/UI/connection dependencies
// replaced. CI strips its imports, not its logic, into the included temporary file.
#import <Foundation/Foundation.h>
#include <stdbool.h>
#define TRUE YES
#define FALSE NO
#import "../Limelight/Stream/StreamConfiguration.h"
#import "../Limelight/Stream/StreamConfiguration.m"

#define CHECK(x) do { if (!(x)) { NSLog(@"CHECK failed at %d: %s", __LINE__, #x); abort(); } } while (0)
#define Log(...) do {} while (0)
static BOOL busy, rendererLowLatency, connectionLowLatency;
static int connectionFrameRate;
static int created, terminated, failures, requests;
static void (^duringRequest)(NSString*);

@interface UIView : NSObject @end
@implementation UIView @end
@protocol ConnectionCallbacks <NSObject>
- (void)launchFailed:(NSString*)message;
@end
@interface VideoDecoderRenderer : NSObject
- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)ratio useFramePacing:(BOOL)pacing lowLatencyMode:(BOOL)lowLatencyMode;
@end
@implementation VideoDecoderRenderer
- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)ratio useFramePacing:(BOOL)pacing lowLatencyMode:(BOOL)lowLatencyMode { rendererLowLatency = lowLatencyMode; return [super init]; }
@end
#include "connection-under-test.inc"
@implementation Connection
- (id)initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)renderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks { self = [super init]; created++; connectionLowLatency = config.lowLatencyMode; connectionFrameRate = config.frameRate; return self; }
- (void)terminate { [self cancel]; terminated++; }
- (void)main {}
- (BOOL)getVideoStats:(video_stats_t*)stats { return NO; }
- (NSString*)getActiveCodecName { return @"test"; }
- (NSString*)getVideoSubmissionStats { return @""; }
@end
#include "stream-manager-header-under-test.inc"

@interface CryptoManager : NSObject
+ (void)generateKeyPairUsingSSL;
@end
@implementation CryptoManager
+ (void)generateKeyPairUsingSSL {}
@end
@interface Utils : NSObject
+ (NSData*)randomBytes:(int)count;
@end
@implementation Utils
+ (NSData*)randomBytes:(int)count { return [NSMutableData dataWithLength:count]; }
@end
@interface HttpResponse : NSObject
@property (readonly) NSString* statusMessage;
- (BOOL)isStatusOk;
- (NSString*)getStringTag:(NSString*)tag;
@end
@implementation HttpResponse
- (NSString*)statusMessage { return @"test"; }
- (BOOL)isStatusOk { return YES; }
- (NSString*)getStringTag:(NSString*)tag {
    if ([tag isEqualToString:@"state"]) { return busy ? @"SUNSHINE_SERVER_BUSY" : @"SUNSHINE_SERVER_FREE"; }
    if ([tag isEqualToString:@"sessionUrl0"]) { return @"rtsp://test"; }
    return @"1";
}
@end
@interface ServerInfoResponse : HttpResponse @end
@implementation ServerInfoResponse @end
@interface HttpRequest : NSObject
@property NSString* kind;
+ (id)requestForResponse:(HttpResponse*)response withUrlRequest:(NSString*)kind;
+ (id)requestForResponse:(HttpResponse*)response withUrlRequest:(NSString*)kind fallbackError:(int)error fallbackRequest:(NSString*)fallback;
@end
@implementation HttpRequest
+ (id)requestForResponse:(HttpResponse*)response withUrlRequest:(NSString*)kind { HttpRequest* request = [self new]; request.kind = kind; return request; }
+ (id)requestForResponse:(HttpResponse*)response withUrlRequest:(NSString*)kind fallbackError:(int)error fallbackRequest:(NSString*)fallback { return [self requestForResponse:response withUrlRequest:kind]; }
@end
@interface HttpManager : NSObject
- (id)initWithAddress:(NSString*)address httpsPort:(unsigned short)port serverCert:(NSData*)cert;
- (NSString*)newServerInfoRequest:(BOOL)fast;
- (NSString*)newHttpServerInfoRequest;
- (NSString*)newLaunchOrResumeRequest:(NSString*)verb config:(StreamConfiguration*)config;
- (void)executeRequestSynchronously:(HttpRequest*)request;
@end
@implementation HttpManager
- (id)initWithAddress:(NSString*)address httpsPort:(unsigned short)port serverCert:(NSData*)cert { return [super init]; }
- (NSString*)newServerInfoRequest:(BOOL)fast { return @"serverinfo"; }
- (NSString*)newHttpServerInfoRequest { return @"serverinfo"; }
- (NSString*)newLaunchOrResumeRequest:(NSString*)verb config:(StreamConfiguration*)config { return verb; }
- (void)executeRequestSynchronously:(HttpRequest*)request { requests++; if (duringRequest) { duringRequest(request.kind); } }
@end
bool LiGetEstimatedRttInfo(uint32_t* rtt, uint32_t* variance) { return false; }
#include "stream-manager-under-test.inc"
@interface TestCallbacks : NSObject <ConnectionCallbacks> @end
@implementation TestCallbacks
- (void)launchFailed:(NSString*)message { failures++; }
@end

static StreamManager* manager(void) {
    StreamConfiguration* config = [StreamConfiguration new];
    config.width = config.height = 16;
    return [[StreamManager alloc] initWithConfig:config renderView:[UIView new] connectionCallbacks:[TestCallbacks new]];
}
static void drainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    CHECK(drained);
}

int main(void) {
    @autoreleasepool {
        StreamManager* stream = manager();
        [stream stopStream]; [stream main]; drainMainQueue();
        CHECK(created == 0 && requests == 0);
        for (NSString* phase in @[@"serverinfo", @"launch", @"resume"]) {
            stream = manager(); busy = [phase isEqualToString:@"resume"];
            __weak StreamManager* weakStream = stream;
            duringRequest = ^(NSString* kind) { if ([kind isEqualToString:phase]) { [weakStream stopStream]; } };
            [stream main]; drainMainQueue();
            CHECK(created == 0 && failures == 0);
        }
        duringRequest = nil; busy = NO;
        stream = manager(); [stream main]; // Handoff queued, not yet executed.
        [stream stopStream]; drainMainQueue();
        CHECK(created == 0);
        stream = manager();
        NSOperationQueue* queue = [NSOperationQueue new];
        [queue addOperation:stream]; [queue waitUntilAllOperationsAreFinished];
        CHECK(stream.isFinished); // HTTP operation finished, main handoff still queued.
        [stream stopStream]; drainMainQueue();
        CHECK(created == 0);
        stream = manager(); [stream main]; drainMainQueue();
        CHECK(created == 1 && !rendererLowLatency && !connectionLowLatency);
        [stream stopStream];
        CHECK(terminated == 1);
        // The shared preset reaches both consumers without changing selected FPS.
        StreamConfiguration* config = [StreamConfiguration new];
        config.width = config.height = 16;
        config.frameRate = 60;
        config.lowLatencyMode = YES;
        stream = [[StreamManager alloc] initWithConfig:config renderView:[UIView new] connectionCallbacks:[TestCallbacks new]];
        [stream main]; drainMainQueue();
        CHECK(created == 2 && rendererLowLatency && connectionLowLatency);
        CHECK(connectionFrameRate == 60);
        [stream stopStream]; CHECK(terminated == 2);
        NSLog(@"PASS: cancellation before HTTP, during serverinfo/launch/resume, queued main handoff, and published connection termination");
    }
    return 0;
}
