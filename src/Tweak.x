#import "VCamEngine.h"
#import "VCamLog.h"
#import "VCamPreviewController.h"
#import "VCamWebInjector.h"
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

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

static void VCamHookSampleBufferDelegateIfNeeded(Class delegateClass) {
    if (!delegateClass) return;

    static NSMutableSet *hookedClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hookedClasses = [[NSMutableSet alloc] init];
    });

    @synchronized(hookedClasses) {
        if ([hookedClasses containsObject:delegateClass]) {
            return;
        }
        [hookedClasses addObject:delegateClass];

        SEL targetSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method origMethod = class_getInstanceMethod(delegateClass, targetSel);
        VCamLog(@"VCamHookSampleBufferDelegate: delegate=%@ hasCaptureOutput=%@",
                NSStringFromClass(delegateClass), origMethod ? @"YES" : @"NO");
        if (origMethod) {
            IMP origImp = method_getImplementation(origMethod);

            void (^unifiedBlock)(id, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
            ^(id selfDelegate, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                VCamEngine *engine = [VCamEngine sharedEngine];
                if (engine.enabled && sampleBuffer) {
                    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                        if (pixelBuffer) {
                            [engine processFrame:pixelBuffer connection:connection];
                        }
                    } else if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
                        if (engine.audioEnabled) {
                            [engine processAudioSampleBuffer:sampleBuffer];
                        }
                    } else {
                        // Fallback check based on sample buffer contents
                        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                        if (pixelBuffer) {
                            [engine processFrame:pixelBuffer connection:connection];
                        } else if (engine.audioEnabled) {
                            [engine processAudioSampleBuffer:sampleBuffer];
                        }
                    }
                }
                ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origImp)(selfDelegate, targetSel, output, sampleBuffer, connection);
            };

            IMP newImp = imp_implementationWithBlock(unifiedBlock);
            class_replaceMethod(delegateClass, targetSel, newImp, method_getTypeEncoding(origMethod));
            VCamLog(@"unified captureOutput hook installed on %@", NSStringFromClass(delegateClass));
        }
    }
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        VCamHookSampleBufferDelegateIfNeeded([sampleBufferDelegate class]);
    }
    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        VCamHookSampleBufferDelegateIfNeeded([sampleBufferDelegate class]);
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

// ---------------------------------------------------------------------------
// WebKit / Safari Web View Hooks (Deep DOM Swap)
// Injects the custom getUserMedia interception script into every WKWebView
// ---------------------------------------------------------------------------

%hook WKUserContentController

- (instancetype)init {
    self = %orig;
    if (self) {
        [[VCamWebInjector sharedInjector] injectIntoUserContentController:self];
    }
    return self;
}

- (void)addUserScript:(WKUserScript *)userScript {
    [[VCamWebInjector sharedInjector] injectIntoUserContentController:self];
    %orig(userScript);
}

%end

%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if (configuration && configuration.userContentController) {
        [[VCamWebInjector sharedInjector] injectIntoUserContentController:configuration.userContentController];
    }
    self = %orig(frame, configuration);
    return self;
}

%end

// ---------------------------------------------------------------------------
// WebCore Native Video Capture Observer Hook
// If the WebKit GPU process runs native camera capture, this intercepts frames
// ---------------------------------------------------------------------------

%group WebCoreGroup

%hook WebCoreAVVideoCaptureSourceObserver

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    VCamEngine *engine = [VCamEngine sharedEngine];
    if (engine.enabled && sampleBuffer) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            [engine processFrame:pixelBuffer connection:connection];
        }
    }
    %orig(captureOutput, sampleBuffer, connection);
}

%end

%end

%ctor {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        NSString *procName = [[NSProcessInfo processInfo] processName];
        NSString *identifier = bundleId ?: procName;
        if (!identifier) {
            return;
        }

        // Strictly exclude SpringBoard, Preferences, and system UI processes to prevent respring loops
        if ([identifier isEqualToString:@"com.apple.springboard"] ||
            [identifier hasPrefix:@"com.apple.springboard."] ||
            [identifier isEqualToString:@"com.apple.Preferences"] ||
            [identifier isEqualToString:@"com.apple.backboardd"] ||
            [identifier isEqualToString:@"com.apple.CoreAuthUI"] ||
            [identifier isEqualToString:@"com.apple.InCallService"] ||
            [identifier isEqualToString:@"com.apple.ScreenSharingViewService"] ||
            [identifier isEqualToString:@"mediaserverd"] ||
            [identifier isEqualToString:@"SpringBoard"] ||
            [identifier isEqualToString:@"Preferences"]) {
            return;
        }

        // Ensure frameworks are loaded into the runtime before installing hooks
        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_NOW);
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/WebCore.framework/WebCore", RTLD_NOW);

        VCamLog(@"loaded in identifier=%@ (bundle=%@, proc=%@)", identifier, bundleId, procName);
        %init;
        Class observerClass = objc_getClass("WebCoreAVVideoCaptureSourceObserver");
        if (observerClass) {
            %init(WebCoreGroup, WebCoreAVVideoCaptureSourceObserver = observerClass);
            VCamLog(@"WebCoreAVVideoCaptureSourceObserver hooked successfully");
        }
    }
}

