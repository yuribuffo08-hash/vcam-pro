#import <Foundation/Foundation.h>
#import <os/log.h>

// Shared debug logging for VCam Pro.
//   - Always emits to os_log under subsystem "com.vcam.pro" (readable with
//     idevicesyslog / macOS Console, filter: subsystem == com.vcam.pro).
//   - Best-effort append to TWO on-device files (each attempted independently,
//     both silently skipped if the sandbox blocks them):
//       1. /var/jb/tmp/vcampro.log
//            Written by jailbreak apps (Filza, Sileo, Preferences) which can
//            reach the rootless prefix. App Store apps run in a sandbox and
//            CANNOT write here, so they never appeared in this file.
//       2. NSHomeDirectory()/Documents/vcampro.log
//            Inside the process's OWN sandbox container, so App Store apps
//            (Telegram, Instagram, ...) can write it. Read it afterwards via
//            Filza -> App Manager -> <app> -> Documents -> vcampro.log.
// static inline -> one private copy per translation unit, no duplicate symbols.

static inline os_log_t VCamLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = os_log_create("com.vcam.pro", "vcam"); });
    return handle;
}

// Best-effort append of one already-formatted line to a single file path.
static inline void VCamLogAppendToPath(NSString *path, NSData *data) {
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:path]) {
            [data writeToFile:path options:0 error:nil];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:data];
                } @finally {
                    [fh closeFile];
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

static inline void VCamLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    os_log(VCamLogHandle(), "%{public}@", msg);

    @try {
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [NSDate date],
                          NSProcessInfo.processInfo.processName,
                          msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

        // (1) Rootless tmp: works for jailbreak apps, blocked in App Store sandbox.
        VCamLogAppendToPath(@"/var/jb/tmp/vcampro.log", data);

        // (2) Per-process sandbox container: works for App Store apps too.
        NSString *home = NSHomeDirectory();
        if (home.length) {
            NSString *docs = [home stringByAppendingPathComponent:@"Documents/vcampro.log"];
            VCamLogAppendToPath(docs, data);
        }
    } @catch (__unused NSException *e) {}
}
