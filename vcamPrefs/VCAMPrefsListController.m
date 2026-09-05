#import "VCAMPrefsListController.h"
#import "../src/VCamLog.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>

#define kVCamPrefsNotification CFSTR("com.vcam.pro/preferencesChanged")
// Shared storage lives in the ROOTLESS apex so injected App Store apps can read
// it (the sandbox blocks /var/mobile/Library/Preferences for those targets).
static NSString *const kSharedDir = @"/var/jb/var/mobile/Library/Preferences";
static NSString *const kLegacyDir = @"/var/mobile/Library/Preferences";
static NSString *const kPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.vcam.pro.plist";
static NSString *const kImageDest = @"/var/jb/var/mobile/Library/Preferences/vcam_source.png";
static NSString *const kVideoDest = @"/var/jb/var/mobile/Library/Preferences/vcam_source.mp4";
static NSString *const kTypeImage = @"public.image";
static NSString *const kTypeMovie = @"public.movie";

@implementation VCAMPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self seedSharedStore];
    }
    return _specifiers;
}

// Ensure the rootless shared store exists and carries the current settings +
// media, migrating anything previously saved under the legacy (sandbox-blocked
// for targets) location so the user keeps their selection after upgrading.
- (void)seedSharedStore {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kSharedDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:
        [kLegacyDir stringByAppendingPathComponent:@"com.vcam.pro.plist"]];
    NSMutableDictionary *shared = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
        ?: [NSMutableDictionary dictionary];
    if (legacyPrefs) {
        for (NSString *k in @[@"enabled", @"previewEnabled", @"sourceType", @"loopEnabled", @"mediaPath"]) {
            if (legacyPrefs[k] != nil && shared[k] == nil) shared[k] = legacyPrefs[k];
        }
    }
    // A migrated mediaPath points at the legacy dir; rewrite it to the shared one.
    NSString *mp = shared[@"mediaPath"];
    if ([mp hasPrefix:kLegacyDir]) {
        shared[@"mediaPath"] = [kSharedDir stringByAppendingPathComponent:[mp lastPathComponent]];
    }
    [shared writeToFile:kPrefsPath atomically:YES];

    for (NSString *fn in @[@"vcam_source.mp4", @"vcam_source.png"]) {
        NSString *oldP = [kLegacyDir stringByAppendingPathComponent:fn];
        NSString *newP = [kSharedDir stringByAppendingPathComponent:fn];
        if ([fm fileExistsAtPath:oldP] && ![fm fileExistsAtPath:newP]) {
            [fm copyItemAtPath:oldP toPath:newP error:nil];
        }
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    // CFPreferences (PreferenceLoader "defaults") writes to the legacy location
    // that target sandboxes can't read, so mirror each change into the shared
    // rootless plist that the engine actually reads.
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length && value) {
        [[NSFileManager defaultManager] createDirectoryAtPath:kSharedDir
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
            ?: [NSMutableDictionary dictionary];
        dict[key] = value;
        [dict writeToFile:kPrefsPath atomically:YES];
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kVCamPrefsNotification,
        NULL,
        NULL,
        YES
    );
}

- (void)selectMediaFromGallery {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[kTypeImage, kTypeMovie];
    picker.allowsEditing = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSString *mediaType = info[UIImagePickerControllerMediaType];
    NSString *destinationPath = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kSharedDir withIntermediateDirectories:YES attributes:nil error:nil];

    if ([mediaType isEqualToString:kTypeImage]) {
        UIImage *chosenImage = info[UIImagePickerControllerOriginalImage];
        if (chosenImage) {
            destinationPath = kImageDest;
            NSData *data = UIImagePNGRepresentation(chosenImage);
            BOOL ok = [data writeToFile:destinationPath atomically:YES];
            VCamLog(@"picker: saved image ok=%d path=%@ bytes=%lu", ok, destinationPath, (unsigned long)data.length);
        }
    } else if ([mediaType isEqualToString:kTypeMovie]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        if (videoURL) {
            destinationPath = kVideoDest;
            [fm removeItemAtPath:destinationPath error:nil];
            NSError *copyErr = nil;
            BOOL ok = [fm copyItemAtPath:[videoURL path] toPath:destinationPath error:&copyErr];
            VCamLog(@"picker: saved video ok=%d path=%@ err=%@", ok, destinationPath, copyErr.localizedDescription);
        }
    }

    if (destinationPath) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary dictionary];
        dict[@"mediaPath"] = destinationPath;
        dict[@"sourceType"] = [mediaType isEqualToString:kTypeMovie] ? @(1) : @(0);
        [dict writeToFile:kPrefsPath atomically:YES];

        // Broadcast change immediately to mediaserverd via Darwin notification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kVCamPrefsNotification,
            NULL,
            NULL,
            YES
        );

        [self reloadSpecifiers];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)respringUserspace {
    pid_t pid;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/sbreload"]) {
        const char *args[] = {"sbreload", NULL};
        posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char *const *)args, NULL);
    } else {
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
    }
}

@end
