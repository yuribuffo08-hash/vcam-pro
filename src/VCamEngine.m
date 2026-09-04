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
    BOOL _debugFill;   // solid-colour test: see if the buffer we write feeds the preview
    BOOL _loggedFormat;
}
@end

// FourCC (e.g. '420v', 'BGRA') of a pixel format, for logging.
static NSString *VCamFourCC(OSType t) {
    char c[5] = { (char)((t >> 24) & 0xFF), (char)((t >> 16) & 0xFF),
                  (char)((t >> 8) & 0xFF), (char)(t & 0xFF), 0 };
    return [NSString stringWithFormat:@"%s", c];
}

// Fill a pixel buffer with a solid colour, handling BGRA and biplanar YUV.
// Purely a diagnostic: if the on-screen preview turns this colour, the buffer
// we overwrite is the one the app displays; if not, the preview is a separate
// path (e.g. AVCaptureVideoPreviewLayer) our hook cannot reach.
static void VCamFillSolid(CVPixelBufferRef pb) {
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) return;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    if (CVPixelBufferIsPlanar(pb)) {
        // Y plane -> mid, CbCr -> shifted => vivid magenta-ish, unmistakable.
        void *yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        size_t yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t yH = CVPixelBufferGetHeightOfPlane(pb, 0);
        if (yPlane) memset(yPlane, 0x80, yBpr * yH);
        if (CVPixelBufferGetPlaneCount(pb) > 1) {
            void *cPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
            size_t cBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            size_t cH = CVPixelBufferGetHeightOfPlane(pb, 1);
            if (cPlane) memset(cPlane, 0xFF, cBpr * cH);
        }
    } else {
        void *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t h = CVPixelBufferGetHeight(pb);
        if (base) memset(base, (fmt == kCVPixelFormatType_32BGRA) ? 0xC0 : 0x80, bpr * h);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

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

        // NOTE: do NOT null out the output/working colour spaces. Camera buffers
        // are usually YUV (420v/420f); with colour management disabled CIContext
        // will not perform the RGB->YUV conversion and render:toCVPixelBuffer:
        // effectively no-ops, which is why injected frames never showed.
        _ciContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
        if (!_ciContext) {
            _ciContext = [CIContext context];
        }

        // Diagnostic toggle: create this file in Filza to force a solid-colour
        // fill (no rebuild needed) and see whether the preview reacts.
        _debugFill = [NSFileManager.defaultManager fileExistsAtPath:
            @"/var/jb/var/mobile/Library/Preferences/vcam_testfill"];
        _loggedFormat = NO;

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

    // Log the real target format once: tells us YUV vs BGRA, size, IOSurface.
    if (!_loggedFormat) {
        _loggedFormat = YES;
        OSType fmt = CVPixelBufferGetPixelFormatType(targetPixelBuffer);
        VCamLog(@"processFrame: target fmt=%@(0x%08x) %zux%zu planar=%d iosurface=%d",
                VCamFourCC(fmt), (unsigned)fmt,
                CVPixelBufferGetWidth(targetPixelBuffer),
                CVPixelBufferGetHeight(targetPixelBuffer),
                CVPixelBufferIsPlanar(targetPixelBuffer),
                CVPixelBufferGetIOSurface(targetPixelBuffer) != NULL);
    }

    // Diagnostic: paint the buffer a solid colour and stop. If the preview turns
    // that colour, this buffer IS what the app shows and the render path is the
    // bug; if the preview is unchanged, the app draws from a separate path.
    if (_debugFill) {
        VCamFillSolid(targetPixelBuffer);
        static dispatch_once_t fillOnce;
        dispatch_once(&fillOnce, ^{ VCamLog(@"processFrame: DEBUG solid fill active (vcam_testfill present)"); });
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
            _ciContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
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

#pragma mark - Still capture (photo path)

// Current fake frame as a CIImage. For video, reads the next frame (looping).
// Caller must CFRelease *sampleOut if non-NULL after it is done with the image.
- (CIImage *)currentStillCIImage:(CMSampleBufferRef *)sampleOut {
    if (sampleOut) *sampleOut = NULL;
    if (!_mediaLoaded) [self loadMedia];

    CIImage *img = nil;
    [_lock lock];
    @try {
        if (_sourceType == VCamSourceTypeImage) {
            if (_loadedCGImage) img = [CIImage imageWithCGImage:_loadedCGImage];
        } else {
            if (!_videoReadingStarted) [self setupVideoReader];
            if (_readerOutput) {
                CMSampleBufferRef s = [_readerOutput copyNextSampleBuffer];
                if (!s && _loopEnabled) {
                    [self setupVideoReader];
                    if (_readerOutput) s = [_readerOutput copyNextSampleBuffer];
                }
                if (s) {
                    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(s);
                    if (pb) {
                        img = [CIImage imageWithCVPixelBuffer:pb];
                        if (sampleOut) *sampleOut = s; else CFRelease(s);
                    } else {
                        CFRelease(s);
                    }
                }
            }
        }
    } @finally {
        [_lock unlock];
    }
    return img;
}

- (CGImageRef)copyCurrentStillCGImage {
    if (!_enabled) return NULL;
    CGImageRef cg = NULL;
    @autoreleasepool {
        CMSampleBufferRef s = NULL;
        CIImage *img = [self currentStillCIImage:&s];
        if (img) {
            if (!_ciContext) {
                _ciContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
                if (!_ciContext) _ciContext = [CIContext context];
            }
            if (_ciContext) cg = [_ciContext createCGImage:img fromRect:img.extent];
        }
        if (s) CFRelease(s);
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ VCamLog(@"copyCurrentStillCGImage: first still %@", cg ? @"produced" : @"FAILED"); });
    return cg; // +1, caller releases
}

- (NSData *)currentStillJPEG {
    CGImageRef cg = [self copyCurrentStillCGImage];
    if (!cg) return nil;
    NSData *data = nil;
    @autoreleasepool {
        UIImage *ui = [UIImage imageWithCGImage:cg];
        data = UIImageJPEGRepresentation(ui, 0.95);
    }
    CGImageRelease(cg);
    return data;
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
