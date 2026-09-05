#import "VCamEngine.h"
#import "VCamLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudioTypes.h>

static NSString *const kPrefsFileName = @"com.vcam.pro.plist";
static NSString *const kVideoFileName = @"vcam_source.mp4";
static NSString *const kImageFileName = @"vcam_source.png";

// Candidate directories, in priority order, that hold shared config + media.
// On Dopamine ROOTLESS the App Store app sandbox BLOCKS /var/mobile/Library/
// Preferences (confirmed on-device: reloadPreferences prefsReadable=NO from
// Telegram), so the rootless apex /var/jb is tried first: the injected dylib
// itself loads from /var/jb/Library/MobileSubstrate, so the target process can
// reach that apex. /tmp is included as a universal fallback that even the most
// restrictive sandboxes (like com.apple.WebKit.GPU) can typically access.
// The legacy path is kept last only as a fallback.
static NSArray<NSString *> *VCamSharedDirs(void) {
    static NSArray *dirs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dirs = @[
            @"/var/jb/var/mobile/Library/Preferences",
            @"/var/jb/tmp",
            @"/tmp",
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
    CIContext *_videoContext;
    CIContext *_previewContext;
    NSLock *_lock;
    BOOL _mediaLoaded;
    BOOL _debugFill;   // solid-colour test: see if the buffer we write feeds the preview
    BOOL _loggedFormat;

    // --- audio track reader (completely independent from video) ---
    AVAssetReader *_audioAssetReader;
    AVAssetReaderTrackOutput *_audioTrackOutput;
    NSMutableData *_audioBuffer;
    NSLock *_audioLock;
    BOOL _audioReadingStarted;
    AudioStreamBasicDescription _activeAudioFormat;
    BOOL _hasActiveAudioFormat;

    // --- shared frame clock (see header) ---
    CMSampleBufferRef _currentSample;     // retained; backs _currentCIImage
    CIImage *_currentCIImage;             // the frame every consumer sees
    CIImage *_lastRenderedCIImage;        // fallback to ensure real camera never flashes
    CFTimeInterval _playbackStart;        // wall-clock origin of this play-through
    double _currentPTS;                   // presentation time of _currentCIImage, seconds
    double _videoStartPTS;                // first frame PTS, for normalized timing
    uint64_t _frameSerial;                // bumped whenever _currentCIImage changes
    CGAffineTransform _videoTransform;    // track preferredTransform (upright correction)
    BOOL _hasVideoTransform;

    // --- preview rasterisation cache ---
    CGImageRef _previewCGImage;
    uint64_t _previewCGSerial;
}
@end

// FourCC of a pixel format, for logging (e.g. 420v, BGRA).
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

- (uint64_t)frameSerial {
    return _frameSerial;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _audioLock = [[NSLock alloc] init];
        _audioBuffer = [[NSMutableData alloc] init];
        _enabled = YES;
        _previewEnabled = YES;
        _audioEnabled = YES;
        _sourceType = VCamSourceTypeVideo;
        _loopEnabled = YES;
        _mediaPath = nil; // resolved from prefs / by searching the shared dirs
        _mediaLoaded = NO;
        _videoReadingStarted = NO;
        _audioReadingStarted = NO;
        _videoTransform = CGAffineTransformIdentity;
        _hasVideoTransform = NO;
        _frameSerial = 0;
        _previewCGSerial = 0;
        _videoStartPTS = -1.0;
        _hasActiveAudioFormat = NO;

        _videoContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
        if (!_videoContext) _videoContext = [CIContext context];

        _previewContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
        if (!_previewContext) _previewContext = [CIContext context];

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
    VCamLog(@"reloadPreferences: prefsReadable=%@ at=%@ enabled=%@ preview=%@ sourceType=%@ mediaPath=%@",
            prefs ? @"YES" : @"NO", prefsAt ?: @"(none)",
            prefs[@"enabled"], prefs[@"previewEnabled"], prefs[@"sourceType"], prefs[@"mediaPath"]);
    if (prefs) {
        if (prefs[@"enabled"] != nil) {
            _enabled = [prefs[@"enabled"] boolValue];
        }
        if (prefs[@"previewEnabled"] != nil) {
            _previewEnabled = [prefs[@"previewEnabled"] boolValue];
        }
        if (prefs[@"audioEnabled"] != nil) {
            _audioEnabled = [prefs[@"audioEnabled"] boolValue];
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
    [self discardCurrentFrameLocked];
    [_lock unlock];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.vcam.pro.internalPrefsChanged" object:nil];
}

#pragma mark - Frame clock

// Drop the cached frame so the next request rebuilds it from the current media.
// Caller holds _lock.
- (void)discardCurrentFrameLocked {
    if (_currentSample) {
        CFRelease(_currentSample);
        _currentSample = NULL;
    }
    _currentCIImage = nil;
    _lastRenderedCIImage = nil;
    if (_previewCGImage) {
        CGImageRelease(_previewCGImage);
        _previewCGImage = NULL;
    }
    _playbackStart = 0;
    _currentPTS = 0;
    _videoStartPTS = -1.0;
    _frameSerial++;
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

    // AVAssetReaderTrackOutput hands back raw coded frames and does NOT apply
    // the track's preferredTransform, so a clip recorded in portrait arrives
    // rotated 90 degrees. Capture the transform once and apply it to every
    // frame (applyVideoTransform:) so the fake feed comes out upright.
    if (!_hasVideoTransform) {
        _videoTransform = videoTrack.preferredTransform;
        _hasVideoTransform = YES;
        VCamLog(@"setupVideoReader: preferredTransform a=%.2f b=%.2f c=%.2f d=%.2f natural=%.0fx%.0f",
                _videoTransform.a, _videoTransform.b, _videoTransform.c, _videoTransform.d,
                videoTrack.naturalSize.width, videoTrack.naturalSize.height);
    }

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    _readerOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    _readerOutput.alwaysCopiesSampleData = NO;

    if ([_assetReader canAddOutput:_readerOutput]) {
        [_assetReader addOutput:_readerOutput];
    } else {
        [self cleanupVideoReader];
        return NO;
    }

    if ([_assetReader startReading]) {
        _videoReadingStarted = YES;
        return YES;
    }

    [self cleanupVideoReader];
    return NO;
}

#pragma mark - Independent Audio Reader

- (void)cleanupAudioReaderLocked {
    if (_audioAssetReader) {
        if (_audioAssetReader.status == AVAssetReaderStatusReading) {
            [_audioAssetReader cancelReading];
        }
        _audioAssetReader = nil;
    }
    _audioTrackOutput = nil;
    _audioReadingStarted = NO;
    [_audioBuffer setLength:0];
}

- (BOOL)setupAudioReaderLockedWithFormat:(const AudioStreamBasicDescription *)asbd {
    if (_audioAssetReader) {
        if (_audioAssetReader.status == AVAssetReaderStatusReading) {
            [_audioAssetReader cancelReading];
        }
        _audioAssetReader = nil;
    }
    _audioTrackOutput = nil;
    _audioReadingStarted = NO;
    // Note: unconsumed bytes in _audioBuffer are preserved during loop restart

    if (!_videoAsset) {
        return NO;
    }

    NSArray *audioTracks = [_videoAsset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        return NO;
    }

    AVAssetTrack *audioTrack = audioTracks[0];
    NSError *error = nil;
    _audioAssetReader = [[AVAssetReader alloc] initWithAsset:_videoAsset error:&error];
    if (error || !_audioAssetReader) {
        _audioAssetReader = nil;
        return NO;
    }

    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    settings[AVFormatIDKey] = @(kAudioFormatLinearPCM);

    if (asbd && asbd->mFormatID == kAudioFormatLinearPCM) {
        double sampleRate = asbd->mSampleRate > 0 ? asbd->mSampleRate : 44100.0;
        uint32_t channels = asbd->mChannelsPerFrame > 0 ? asbd->mChannelsPerFrame : 2;
        uint32_t bitDepth = asbd->mBitsPerChannel > 0 ? asbd->mBitsPerChannel : 16;
        BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) ? YES : NO;
        BOOL isBigEndian = (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) ? YES : NO;
        BOOL isNonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? YES : NO;

        settings[AVSampleRateKey] = @(sampleRate);
        settings[AVNumberOfChannelsKey] = @(channels);
        settings[AVLinearPCMBitDepthKey] = @(bitDepth);
        settings[AVLinearPCMIsFloatKey] = @(isFloat);
        settings[AVLinearPCMIsBigEndianKey] = @(isBigEndian);
        settings[AVLinearPCMIsNonInterleaved] = @(isNonInterleaved);

        _activeAudioFormat = *asbd;
        _hasActiveAudioFormat = YES;
    } else {
        settings[AVSampleRateKey] = @(44100.0);
        settings[AVNumberOfChannelsKey] = @(2);
        settings[AVLinearPCMBitDepthKey] = @(16);
        settings[AVLinearPCMIsFloatKey] = @(NO);
        settings[AVLinearPCMIsBigEndianKey] = @(NO);
        settings[AVLinearPCMIsNonInterleaved] = @(NO);
        _hasActiveAudioFormat = NO;
    }

    _audioTrackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:settings];
    _audioTrackOutput.alwaysCopiesSampleData = NO;

    if ([_audioAssetReader canAddOutput:_audioTrackOutput]) {
        [_audioAssetReader addOutput:_audioTrackOutput];
    } else {
        // Fallback to standard 16-bit PCM if the hardware format cannot be negotiated directly
        NSDictionary *fallback = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @(NO),
            AVLinearPCMIsBigEndianKey: @(NO),
            AVLinearPCMIsNonInterleaved: @(NO)
        };
        _audioTrackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:fallback];
        _audioTrackOutput.alwaysCopiesSampleData = NO;
        if ([_audioAssetReader canAddOutput:_audioTrackOutput]) {
            [_audioAssetReader addOutput:_audioTrackOutput];
        } else {
            _audioAssetReader = nil;
            _audioTrackOutput = nil;
            return NO;
        }
    }

    if ([_audioAssetReader startReading]) {
        _audioReadingStarted = YES;
        VCamLog(@"setupAudioReader: started reading audio track (rate=%.0f chan=%u)",
                settings[AVSampleRateKey] ? [settings[AVSampleRateKey] doubleValue] : 0,
                settings[AVNumberOfChannelsKey] ? [settings[AVNumberOfChannelsKey] unsignedIntValue] : 0);
        return YES;
    }

    _audioAssetReader = nil;
    _audioTrackOutput = nil;
    return NO;
}

- (BOOL)audioFormatChangedLocked:(const AudioStreamBasicDescription *)asbd {
    if (!asbd) return NO;
    if (!_hasActiveAudioFormat) return YES;
    return (asbd->mSampleRate != _activeAudioFormat.mSampleRate ||
            asbd->mChannelsPerFrame != _activeAudioFormat.mChannelsPerFrame ||
            asbd->mBitsPerChannel != _activeAudioFormat.mBitsPerChannel ||
            (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != (_activeAudioFormat.mFormatFlags & kAudioFormatFlagIsFloat) ||
            (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != (_activeAudioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved));
}

// Rotate/flip a decoded frame per the track transform, then move it back to a
// (0,0) origin so downstream scaling can use extent directly.
- (CIImage *)applyVideoTransform:(CIImage *)image {
    if (!_hasVideoTransform || CGAffineTransformIsIdentity(_videoTransform)) {
        return image;
    }
    // Rotation/flip only: the file's translation refers to the render surface,
    // not to our extent, so it is dropped and re-derived below.
    CIImage *rotated = [image imageByApplyingTransform:
        CGAffineTransformMake(_videoTransform.a, _videoTransform.b,
                              _videoTransform.c, _videoTransform.d, 0, 0)];
    CGRect e = rotated.extent;
    if (e.origin.x == 0 && e.origin.y == 0) return rotated;
    return [rotated imageByApplyingTransform:
        CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
}

// Advance the reader until the current frame matches elapsed wall-clock time.
// Caller holds _lock.
- (void)advanceFrameIfNeededLocked {
    if (_sourceType == VCamSourceTypeImage) {
        if (!_currentCIImage && _loadedCGImage) {
            _currentCIImage = [CIImage imageWithCGImage:_loadedCGImage];
            _lastRenderedCIImage = _currentCIImage;
            _frameSerial++;
        }
        return;
    }

    if (!_videoReadingStarted) {
        if (![self setupVideoReader]) return;
        _playbackStart = 0;
    }
    if (!_readerOutput) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (_playbackStart <= 0) {
        _playbackStart = now;
    }
    double elapsed = now - _playbackStart;

    // Resynchronize if wall clock drifted by more than 1.5s (e.g. app background or stall)
    if (_currentPTS > 0 && (elapsed - _currentPTS) > 1.5) {
        _playbackStart = now - _currentPTS;
        elapsed = _currentPTS;
    }

    // The current frame is still within its display time: nothing to decode.
    if (_currentCIImage && _currentPTS > elapsed) {
        return;
    }

    // Bounded catch-up: after a stall, skip ahead a few frames rather than
    // decoding the whole backlog in one call and stuttering the caller.
    for (int guard = 0; guard < 8; guard++) {
        CMSampleBufferRef sample = [_readerOutput copyNextSampleBuffer];
        if (!sample) {
            if (_loopEnabled && [self setupVideoReader]) {
                _playbackStart = CACurrentMediaTime();
                _videoStartPTS = -1.0;
                _currentPTS = 0;
                elapsed = 0;
                continue;
            }
            break; // no more frames: keep showing the last one
        }

        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
        if (!pb) {
            CFRelease(sample);
            continue;
        }

        if (_currentSample) CFRelease(_currentSample);
        _currentSample = sample; // owns the buffer backing _currentCIImage
        _currentCIImage = [self applyVideoTransform:[CIImage imageWithCVPixelBuffer:pb]];
        _lastRenderedCIImage = _currentCIImage;
        _frameSerial++;

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        double rawPTS = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : elapsed;
        if (_videoStartPTS < 0) {
            _videoStartPTS = rawPTS;
        }
        double normPTS = rawPTS - _videoStartPTS;
        if (normPTS < 0) normPTS = 0;
        _currentPTS = normPTS;
        if (_currentPTS >= elapsed) break; // caught up with the wall clock
    }
}

- (CIImage *)currentSourceCIImageHoldingSample:(CMSampleBufferRef *)sampleOut {
    if (sampleOut) *sampleOut = NULL;
    if (!_mediaLoaded) {
        [self loadMedia];
    }
    CIImage *img = nil;
    [_lock lock];
    @try {
        [self advanceFrameIfNeededLocked];
        img = _currentCIImage ?: _lastRenderedCIImage;
        if (sampleOut && _currentSample) {
            *sampleOut = (CMSampleBufferRef)CFRetain(_currentSample);
        }
    } @finally {
        [_lock unlock];
    }
    return img;
}

- (CIImage *)currentSourceCIImage {
    return [self currentSourceCIImageHoldingSample:NULL];
}

- (CIContext *)ensureVideoContext {
    if (!_videoContext) {
        _videoContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
        if (!_videoContext) _videoContext = [CIContext context];
    }
    return _videoContext;
}

- (CIContext *)ensurePreviewContext {
    if (!_previewContext) {
        _previewContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
        if (!_previewContext) _previewContext = [CIContext context];
    }
    return _previewContext;
}

#pragma mark - Media loading

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
    [self discardCurrentFrameLocked];
    _videoAsset = nil;
    _hasVideoTransform = NO;
    _videoTransform = CGAffineTransformIdentity;

    [_audioLock lock];
    [self cleanupAudioReaderLocked];
    [_audioLock unlock];

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

#pragma mark - Video data-output path

- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer {
    [self processFrame:targetPixelBuffer connection:nil];
}

- (void)processFrame:(CVPixelBufferRef)targetPixelBuffer connection:(AVCaptureConnection *)connection {
    if (!_enabled || !targetPixelBuffer) {
        return;
    }

    static dispatch_once_t enterOnce;
    dispatch_once(&enterOnce, ^{ VCamLog(@"processFrame: first call, enabled=%d sourceType=%ld", (int)_enabled, (long)_sourceType); });

    // Log the real target format once: tells us YUV vs BGRA, size, IOSurface.
    if (!_loggedFormat) {
        _loggedFormat = YES;
        OSType fmt = CVPixelBufferGetPixelFormatType(targetPixelBuffer);
        VCamLog(@"processFrame: target fmt=%@(0x%08x) %zux%zu planar=%d iosurface=%d connOrientation=%ld mirrored=%d",
                VCamFourCC(fmt), (unsigned)fmt,
                CVPixelBufferGetWidth(targetPixelBuffer),
                CVPixelBufferGetHeight(targetPixelBuffer),
                CVPixelBufferIsPlanar(targetPixelBuffer),
                CVPixelBufferGetIOSurface(targetPixelBuffer) != NULL,
                connection ? (long)connection.videoOrientation : -1,
                connection ? (int)connection.isVideoMirrored : -1);
    }

    // Diagnostic: paint the buffer a solid colour and stop. If the preview turns
    // that colour, this buffer IS what the app shows and the render path is the
    // bug; if not, the preview is a separate path.
    if (_debugFill) {
        VCamFillSolid(targetPixelBuffer);
        static dispatch_once_t fillOnce;
        dispatch_once(&fillOnce, ^{ VCamLog(@"processFrame: DEBUG solid fill active (vcam_testfill present)"); });
        return;
    }

    @autoreleasepool {
        CMSampleBufferRef sampleToHold = NULL;
        CIImage *sourceImage = [self currentSourceCIImageHoldingSample:&sampleToHold];
        if (!sourceImage) {
            [_lock lock];
            sourceImage = _lastRenderedCIImage;
            [_lock unlock];
        }
        if (!sourceImage) {
            if (sampleToHold) CFRelease(sampleToHold);
            return;
        }

        CIContext *ctx = [self ensureVideoContext];
        if (!ctx) {
            if (sampleToHold) CFRelease(sampleToHold);
            return;
        }

        size_t targetW = CVPixelBufferGetWidth(targetPixelBuffer);
        size_t targetH = CVPixelBufferGetHeight(targetPixelBuffer);
        CGRect extent = sourceImage.extent;
        if (extent.size.width <= 0 || extent.size.height <= 0 || targetW <= 0 || targetH <= 0) {
            if (sampleToHold) CFRelease(sampleToHold);
            return;
        }

        // Sensor orientation & aspect adaptation:
        // When recording in portrait on iPhone, the camera hardware sensor delivers
        // landscape buffers (e.g. 1920x1080, targetW > targetH). The recorder/app
        // attaches a +90 deg rotation transform to the MP4 file so players show it upright.
        // If our source image is portrait (extent.h > extent.w) and we draw it
        // unrotated into the landscape buffer, the player rotates it by another 90 deg,
        // and fitting 1080x1920 into 1920x1080 forces a 1.77x zoom.
        // Pre-rotating by -90 deg (or +90 deg if mirrored/front) turns 1080x1920 into
        // 1920x1080: scale is 1.0 (zero zoom), and the player's +90 deg rotation displays
        // the video 100% upright and identical to the preview.
        CIImage *preparedImage = sourceImage;
        BOOL targetIsLandscape = (targetW > targetH);
        BOOL sourceIsPortrait = (extent.size.height > extent.size.width);

        if (targetIsLandscape && sourceIsPortrait) {
            BOOL isMirrored = connection ? connection.isVideoMirrored : NO;
            CGFloat rotAngle = isMirrored ? (CGFloat)M_PI_2 : (CGFloat)-M_PI_2;
            CIImage *rotated = [preparedImage imageByApplyingTransform:CGAffineTransformMakeRotation(rotAngle)];
            CGRect rExtent = rotated.extent;
            preparedImage = [rotated imageByApplyingTransform:CGAffineTransformMakeTranslation(-rExtent.origin.x, -rExtent.origin.y)];
            extent = preparedImage.extent;
        }

        CGFloat scaleX = (CGFloat)targetW / extent.size.width;
        CGFloat scaleY = (CGFloat)targetH / extent.size.height;
        CGFloat scale = MAX(scaleX, scaleY);

        CGAffineTransform tScale = CGAffineTransformMakeScale(scale, scale);
        CIImage *scaled = [preparedImage imageByApplyingTransform:tScale];

        CGRect scaledExtent = scaled.extent;
        CGFloat offsetX = ((CGFloat)targetW - scaledExtent.size.width) / 2.0;
        CGFloat offsetY = ((CGFloat)targetH - scaledExtent.size.height) / 2.0;
        CIImage *final = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

        [ctx render:final toCVPixelBuffer:targetPixelBuffer];
        static dispatch_once_t renderOnce;
        dispatch_once(&renderOnce, ^{ VCamLog(@"processFrame: first render into %zux%zu target buffer (rotated=%d)", targetW, targetH, (targetIsLandscape && sourceIsPortrait)); });

        if (sampleToHold) {
            CFRelease(sampleToHold);
        }
    }
}

#pragma mark - Audio data-output path

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_enabled || !_audioEnabled || !sampleBuffer) return;
    if (_sourceType != VCamSourceTypeVideo) return;

    if (!_mediaLoaded) {
        [self loadMedia];
    }

    CMBlockBufferRef targetBlock = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!targetBlock) return;

    size_t targetLen = CMBlockBufferGetDataLength(targetBlock);
    if (targetLen == 0) return;

    char *targetPtr = NULL;
    if (CMBlockBufferGetDataPointer(targetBlock, 0, NULL, NULL, &targetPtr) != kCVReturnSuccess || !targetPtr) {
        return;
    }

    CMAudioFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = formatDesc ? CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) : NULL;

    [_audioLock lock];
    @try {
        if (!_audioReadingStarted || [self audioFormatChangedLocked:asbd]) {
            if (![self setupAudioReaderLockedWithFormat:asbd]) {
                return;
            }
        }

        // Fill _audioBuffer FIFO until we have at least targetLen bytes
        while (_audioBuffer.length < targetLen) {
            CMSampleBufferRef fakeSample = [_audioTrackOutput copyNextSampleBuffer];
            if (!fakeSample) {
                if (_loopEnabled && [self setupAudioReaderLockedWithFormat:asbd]) {
                    fakeSample = [_audioTrackOutput copyNextSampleBuffer];
                }
            }
            if (!fakeSample) {
                break; // No more audio data available
            }

            CMBlockBufferRef srcBlock = CMSampleBufferGetDataBuffer(fakeSample);
            if (srcBlock) {
                size_t srcLen = CMBlockBufferGetDataLength(srcBlock);
                char *srcPtr = NULL;
                if (CMBlockBufferGetDataPointer(srcBlock, 0, NULL, NULL, &srcPtr) == kCVReturnSuccess && srcPtr && srcLen > 0) {
                    [_audioBuffer appendBytes:srcPtr length:srcLen];
                }
            }
            CFRelease(fakeSample);
        }

        if (_audioBuffer.length >= targetLen) {
            memcpy(targetPtr, _audioBuffer.bytes, targetLen);
            [_audioBuffer replaceBytesInRange:NSMakeRange(0, targetLen) withBytes:NULL length:0];
        } else if (_audioBuffer.length > 0) {
            size_t avail = _audioBuffer.length;
            memcpy(targetPtr, _audioBuffer.bytes, avail);
            memset(targetPtr + avail, 0, targetLen - avail);
            [_audioBuffer setLength:0];
        } else {
            memset(targetPtr, 0, targetLen);
        }

        static dispatch_once_t audioOnce;
        dispatch_once(&audioOnce, ^{ VCamLog(@"processAudioSampleBuffer: first audio packet injected successfully (len=%zu)", targetLen); });
    } @finally {
        [_audioLock unlock];
    }
}

#pragma mark - Still capture (photo path)

- (CGImageRef)copyCurrentStillCGImage {
    if (!_enabled) return NULL;
    CGImageRef cg = NULL;
    @autoreleasepool {
        CMSampleBufferRef sampleToHold = NULL;
        CIImage *img = [self currentSourceCIImageHoldingSample:&sampleToHold];
        if (!img) {
            [_lock lock];
            img = _lastRenderedCIImage;
            [_lock unlock];
        }
        CIContext *ctx = [self ensurePreviewContext];
        if (img && ctx) {
            cg = [ctx createCGImage:img fromRect:img.extent];
        }
        if (sampleToHold) {
            CFRelease(sampleToHold);
        }
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

#pragma mark - Live preview path

- (CGImageRef)copyCurrentPreviewCGImage {
    if (!_enabled || !_previewEnabled) return NULL;

    if (!_mediaLoaded) {
        [self loadMedia];
    }

    // Check cached raster under lock
    [_lock lock];
    [self advanceFrameIfNeededLocked];
    if (_previewCGImage && _previewCGSerial == _frameSerial) {
        CGImageRef cached = CGImageRetain(_previewCGImage);
        [_lock unlock];
        return cached;
    }
    CIImage *img = _currentCIImage ?: _lastRenderedCIImage;
    CMSampleBufferRef sampleToHold = _currentSample ? (CMSampleBufferRef)CFRetain(_currentSample) : NULL;
    uint64_t serial = _frameSerial;
    [_lock unlock];

    if (!img) {
        if (sampleToHold) CFRelease(sampleToHold);
        return NULL;
    }

    CGImageRef cg = NULL;
    @autoreleasepool {
        CIContext *ctx = [self ensurePreviewContext];
        if (ctx) cg = [ctx createCGImage:img fromRect:img.extent];
    }

    if (sampleToHold) {
        CFRelease(sampleToHold);
    }

    if (!cg) return NULL;

    [_lock lock];
    if (_previewCGImage) CGImageRelease(_previewCGImage);
    _previewCGImage = CGImageRetain(cg);
    _previewCGSerial = serial;
    [_lock unlock];

    static dispatch_once_t once;
    dispatch_once(&once, ^{ VCamLog(@"copyCurrentPreviewCGImage: first preview frame produced"); });
    return cg; // +1, caller releases
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
    [_lock lock];
    [self discardCurrentFrameLocked];
    [self cleanupVideoReader];
    [_lock unlock];

    [_audioLock lock];
    [self cleanupAudioReaderLocked];
    [_audioLock unlock];
}

@end
