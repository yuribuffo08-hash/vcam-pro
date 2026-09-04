#import "VCamEngine.h"
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
                if (origMethod) {
                    IMP origImp = method_getImplementation(origMethod);

                    void (^swizzledBlock)(id, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = 
                    ^(id selfDelegate, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
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
                }
            }
        }
    }

    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

%ctor {
    @autoreleasepool {
        [[VCamEngine sharedEngine] reloadPreferences];
    }
}
