#ifndef VCamEngine_h
#define VCamEngine_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, VCamSourceType) {
    VCamSourceTypeImage = 0,
    VCamSourceTypeVideo = 1
};

@interface VCamEngine : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) VCamSourceType sourceType;
@property (nonatomic, assign) BOOL loopEnabled;
@property (nonatomic, copy) NSString *mediaPath;

+ (instancetype)sharedEngine;
- (void)startListeningForNotifications;
- (void)reloadPreferences;
- (void)loadMedia;
- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer;

// Still-photo path (AVCapturePhotoOutput / AVCapturePhoto): produce the current
// fake frame as a still, so photo capture is replaced too — the video-data hook
// alone does not touch photos.
- (CGImageRef)copyCurrentStillCGImage CF_RETURNS_RETAINED; // caller releases
- (NSData *)currentStillJPEG;

@end

#endif /* VCamEngine_h */
