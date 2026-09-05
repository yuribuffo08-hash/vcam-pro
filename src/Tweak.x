#import "VCamEngine.h"
#import "VCamLog.h"
#import "VCamPreviewController.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// Photo path. Apps that take a still use AVCapturePhotoOutput and read the
// result from the AVCapturePhoto handed to their delegate — NOT from the video
// data-output stream. Overriding these accessors replaces the captured photo
// with the fake frame, so the photo the app saves/sends is ours.
// ---------------------------------------------------------------------------
%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    VCamEngine *engine = [VCamEngine sharedEngine];
    if (engine.enabled) {
        NSData *fake = [engine currentStillJPEG];
        if (fake.length) {
            VCamLog(@"AVCapturePhoto.fileDataRepresentation -> fake %lu bytes", (unsigned long)fake.length);
            return fake;
        }
    }
    return %orig;
}

- (CGImageRef)CGImageRepresentation {
    VCamEngine *engine = [VCamEngine sharedEngine];
    if (engine.enabled) {
        CGImageRef cg = [engine copyCurrentStillCGImage];
        if (cg) {
            VCamLog(@"AVCapturePhoto.CGImageRepresentation -> fake image");
            return (CGImageRef)CFAutorelease(cg); // valid for the callback scope
        }
    }
    return %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        Class delegateClass = [sampleBufferDelegate class];
        static NSMutableSet *hookedClasses = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            hookedClasses = [[NSMutableSet alloc] init];
        });

        @synchronized(hookedClasses) {
            if (![hookedClasses containsObject:delegateClass]) {
                [hookedClasses addObject:delegateClass];

                SEL targetSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                Method origMethod = class_getInstanceMethod(delegateClass, targetSel);
                VCamLog(@"setSampleBufferDelegate: delegate=%@ hasCaptureOutput=%@",
                        NSStringFromClass(delegateClass), origMethod ? @"YES" : @"NO");
                if (origMethod) {
                    IMP origImp = method_getImplementation(origMethod);

                    void (^swizzledBlock)(id, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
                    ^(id selfDelegate, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                        static dispatch_once_t frameOnce;
                        dispatch_once(&frameOnce, ^{ VCamLog(@"first captureOutput frame delivered on %@", NSStringFromClass(delegateClass)); });
                        VCamEngine *engine = [VCamEngine sharedEngine];
                        if (engine.enabled && sampleBuffer) {
                            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                            if (pixelBuffer) {
                                [engine processFrame:pixelBuffer connection:connection];
                            } else if (engine.audioEnabled) {
                                [engine processAudioSampleBuffer:sampleBuffer];
                            }
                        }
                        ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origImp)(selfDelegate, targetSel, output, sampleBuffer, connection);
                    };

                    IMP newImp = imp_implementationWithBlock(swizzledBlock);
                    class_replaceMethod(delegateClass, targetSel, newImp, method_getTypeEncoding(origMethod));
                    VCamLog(@"hook installed on %@", NSStringFromClass(delegateClass));
                }
            }
        }
    }

    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        Class delegateClass = [sampleBufferDelegate class];
        static NSMutableSet *hookedAudioClasses = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            hookedAudioClasses = [[NSMutableSet alloc] init];
        });

        @synchronized(hookedAudioClasses) {
            if (![hookedAudioClasses containsObject:delegateClass]) {
                [hookedAudioClasses addObject:delegateClass];

                SEL targetSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                Method origMethod = class_getInstanceMethod(delegateClass, targetSel);
                VCamLog(@"setSampleBufferDelegate (audio): delegate=%@ hasCaptureOutput=%@",
                        NSStringFromClass(delegateClass), origMethod ? @"YES" : @"NO");
                if (origMethod) {
                    IMP origImp = method_getImplementation(origMethod);

                    void (^audioBlock)(id, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
                    ^(id selfDelegate, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                        VCamEngine *engine = [VCamEngine sharedEngine];
                        if (engine.enabled && engine.audioEnabled && sampleBuffer) {
                            [engine processAudioSampleBuffer:sampleBuffer];
                        }
                        ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origImp)(selfDelegate, targetSel, output, sampleBuffer, connection);
                    };

                    IMP newImp = imp_implementationWithBlock(audioBlock);
                    class_replaceMethod(delegateClass, targetSel, newImp, method_getTypeEncoding(origMethod));
                    VCamLog(@"audio hook installed on %@", NSStringFromClass(delegateClass));
                }
            }
        }
    }

    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

static char kVCamPreviewControllerKey;

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    self = %orig;
    if (self) {
        VCamPreviewController *ctrl = [[VCamPreviewController alloc] initWithPreviewLayer:self];
        objc_setAssociatedObject(self, &kVCamPreviewControllerKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
    self = %orig;
    if (self) {
        VCamPreviewController *ctrl = [[VCamPreviewController alloc] initWithPreviewLayer:self];
        objc_setAssociatedObject(self, &kVCamPreviewControllerKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (instancetype)init {
    self = %orig;
    if (self) {
        VCamPreviewController *ctrl = [[VCamPreviewController alloc] initWithPreviewLayer:self];
        objc_setAssociatedObject(self, &kVCamPreviewControllerKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    VCamPreviewController *ctrl = objc_getAssociatedObject(self, &kVCamPreviewControllerKey);
    if (!ctrl) {
        ctrl = [[VCamPreviewController alloc] initWithPreviewLayer:self];
        objc_setAssociatedObject(self, &kVCamPreviewControllerKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [ctrl updateSession];
}

- (void)layoutSublayers {
    %orig;
    VCamPreviewController *ctrl = objc_getAssociatedObject(self, &kVCamPreviewControllerKey);
    if (!ctrl) {
        ctrl = [[VCamPreviewController alloc] initWithPreviewLayer:self];
        objc_setAssociatedObject(self, &kVCamPreviewControllerKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [ctrl updateLayout];
}

- (void)removeFromSuperlayer {
    VCamPreviewController *ctrl = objc_getAssociatedObject(self, &kVCamPreviewControllerKey);
    if (ctrl) {
        [ctrl layerDidRemoveFromSuperlayer];
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    VCamPreviewController *ctrl = objc_getAssociatedObject(self, &kVCamPreviewControllerKey);
    if (ctrl) {
        [ctrl updateVisibility];
    }
}

- (void)setOpacity:(float)opacity {
    %orig;
    VCamPreviewController *ctrl = objc_getAssociatedObject(self, &kVCamPreviewControllerKey);
    if (ctrl) {
        [ctrl updateVisibility];
    }
}

- (void)dealloc {
    VCamPreviewController *ctrl = objc_getAssociatedObject(self, &kVCamPreviewControllerKey);
    if (ctrl) {
        [ctrl stop];
        objc_setAssociatedObject(self, &kVCamPreviewControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleId) {
            return;
        }

        // Strictly exclude SpringBoard, Preferences, and system UI processes to prevent respring loops
        if ([bundleId isEqualToString:@"com.apple.springboard"] ||
            [bundleId hasPrefix:@"com.apple.springboard."] ||
            [bundleId isEqualToString:@"com.apple.Preferences"] ||
            [bundleId isEqualToString:@"com.apple.backboardd"] ||
            [bundleId isEqualToString:@"com.apple.CoreAuthUI"] ||
            [bundleId isEqualToString:@"com.apple.InCallService"] ||
            [bundleId isEqualToString:@"com.apple.ScreenSharingViewService"]) {
            return;
        }

        VCamLog(@"loaded in %@", bundleId);
        %init;
    }
}
