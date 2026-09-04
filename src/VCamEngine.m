#import "VCamEngine.h"
#import "VCamLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

static NSString *const kPrefsFileName = @"com.vcam.pro.plist";
static NSString *const kVideoFileName = @"vcam_source.mp4";
static NSString *const kImageFileName = @"vcam_source.png";

// Candidate directories, in priority order, that hold shared config + media.
// On Dopamine ROOTLESS the App Store app sandbox BLOCKS /var/mobile/Library/
// Preferences (confirmed on-device: reloadPreferences prefsReadable=NO from
// Telegram), so the rootless apex /var/jb is tried first: the injected dylib
// itself loads from /var/jb/Library/MobileSubstrate, so the target process can
// reach that apex. The legacy path is kept last only as a fallback.
static NSArray<NSString *> *VCamSharedDirs(void) {
    static NSArray *dirs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dirs = @[
            @"/var/jb/var/mobile/Library/Preferences",
            @"/var/jb/tmp",
            @"/var/mobile/Library/Preferences",
        ];
    });
    return dirs;
}

// First existing file with this basename across the candidate dirs, or nil.
static NSString *VCamFindExistingFile(NSString *fileName) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in VCamSharedDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:fileName];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// First readable prefs plist across the candidate dirs; reports where it came from.
static NSDictionary *VCamReadSharedPrefs(NSString **outPath) {
    for (NSString *dir in VCamSharedDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:kPrefsFileName];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) { if (outPath) *outPath = p; return d; }
    }
    return nil;
}

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
        _mediaPath = nil; // resolved from prefs / by searching the shared dirs
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

        [self probeSharedPaths];
        [self reloadPreferences];
        [self startListeningForNotifications];
    }
    return self;
}

// One-shot diagnostic: which of the candidate dirs can this (possibly sandboxed)
// process actually read and write? Logged once so a wrong storage location shows
// up immediately in the on-device log instead of costing a build cycle to guess.
- (void)probeSharedPaths {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in VCamSharedDirs()) {
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:dir isDirectory:&isDir];
        BOOL readable = [fm isReadableFileAtPath:dir];
        NSString *probe = [dir stringByAppendingPathComponent:@".vcam_probe"];
        BOOL writable = [@"x" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (writable) [fm removeItemAtPath:probe error:nil];
        VCamLog(@"probe dir=%@ exists=%d isDir=%d readable=%d writable=%d",
                dir, exists, isDir, readable, writable);
    }
    NSString *prefsAt = nil;
    NSDictionary *d = VCamReadSharedPrefs(&prefsAt);
    VCamLog(@"probe prefs found=%@ at=%@", d ? @"YES" : @"NO", prefsAt ?: @"(none)");
    VCamLog(@"probe media video=%@ image=%@",
            VCamFindExistingFile(kVideoFileName) ?: @"(none)",
            VCamFindExistingFile(kImageFileName) ?: @"(none)");
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
    NSString *prefsAt = nil;
    NSDictionary *prefs = VCamReadSharedPrefs(&prefsAt);
    VCamLog(@"reloadPreferences: prefsReadable=%@ at=%@ enabled=%@ sourceType=%@ mediaPath=%@",
            prefs ? @"YES" : @"NO", prefsAt ?: @"(none)",
            prefs[@"enabled"], prefs[@"sourceType"], prefs[@"mediaPath"]);
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
    if (_mediaPath.length == 0 || ![fm fileExistsAtPath:_mediaPath]) {
        if (_mediaPath.length) {
            VCamLog(@"loadMedia: configured mediaPath NOT found: %@ -> searching shared dirs", _mediaPath);
        }
        // Search the candidate dirs by conventional basename, preferring the
        // configured source type but falling back to whichever media exists.
        NSString *found = nil;
        if (_sourceType == VCamSourceTypeVideo) {
            found = VCamFindExistingFile(kVideoFileName) ?: VCamFindExistingFile(kImageFileName);
        } else {
            found = VCamFindExistingFile(kImageFileName) ?: VCamFindExistingFile(kVideoFileName);
        }
        if (found) {
            _mediaPath = found;
            VCamLog(@"loadMedia: resolved media from shared dirs: %@", _mediaPath);
        } else {
            VCamLog(@"loadMedia: no usable media file (sandbox block or not selected) -> nothing to inject");
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
        VCamLog(@"loadMedia: image %@ loaded=%@ size=%.0fx%.0f",
                _mediaPath, _loadedCGImage ? @"YES" : @"NO",
                img ? img.size.width : 0, img ? img.size.height : 0);
    } else if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"]) {
        _sourceType = VCamSourceTypeVideo;
        NSURL *videoURL = [NSURL fileURLWithPath:_mediaPath];
        _videoAsset = [AVAsset assetWithURL:videoURL];
        BOOL ok = [self setupVideoReader];
        VCamLog(@"loadMedia: video %@ readerStarted=%@", _mediaPath, ok ? @"YES" : @"NO");
    }

    _mediaLoaded = YES;
    [_lock unlock];
}

- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer {
    if (!_enabled || !targetPixelBuffer) {
        return;
    }

    static dispatch_once_t enterOnce;
    dispatch_once(&enterOnce, ^{ VCamLog(@"processFrame: first call, enabled=%d sourceType=%ld", (int)_enabled, (long)_sourceType); });

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
        static dispatch_once_t renderOnce;
        dispatch_once(&renderOnce, ^{ VCamLog(@"processFrame: first render into %zux%zu target buffer", targetW, targetH); });

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
