#import "VCamEngine.h"
#import <objc/runtime.h>
#import <objc/message.h>

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) {
        %orig(sampleBuffer);
        return;
    }

    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) {
        %orig(sampleBuffer);
        return;
    }

    // Prevent double-processing identical PTS on multiple internal pipeline outputs
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    static CMTime lastProcessedPTS = {0};
    if (CMTIME_IS_VALID(pts) && CMTIME_COMPARE_INLINE(pts, ==, lastProcessedPTS)) {
        %orig(sampleBuffer);
        return;
    }
    lastProcessedPTS = pts;

    VCamEngine *engine = [VCamEngine sharedEngine];
    if (engine.enabled) {
        [engine processFrame:imageBuffer];
    }

    %orig(sampleBuffer);
}

%end

%ctor {
    @autoreleasepool {
        VCamEngine *engine = [VCamEngine sharedEngine];
        [engine startListeningForNotifications];
        [engine reloadPreferences];
        [engine loadMedia];
    }
}
