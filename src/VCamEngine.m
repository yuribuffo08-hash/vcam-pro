#import "VCamEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.vcam.pro.plist";
static NSString *const kDefaultMediaPath = @"/var/mobile/Media/DCIM/vcam_source.mp4";

@interface VCamEngine () {
    CGImageRef _loadedCGImage;
    NSMutableArray *_videoBufferQueue;
    NSUInteger _currentVideoIndex;
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
        _videoBufferQueue = [[NSMutableArray alloc] init];
        _currentVideoIndex = 0;
        _enabled = YES;
        _sourceType = VCamSourceTypeVideo;
        _loopEnabled = YES;
        _mediaPath = kDefaultMediaPath;
        _mediaLoaded = NO;
        _ciContext = nil;
    }
    return self;
}

- (void)reloadPreferences {
    [_lock lock];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (prefs) {
        if (prefs[@"enabled"]) {
            _enabled = [prefs[@"enabled"] boolValue];
        }
        if (prefs[@"sourceType"]) {
            _sourceType = (VCamSourceType)[prefs[@"sourceType"] integerValue];
        }
        if (prefs[@"loopEnabled"]) {
            _loopEnabled = [prefs[@"loopEnabled"] boolValue];
        }
        if (prefs[@"mediaPath"] && [prefs[@"mediaPath"] length] > 0) {
            _mediaPath = [prefs[@"mediaPath"] copy];
        }
    }
    _mediaLoaded = NO; // Force reload media on next frame
    [_lock unlock];
}

- (void)loadMedia {
    [_lock lock];
    if (_mediaLoaded) {
        [_lock unlock];
        return;
    }
    
    // Reset previous media
    if (_loadedCGImage) {
        CGImageRelease(_loadedCGImage);
        _loadedCGImage = NULL;
    }
    for (id buf in _videoBufferQueue) {
        CVPixelBufferRef pixelBuf = (__bridge CVPixelBufferRef)buf;
        CVPixelBufferRelease(pixelBuf);
    }
    [_videoBufferQueue removeAllObjects];
    _currentVideoIndex = 0;

    if (![[NSFileManager defaultManager] fileExistsAtPath:_mediaPath]) {
        _mediaLoaded = YES;
        [_lock unlock];
        return;
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
        AVAsset *asset = [AVAsset assetWithURL:videoURL];
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!error) {
            NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if (tracks.count > 0) {
                AVAssetTrack *track = tracks[0];
                NSDictionary *settings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
                AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
                output.alwaysCopiesSampleData = NO;
                if ([reader canAddOutput:output]) {
                    [reader addOutput:output];
                    [reader startReading];
                    
                    int maxFrames = 180; // Load up to 6 seconds safely
                    int count = 0;
                    while (reader.status == AVAssetReaderStatusReading && count < maxFrames) {
                        CMSampleBufferRef sampleBuf = [output copyNextSampleBuffer];
                        if (!sampleBuf) break;
                        CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(sampleBuf);
                        if (pixBuf) {
                            CVPixelBufferRetain(pixBuf);
                            [_videoBufferQueue addObject:(__bridge id)pixBuf];
                            count++;
                        }
                        CFRelease(sampleBuf);
                    }
                    [reader cancelReading];
                }
            }
        }
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
        [_lock lock];
        CIImage *sourceImage = nil;

        if (_sourceType == VCamSourceTypeImage && _loadedCGImage) {
            sourceImage = [CIImage imageWithCGImage:_loadedCGImage];
        } else if (_sourceType == VCamSourceTypeVideo && _videoBufferQueue.count > 0) {
            CVPixelBufferRef frameBuf = (__bridge CVPixelBufferRef)_videoBufferQueue[_currentVideoIndex];
            sourceImage = [CIImage imageWithCVPixelBuffer:frameBuf];
            if (_loopEnabled || _currentVideoIndex + 1 < _videoBufferQueue.count) {
                _currentVideoIndex = (_currentVideoIndex + 1) % _videoBufferQueue.count;
            }
        }
        [_lock unlock];

        if (!sourceImage) {
            return;
        }

        if (!_ciContext) {
            NSDictionary *options = @{ kCIContextUseSoftwareRenderer: @(NO) };
            _ciContext = [CIContext contextWithOptions:options];
            if (!_ciContext) {
                _ciContext = [CIContext context];
            }
        }

        if (!_ciContext) {
            return;
        }

        size_t targetW = CVPixelBufferGetWidth(targetPixelBuffer);
        size_t targetH = CVPixelBufferGetHeight(targetPixelBuffer);
        CGRect extent = sourceImage.extent;
        if (extent.size.width <= 0 || extent.size.height <= 0) {
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

        CVPixelBufferLockBaseAddress(targetPixelBuffer, 0);
        [_ciContext render:final toCVPixelBuffer:targetPixelBuffer];
        CVPixelBufferUnlockBaseAddress(targetPixelBuffer, 0);
    }
}

- (void)dealloc {
    if (_loadedCGImage) {
        CGImageRelease(_loadedCGImage);
    }
    for (id buf in _videoBufferQueue) {
        CVPixelBufferRef pixelBuf = (__bridge CVPixelBufferRef)buf;
        CVPixelBufferRelease(pixelBuf);
    }
}

@end
