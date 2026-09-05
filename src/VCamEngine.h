#ifndef VCamEngine_h
#define VCamEngine_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

@class CIImage;
@class AVCaptureConnection;

typedef NS_ENUM(NSInteger, VCamSourceType) {
    VCamSourceTypeImage = 0,
    VCamSourceTypeVideo = 1
};

@interface VCamEngine : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL previewEnabled;   // live-preview overlay on/off
@property (nonatomic, assign) BOOL audioEnabled;     // replace mic with video audio
@property (nonatomic, assign) VCamSourceType sourceType;
@property (nonatomic, assign) BOOL loopEnabled;
@property (nonatomic, copy) NSString *mediaPath;
@property (nonatomic, readonly) uint64_t frameSerial;

+ (instancetype)sharedEngine;
- (void)startListeningForNotifications;
- (void)reloadPreferences;
- (void)loadMedia;
- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer;
- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer connection:(AVCaptureConnection *)connection;
- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// ---------------------------------------------------------------------------
// Shared frame clock.
//
// Three consumers now want "the fake frame that is current right now": the
// video-data stream (processFrame:), the still-photo path (AVCapturePhoto) and
// the live-preview overlay. Each one used to pull copyNextSampleBuffer itself,
// so with more than one active they stole frames from each other and playback
// ran at whatever rate the caller happened to fire at.
//
// currentSourceCIImage advances the reader against the wall clock and caches
// the result, so every consumer sees the same frame and the video plays at its
// own real speed regardless of how often it is asked.
// ---------------------------------------------------------------------------
- (CIImage *)currentSourceCIImage;

// Still-photo path (AVCapturePhotoOutput / AVCapturePhoto).
- (CGImageRef)copyCurrentStillCGImage CF_RETURNS_RETAINED; // caller releases
- (NSData *)currentStillJPEG;

// Live-preview path: same frame as above, rasterised and cached per frame so a
// 30 fps overlay does not re-render an image that has not changed.
- (CGImageRef)copyCurrentPreviewCGImage CF_RETURNS_RETAINED; // caller releases

@end

#endif /* VCamEngine_h */
