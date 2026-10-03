#import "LatestFramePresentationScheduler.h"

@implementation LatestFramePresentationScheduler {
    NSLock* _lock;
    dispatch_queue_t _queue;
    dispatch_group_t _group;
    dispatch_block_t _handler;
    BOOL _active;
    BOOL _outstanding;
    BOOL _dirty;
    uint64_t _requests, _coalesced, _passes;
}

- (id)initWithQueue:(dispatch_queue_t)queue handler:(dispatch_block_t)handler {
    self = [super init];
    _lock = [[NSLock alloc] init];
    _queue = queue;
    _group = dispatch_group_create();
    _handler = [handler copy];
    return self;
}

- (void)start {
    [_lock lock];
    NSAssert(!_outstanding, @"Presentation worker must be drained before restart");
    _active = YES;
    _dirty = NO;
    _requests = _coalesced = _passes = 0;
    [_lock unlock];
}

- (void)requestPresentation {
    [_lock lock];
    if (!_active) {
        [_lock unlock];
        return;
    }
    _requests++;
    _dirty = YES;
    if (_outstanding) {
        _coalesced++;
    }
    else {
        _outstanding = YES;
        // Enter the group before releasing the lock: stop cannot miss queued work.
        dispatch_group_async(_group, _queue, ^{ [self runPresentation]; });
    }
    [_lock unlock];
}

- (void)runPresentation {
    for (;;) {
        [_lock lock];
        if (!_active || !_dirty) {
            _dirty = NO;
            _outstanding = NO;
            [_lock unlock];
            return;
        }
        _dirty = NO;
        _passes++;
        [_lock unlock];
        @autoreleasepool {
            _handler();
        }
        // Only a request arriving during this pass requests another pass. No spin
        // waiting for readiness, no frame FIFO, and no block dispatched per frame.
    }
}

- (void)cancel {
    [_lock lock];
    _active = NO;
    _dirty = NO;
    [_lock unlock];
}

- (void)stop {
    [self cancel];
    dispatch_group_wait(_group, DISPATCH_TIME_FOREVER);
}

- (NSDictionary*)takeStatistics {
    [_lock lock];
    NSDictionary* stats = @{
        @"requests": @(_requests), @"coalesced": @(_coalesced),
        @"passes": @(_passes), @"outstanding": @(_outstanding ? 1 : 0)
    };
    _requests = _coalesced = _passes = 0;
    [_lock unlock];
    return stats;
}
@end

@implementation LatestFrameReadinessRetry {
    dispatch_queue_t _queue;
    dispatch_block_t _handler;
    id<LatestFrameReadinessSource> _renderer;
    NSObject* _token;
}

- (id)initWithQueue:(dispatch_queue_t)queue handler:(dispatch_block_t)handler {
    self = [super init];
    _queue = queue;
    _handler = [handler copy];
    return self;
}

- (void)waitForRenderer:(id<LatestFrameReadinessSource>)renderer {
    if (_renderer == renderer) { return; }
    [self cancel];
    _renderer = renderer;
    NSObject* token = _token = [[NSObject alloc] init];
    __weak LatestFrameReadinessRetry* weakSelf = self;
    [renderer requestMediaDataWhenReadyOnQueue:_queue usingBlock:^{
        LatestFrameReadinessRetry* retry = weakSelf;
        if (!retry || retry->_token != token) { return; }
        // One-shot: cancel before signaling, so a ready/empty renderer cannot
        // repeatedly call us. The coalescer still owns every presentation pass.
        [retry cancel];
        retry->_handler();
    }];
}

- (void)cancel {
    id<LatestFrameReadinessSource> renderer = _renderer;
    _renderer = nil;
    _token = nil; // Already queued callbacks cannot cancel a newer registration.
    [renderer stopRequestingMediaData];
}
@end
