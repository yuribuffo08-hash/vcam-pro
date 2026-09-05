#import "VCamPreviewController.h"
#import "VCamEngine.h"
#import "VCamLog.h"
#import <UIKit/UIKit.h>

@interface VCamPreviewController () {
    dispatch_queue_t _renderQueue;
    dispatch_source_t _timer;
    BOOL _timerRunning;
    uint64_t _lastRenderedSerial;
    BOOL _stopped;
}
@end

@implementation VCamPreviewController

- (instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer {
    self = [super init];
    if (self) {
        _previewLayer = previewLayer;
        _renderQueue = dispatch_queue_create("com.vcam.preview.render", DISPATCH_QUEUE_SERIAL);
        _lastRenderedSerial = 0;
        _timerRunning = NO;
        _stopped = NO;

        _overlayLayer = [CALayer layer];
        _overlayLayer.name = @"VCamPreviewOverlay";
        _overlayLayer.masksToBounds = YES;
        _overlayLayer.opaque = YES;
        _overlayLayer.backgroundColor = [UIColor blackColor].CGColor;
        _overlayLayer.contentsGravity = kCAGravityResizeAspectFill;
        // Disable CoreAnimation default implicit animations for instantaneous updates
        _overlayLayer.actions = @{
            @"contents": [NSNull null],
            @"bounds": [NSNull null],
            @"position": [NSNull null],
            @"sublayers": [NSNull null],
            @"hidden": [NSNull null],
            @"opacity": [NSNull null]
        };

        if (previewLayer) {
            [previewLayer addSublayer:_overlayLayer];
            _overlayLayer.frame = previewLayer.bounds;
        }

        // Listen for session running / stopping notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionDidStartRunning:)
                                                     name:AVCaptureSessionDidStartRunningNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionDidStopRunning:)
                                                     name:AVCaptureSessionDidStopRunningNotification
                                                   object:nil];

        // Listen for preferences changes via internal local notification
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(preferencesChanged:)
                                                     name:@"com.vcam.pro.internalPrefsChanged"
                                                   object:nil];

        VCamLog(@"VCamPreviewController: initialized for previewLayer %p", previewLayer);
        [self updateLayout];
    }
    return self;
}

- (void)preferencesChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateVisibility];
    });
}

- (void)sessionDidStartRunning:(NSNotification *)note {
    if (_previewLayer && note.object == _previewLayer.session) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateVisibility];
        });
    }
}

- (void)sessionDidStopRunning:(NSNotification *)note {
    if (_previewLayer && note.object == _previewLayer.session) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateVisibility];
        });
    }
}

- (NSString *)contentsGravityForVideoGravity:(NSString *)videoGravity {
    if ([videoGravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
        return kCAGravityResizeAspect;
    } else if ([videoGravity isEqualToString:AVLayerVideoGravityResize]) {
        return kCAGravityResize;
    }
    return kCAGravityResizeAspectFill;
}

- (void)updateLayout {
    if (_stopped || !_previewLayer) return;

    // Ensure overlay is attached
    if (_overlayLayer.superlayer != _previewLayer) {
        [_previewLayer addSublayer:_overlayLayer];
    } else if (_previewLayer.sublayers.lastObject != _overlayLayer) {
        // Keep overlay at the top of previewLayer's sublayers
        [_previewLayer addSublayer:_overlayLayer];
    }

    _overlayLayer.frame = _previewLayer.bounds;
    _overlayLayer.contentsGravity = [self contentsGravityForVideoGravity:_previewLayer.videoGravity];

    [self updateVisibility];
}

- (void)updateVisibility {
    if (_stopped || !_previewLayer) return;

    VCamEngine *engine = [VCamEngine sharedEngine];
    BOOL shouldBeVisible = engine.enabled && engine.previewEnabled &&
                           _previewLayer.superlayer != nil &&
                           !_previewLayer.hidden &&
                           _previewLayer.opacity > 0.01;

    _overlayLayer.hidden = !shouldBeVisible;

    if (shouldBeVisible) {
        [self startTimerIfNeeded];
    } else {
        [self stopTimerIfNeeded];
    }
}

- (void)updateSession {
    [self updateVisibility];
}

- (void)layerDidRemoveFromSuperlayer {
    [self updateVisibility];
}

- (void)startTimerIfNeeded {
    if (_timerRunning || _stopped) return;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _renderQueue);
    if (!_timer) return;

    // 30 FPS = ~33.3ms
    uint64_t interval = (uint64_t)(1.0 / 30.0 * NSEC_PER_SEC);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, (uint64_t)(0.005 * NSEC_PER_SEC));

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        VCamPreviewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf renderNextFrame];
    });

    dispatch_resume(_timer);
    _timerRunning = YES;
    VCamLog(@"VCamPreviewController: preview timer started");
}

- (void)stopTimerIfNeeded {
    if (!_timerRunning) return;

    _timerRunning = NO;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    VCamLog(@"VCamPreviewController: preview timer stopped");
}

- (void)renderNextFrame {
    if (_stopped) return;

    VCamEngine *engine = [VCamEngine sharedEngine];
    if (!engine.enabled || !engine.previewEnabled) return;

    // If frame hasn't advanced, nothing to do (especially for static photo)
    if (engine.frameSerial != 0 && engine.frameSerial == _lastRenderedSerial) {
        return;
    }

    CGImageRef cg = [engine copyCurrentPreviewCGImage];
    if (!cg) return;

    _lastRenderedSerial = engine.frameSerial;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VCamPreviewController *strongSelf = weakSelf;
        if (strongSelf && !strongSelf->_stopped && strongSelf->_overlayLayer) {
            if (!strongSelf->_overlayLayer.hidden && strongSelf->_previewLayer.superlayer != nil) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                strongSelf->_overlayLayer.contents = (__bridge id)cg;
                [CATransaction commit];
            }
        }
        CGImageRelease(cg);
    });
}

- (void)stop {
    if (_stopped) return;
    _stopped = YES;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTimerIfNeeded];

    if (_overlayLayer) {
        [_overlayLayer removeFromSuperlayer];
        _overlayLayer = nil;
    }
    _previewLayer = nil;
    VCamLog(@"VCamPreviewController: stopped and torn down");
}

- (void)dealloc {
    [self stop];
}

@end
