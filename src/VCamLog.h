#import <Foundation/Foundation.h>
#import <os/log.h>

// Shared debug logging for VCam Pro.
//   - Always emits to os_log under subsystem "com.vcam.pro" (readable with
//     idevicesyslog / macOS Console, filter: subsystem == com.vcam.pro).
//   - Best-effort append to /var/jb/tmp/vcampro.log so the log can be opened
//     directly in Filza on-device (silently skipped if the sandbox blocks it).
// static inline -> one private copy per translation unit, no duplicate symbols.

static inline os_log_t VCamLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = os_log_create("com.vcam.pro", "vcam"); });
    return handle;
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
        NSString *path = @"/var/jb/tmp/vcampro.log";
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
