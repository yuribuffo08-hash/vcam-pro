#import "VCamWebInjector.h"
#import "VCamEngine.h"
#import "VCamLog.h"
#import <objc/runtime.h>

static NSString *const kPrefsFileName = @"com.vcam.pro.plist";
static NSString *const kVideoFileName = @"vcam_source.mp4";
static NSString *const kImageFileName = @"vcam_source.png";
static char kVCamInjectedKey;

static NSArray<NSString *> *VCamWebSharedDirs(void) {
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

static NSString *VCamWebFindMediaFile(NSString *configuredPath, VCamSourceType type) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (configuredPath.length && [fm fileExistsAtPath:configuredPath]) {
        return configuredPath;
    }
    NSString *prefName = (type == VCamSourceTypeVideo) ? kVideoFileName : kImageFileName;
    NSString *altName  = (type == VCamSourceTypeVideo) ? kImageFileName : kVideoFileName;

    for (NSString *dir in VCamWebSharedDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:prefName];
        if ([fm fileExistsAtPath:p]) return p;
    }
    for (NSString *dir in VCamWebSharedDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:altName];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

@interface VCamWebInjector () {
    WKUserScript *_cachedUserScript;
    NSLock *_lock;
    NSString *_cachedScriptSource;
}
@end

@implementation VCamWebInjector

+ (instancetype)sharedInjector {
    static VCamWebInjector *sharedInstance = nil;
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
        _cachedUserScript = nil;
        _cachedScriptSource = nil;

        // Listen for internal preferences change notification
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(invalidateCache)
                                                     name:@"com.vcam.pro.internalPrefsChanged"
                                                   object:nil];
    }
    return self;
}

- (void)invalidateCache {
    [_lock lock];
    _cachedUserScript = nil;
    _cachedScriptSource = nil;
    [_lock unlock];
    VCamLog(@"VCamWebInjector: cache invalidated");
}

- (NSString *)buildJavaScriptForMedia:(NSData *)mediaData mimeType:(NSString *)mime isVideo:(BOOL)isVideo {
    NSString *base64 = [mediaData base64EncodedStringWithOptions:0];
    if (!base64.length) return nil;

    NSString *js = [NSString stringWithFormat:@""
    "(function() {\n"
    "    if (window.__vcam_pro_installed) return;\n"
    "    window.__vcam_pro_installed = true;\n"
    "\n"
    "    var VCAM_IS_VIDEO = %@;\n"
    "    var VCAM_MIME = '%@';\n"
    "    var VCAM_BASE64 = '%@';\n"
    "\n"
    "    var mediaBlobUrl = null;\n"
    "    try {\n"
    "        var binary = atob(VCAM_BASE64);\n"
    "        var len = binary.length;\n"
    "        var bytes = new Uint8Array(len);\n"
    "        for (var i = 0; i < len; i++) {\n"
    "            bytes[i] = binary.charCodeAt(i);\n"
    "        }\n"
    "        var blob = new Blob([bytes], { type: VCAM_MIME });\n"
    "        mediaBlobUrl = URL.createObjectURL(blob);\n"
    "    } catch (e) {\n"
    "        console.warn('[VCam Pro] Failed to create blob URL:', e);\n"
    "        return;\n"
    "    }\n"
    "\n"
    "    var globalVirtualCanvas = null;\n"
    "    var initPromise = null;\n"
    "\n"
    "    function initVirtualSource() {\n"
    "        if (globalVirtualCanvas) return Promise.resolve(globalVirtualCanvas);\n"
    "        if (initPromise) return initPromise;\n"
    "\n"
    "        initPromise = new Promise(function(resolve) {\n"
    "            var canvas = document.createElement('canvas');\n"
    "            canvas.width = 1280;\n"
    "            canvas.height = 720;\n"
    "            var ctx = canvas.getContext('2d');\n"
    "\n"
    "            if (!VCAM_IS_VIDEO) {\n"
    "                var img = new Image();\n"
    "                img.crossOrigin = 'anonymous';\n"
    "                img.onload = function() {\n"
    "                    canvas.width = img.naturalWidth || 1280;\n"
    "                    canvas.height = img.naturalHeight || 720;\n"
    "                    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);\n"
    "                    setInterval(function() {\n"
    "                        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);\n"
    "                    }, 50);\n"
    "                    globalVirtualCanvas = canvas;\n"
    "                    resolve(canvas);\n"
    "                };\n"
    "                img.onerror = function() {\n"
    "                    globalVirtualCanvas = canvas;\n"
    "                    resolve(canvas);\n"
    "                };\n"
    "                img.src = mediaBlobUrl;\n"
    "            } else {\n"
    "                var video = document.createElement('video');\n"
    "                video.setAttribute('muted', '');\n"
    "                video.setAttribute('autoplay', '');\n"
    "                video.setAttribute('loop', '');\n"
    "                video.setAttribute('playsinline', '');\n"
    "                video.setAttribute('webkit-playsinline', '');\n"
    "                video.muted = true;\n"
    "                video.autoplay = true;\n"
    "                video.loop = true;\n"
    "                video.playsInline = true;\n"
    "                video.style.cssText = 'position:fixed;top:-9999px;left:-9999px;width:2px;height:2px;opacity:0.01;pointer-events:none;z-index:-9999;';\n"
    "\n"
    "                var resolved = false;\n"
    "                function onVideoReady() {\n"
    "                    if (resolved) return;\n"
    "                    resolved = true;\n"
    "                    canvas.width = video.videoWidth || 1280;\n"
    "                    canvas.height = video.videoHeight || 720;\n"
    "                    video.play().catch(function(){});\n"
    "                    globalVirtualCanvas = canvas;\n"
    "                    resolve(canvas);\n"
    "                }\n"
    "\n"
    "                video.onloadedmetadata = onVideoReady;\n"
    "                video.oncanplay = onVideoReady;\n"
    "                video.onerror = function() {\n"
    "                    if (!resolved) {\n"
    "                        resolved = true;\n"
    "                        globalVirtualCanvas = canvas;\n"
    "                        resolve(canvas);\n"
    "                    }\n"
    "                };\n"
    "\n"
    "                setTimeout(function() {\n"
    "                    if (!resolved) onVideoReady();\n"
    "                }, 1500);\n"
    "\n"
    "                function drawFrame() {\n"
    "                    if (video.readyState >= 2) {\n"
    "                        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);\n"
    "                    }\n"
    "                }\n"
    "                function renderLoop() {\n"
    "                    drawFrame();\n"
    "                    requestAnimationFrame(renderLoop);\n"
    "                }\n"
    "                requestAnimationFrame(renderLoop);\n"
    "                setInterval(drawFrame, 33);\n"
    "\n"
    "                (document.body || document.documentElement).appendChild(video);\n"
    "                video.src = mediaBlobUrl;\n"
    "            }\n"
    "        });\n"
    "        return initPromise;\n"
    "    }\n"
    "\n"
    "    async function createVirtualTrack(realTrack) {\n"
    "        var canvas = await initVirtualSource();\n"
    "        if (!canvas) return null;\n"
    "\n"
    "        var captureFn = canvas.captureStream || canvas.webkitCaptureStream;\n"
    "        if (!captureFn) return null;\n"
    "\n"
    "        var stream = captureFn.call(canvas, 30);\n"
    "        if (!stream || !stream.getVideoTracks().length) return null;\n"
    "\n"
    "        var vTrack = stream.getVideoTracks()[0];\n"
    "\n"
    "        if (realTrack && realTrack.label) {\n"
    "            try {\n"
    "                Object.defineProperty(vTrack, 'label', {\n"
    "                    value: realTrack.label,\n"
    "                    configurable: true\n"
    "                });\n"
    "            } catch (e) {}\n"
    "        }\n"
    "        if (!vTrack.applyConstraints) {\n"
    "            vTrack.applyConstraints = function() { return Promise.resolve(); };\n"
    "        }\n"
    "        var oldGetSettings = vTrack.getSettings ? vTrack.getSettings.bind(vTrack) : function() { return {}; };\n"
    "        vTrack.getSettings = function() {\n"
    "            var s = oldGetSettings();\n"
    "            s.width = s.width || canvas.width || 1280;\n"
    "            s.height = s.height || canvas.height || 720;\n"
    "            s.frameRate = s.frameRate || 30;\n"
    "            s.aspectRatio = s.aspectRatio || (s.width / s.height);\n"
    "            return s;\n"
    "        };\n"
    "\n"
    "        return vTrack;\n"
    "    }\n"
    "\n"
    "    async function handleGetUserMedia(origFn, constraints) {\n"
    "        console.log('[VCam Pro] Intercepted getUserMedia:', constraints);\n"
    "\n"
    "        var realStream = null;\n"
    "        try {\n"
    "            realStream = await origFn(constraints);\n"
    "        } catch (e) {\n"
    "            console.warn('[VCam Pro] Real getUserMedia failed:', e);\n"
    "        }\n"
    "\n"
    "        if (!constraints || (constraints.video === false)) {\n"
    "            if (realStream) return realStream;\n"
    "            throw new DOMException('Requested device not found', 'NotFoundError');\n"
    "        }\n"
    "\n"
    "        var realVideoTracks = realStream ? realStream.getVideoTracks() : [];\n"
    "        var realVideoTrack = realVideoTracks.length > 0 ? realVideoTracks[0] : null;\n"
    "        var vTrack = await createVirtualTrack(realVideoTrack);\n"
    "        if (!vTrack) {\n"
    "            if (realStream) return realStream;\n"
    "            throw new DOMException('Could not start video source', 'NotReadableError');\n"
    "        }\n"
    "\n"
    "        if (realStream) {\n"
    "            for (var i = 0; i < realVideoTracks.length; i++) {\n"
    "                realStream.removeTrack(realVideoTracks[i]);\n"
    "                try { realVideoTracks[i].stop(); } catch (e) {}\n"
    "            }\n"
    "            realStream.addTrack(vTrack);\n"
    "            return realStream;\n"
    "        } else {\n"
    "            return new MediaStream([vTrack]);\n"
    "        }\n"
    "    }\n"
    "\n"
    "    if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {\n"
    "        var origMediaDevicesGUM = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);\n"
    "        navigator.mediaDevices.getUserMedia = function(constraints) {\n"
    "            return handleGetUserMedia(origMediaDevicesGUM, constraints);\n"
    "        };\n"
    "    }\n"
    "    if (navigator.getUserMedia) {\n"
    "        var origLegacyGUM = navigator.getUserMedia.bind(navigator);\n"
    "        navigator.getUserMedia = function(constraints, success, error) {\n"
    "            handleGetUserMedia(function(c) {\n"
    "                return new Promise(function(resolve, reject) {\n"
    "                    origLegacyGUM(c, resolve, reject);\n"
    "                });\n"
    "            }, constraints).then(function(stream) {\n"
    "                if (typeof success === 'function') success(stream);\n"
    "            }).catch(function(err) {\n"
    "                if (typeof error === 'function') error(err);\n"
    "            });\n"
    "        };\n"
    "    }\n"
    "})();",
    isVideo ? @"true" : @"false",
    mime,
    base64];

    return js;
}

- (WKUserScript *)userScript {
    [_lock lock];
    if (_cachedUserScript) {
        WKUserScript *script = _cachedUserScript;
        [_lock unlock];
        return script;
    }

    VCamEngine *engine = [VCamEngine sharedEngine];
    if (!engine.enabled) {
        [_lock unlock];
        return nil;
    }

    NSString *filePath = VCamWebFindMediaFile(engine.mediaPath, engine.sourceType);
    if (!filePath.length) {
        [_lock unlock];
        VCamLog(@"VCamWebInjector: no media file found to inject");
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data.length) {
        [_lock unlock];
        VCamLog(@"VCamWebInjector: media file empty or unreadable: %@", filePath);
        return nil;
    }

    NSString *ext = [[filePath pathExtension] lowercaseString];
    BOOL isVideo = ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"]);
    NSString *mime = isVideo ? @"video/mp4" : ([ext isEqualToString:@"png"] ? @"image/png" : @"image/jpeg");

    NSString *jsSource = [self buildJavaScriptForMedia:data mimeType:mime isVideo:isVideo];
    if (!jsSource.length) {
        [_lock unlock];
        return nil;
    }

    _cachedUserScript = [[WKUserScript alloc] initWithSource:jsSource
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO];
    _cachedScriptSource = jsSource;
    WKUserScript *result = _cachedUserScript;
    [_lock unlock];

    VCamLog(@"VCamWebInjector: generated user script (isVideo=%d, size=%lu bytes)", isVideo, (unsigned long)data.length);
    return result;
}

- (void)injectIntoUserContentController:(WKUserContentController *)ucc {
    if (!ucc) return;

    // Check if this controller already has our script injected
    NSNumber *injected = objc_getAssociatedObject(ucc, &kVCamInjectedKey);
    if ([injected boolValue]) {
        return;
    }

    WKUserScript *script = [self userScript];
    if (!script) return;

    [ucc addUserScript:script];
    objc_setAssociatedObject(ucc, &kVCamInjectedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VCamLog(@"VCamWebInjector: successfully injected into WKUserContentController %p", ucc);
}

@end
