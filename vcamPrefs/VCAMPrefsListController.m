#import "VCAMPrefsListController.h"
#import "../src/VCamLog.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>

#define kVCamPrefsNotification CFSTR("com.vcam.pro/preferencesChanged")
static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.vcam.pro.plist";
static NSString *const kImageDest = @"/var/mobile/Library/Preferences/vcam_source.png";
static NSString *const kVideoDest = @"/var/mobile/Library/Preferences/vcam_source.mp4";
static NSString *const kTypeImage = @"public.image";
static NSString *const kTypeMovie = @"public.movie";

@implementation VCAMPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
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
