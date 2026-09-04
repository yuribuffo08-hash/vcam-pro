#import "VCamEngine.h"
#import "VCamLog.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
                                [engine processFrame:pixelBuffer];
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
