#ifndef VCamEngine_h
#define VCamEngine_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

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
- (void)reloadPreferences;
- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer;

@end

#endif /* VCamEngine_h */
