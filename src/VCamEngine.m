#import "VCamEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.vcam.pro.plist";
static NSString *const kDefaultVideoPath = @"/var/mobile/Media/DCIM/vcam_source.mp4";
static NSString *const kDefaultImagePath = @"/var/mobile/Media/DCIM/vcam_source.png";
static CFStringRef const kVCamPrefsNotification = CFSTR("com.vcam.pro/preferencesChanged");

static void OnPrefsChangedNotification(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[VCamEngine sharedEngine] reloadPreferences];
}

@interface VCamEngine () {
    CGImageRef _loadedCGImage;
    AVAsset *_videoAsset;
    AVAssetReader *_assetReader;
    AVAssetReaderTrackOutput *_readerOutput;
    BOOL _videoReadingStarted;
    CIContext *_ciContext;
    NSLock *_lock;
    BOOL _mediaLoaded;
}
@end

@implementation VCamEngine

+ (instancetype)sharedEngine {
    static VCamEngine *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _enabled = YES;
        _sourceType = VCamSourceTypeVideo;
        _loopEnabled = YES;
        _mediaPath = kDefaultVideoPath;
        _mediaLoaded = NO;
        _videoReadingStarted = NO;

        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextWorkingColorSpace: [NSNull null],
            kCIContextOutputColorSpace: [NSNull null]
        };
        _ciContext = [CIContext contextWithOptions:options];
        if (!_ciContext) {
            _ciContext = [CIContext context];
        }

        [self reloadPreferences];
        [self startListeningForNotifications];
    }
    return self;
}

- (void)startListeningForNotifications {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        OnPrefsChangedNotification,
        kVCamPrefsNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

- (void)reloadPreferences {
    [_lock lock];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (prefs) {
        if (prefs[@"enabled"] != nil) {
            _enabled = [prefs[@"enabled"] boolValue];
        }
        if (prefs[@"sourceType"] != nil) {
            _sourceType = (VCamSourceType)[prefs[@"sourceType"] integerValue];
        }
        if (prefs[@"loopEnabled"] != nil) {
            _loopEnabled = [prefs[@"loopEnabled"] boolValue];
        }
        if (prefs[@"mediaPath"] && [prefs[@"mediaPath"] length] > 0) {
            _mediaPath = [prefs[@"mediaPath"] copy];
        }
    }
    _mediaLoaded = NO;
    [_lock unlock];
}

- (void)cleanupVideoReader {
    if (_assetReader) {
        if (_assetReader.status == AVAssetReaderStatusReading) {
            [_assetReader cancelReading];
        }
        _assetReader = nil;
    }
    _readerOutput = nil;
    _videoReadingStarted = NO;
}

- (BOOL)setupVideoReader {
    [self cleanupVideoReader];

    if (!_videoAsset) {
        return NO;
    }

    NSError *error = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_videoAsset error:&error];
    if (error || !_assetReader) {
        _assetReader = nil;
        return NO;
    }

    NSArray *tracks = [_videoAsset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        [self cleanupVideoReader];
        return NO;
    }

    AVAssetTrack *videoTrack = tracks[0];
    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    _readerOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    _readerOutput.alwaysCopiesSampleData = NO;

    if ([_assetReader canAddOutput:_readerOutput]) {
        [_assetReader addOutput:_readerOutput];
        if ([_assetReader startReading]) {
            _videoReadingStarted = YES;
            return YES;
        }
    }

    [self cleanupVideoReader];
    return NO;
}

- (void)loadMedia {
    [_lock lock];
    if (_mediaLoaded) {
        [_lock unlock];
        return;
    }

    if (_loadedCGImage) {
        CGImageRelease(_loadedCGImage);
        _loadedCGImage = NULL;
    }
    [self cleanupVideoReader];
    _videoAsset = nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_mediaPath]) {
        if (_sourceType == VCamSourceTypeVideo && [fm fileExistsAtPath:kDefaultVideoPath]) {
            _mediaPath = kDefaultVideoPath;
        } else if (_sourceType == VCamSourceTypeImage && [fm fileExistsAtPath:kDefaultImagePath]) {
            _mediaPath = kDefaultImagePath;
        } else {
            _mediaLoaded = YES;
            [_lock unlock];
            return;
        }
    }

    NSString *ext = [[_mediaPath pathExtension] lowercaseString];
    if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
        _sourceType = VCamSourceTypeImage;
        UIImage *img = [UIImage imageWithContentsOfFile:_mediaPath];
        if (img && img.CGImage) {
            _loadedCGImage = CGImageRetain(img.CGImage);
        }
    } else if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"]) {
        _sourceType = VCamSourceTypeVideo;
        NSURL *videoURL = [NSURL fileURLWithPath:_mediaPath];
        _videoAsset = [AVAsset assetWithURL:videoURL];
        [self setupVideoReader];
    }

    _mediaLoaded = YES;
    [_lock unlock];
}

- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer {
    if (!_enabled || !targetPixelBuffer) {
        return;
    }

    if (!_mediaLoaded) {
        [self loadMedia];
    }

    @autoreleasepool {
        CIImage *sourceImage = nil;
        CMSampleBufferRef videoSampleToRelease = NULL;

        [_lock lock];
        @try {
            if (_sourceType == VCamSourceTypeImage) {
                if (_loadedCGImage) {
                    sourceImage = [CIImage imageWithCGImage:_loadedCGImage];
                }
            } else if (_sourceType == VCamSourceTypeVideo) {
                if (!_videoReadingStarted) {
                    [self setupVideoReader];
                }

                if (_readerOutput) {
                    CMSampleBufferRef sample = [_readerOutput copyNextSampleBuffer];
                    if (!sample && _loopEnabled) {
                        [self setupVideoReader];
                        if (_readerOutput) {
                            sample = [_readerOutput copyNextSampleBuffer];
                        }
                    }

                    if (sample) {
                        CVPixelBufferRef frameBuf = CMSampleBufferGetImageBuffer(sample);
                        if (frameBuf) {
                            sourceImage = [CIImage imageWithCVPixelBuffer:frameBuf];
                            videoSampleToRelease = sample;
                        } else {
                            CFRelease(sample);
                        }
                    }
                }
            }
        } @finally {
            [_lock unlock];
        }

        if (!sourceImage) {
            return;
        }

        if (!_ciContext) {
            NSDictionary *options = @{
                kCIContextUseSoftwareRenderer: @(NO),
                kCIContextWorkingColorSpace: [NSNull null],
                kCIContextOutputColorSpace: [NSNull null]
            };
            _ciContext = [CIContext contextWithOptions:options];
            if (!_ciContext) {
                _ciContext = [CIContext context];
            }
        }

        if (!_ciContext) {
            if (videoSampleToRelease) CFRelease(videoSampleToRelease);
            return;
        }

        size_t targetW = CVPixelBufferGetWidth(targetPixelBuffer);
        size_t targetH = CVPixelBufferGetHeight(targetPixelBuffer);
        CGRect extent = sourceImage.extent;
        if (extent.size.width <= 0 || extent.size.height <= 0 || targetW <= 0 || targetH <= 0) {
            if (videoSampleToRelease) CFRelease(videoSampleToRelease);
            return;
        }

        CGFloat scaleX = (CGFloat)targetW / extent.size.width;
        CGFloat scaleY = (CGFloat)targetH / extent.size.height;
        CGFloat scale = MAX(scaleX, scaleY);

        CGAffineTransform tScale = CGAffineTransformMakeScale(scale, scale);
        CIImage *scaled = [sourceImage imageByApplyingTransform:tScale];

        CGRect scaledExtent = scaled.extent;
        CGFloat offsetX = ((CGFloat)targetW - scaledExtent.size.width) / 2.0;
        CGFloat offsetY = ((CGFloat)targetH - scaledExtent.size.height) / 2.0;
        CIImage *final = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

        [_ciContext render:final toCVPixelBuffer:targetPixelBuffer];

        if (videoSampleToRelease) {
            CFRelease(videoSampleToRelease);
        }
    }
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        kVCamPrefsNotification,
        NULL
    );
    if (_loadedCGImage) {
        CGImageRelease(_loadedCGImage);
        _loadedCGImage = NULL;
    }
    [self cleanupVideoReader];
}

@end
