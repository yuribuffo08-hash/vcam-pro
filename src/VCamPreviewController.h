#ifndef VCamPreviewController_h
#define VCamPreviewController_h

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

@interface VCamPreviewController : NSObject

@property (nonatomic, weak, readonly) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong, readonly) CALayer *overlayLayer;

- (instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer;
- (void)updateLayout;
- (void)updateVisibility;
- (void)updateSession;
- (void)layerDidRemoveFromSuperlayer;
- (void)stop;

@end

#endif /* VCamPreviewController_h */
