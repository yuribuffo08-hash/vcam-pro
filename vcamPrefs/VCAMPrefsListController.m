#import "VCAMPrefsListController.h"
#import <Preferences/PSSpecifier.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <spawn.h>

#define kVCamPrefsNotification CFSTR("com.vcam.pro/preferencesChanged")
static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.vcam.pro.plist";

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
    picker.mediaTypes = @[(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie];
    picker.allowsEditing = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSString *mediaType = info[UIImagePickerControllerMediaType];
    NSString *destinationPath = nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([mediaType isEqualToString:(NSString *)kUTTypeImage]) {
        UIImage *chosenImage = info[UIImagePickerControllerOriginalImage];
        if (chosenImage) {
            destinationPath = @"/var/mobile/Media/DCIM/vcam_source.png";
            NSData *data = UIImagePNGRepresentation(chosenImage);
            [data writeToFile:destinationPath atomically:YES];
        }
    } else if ([mediaType isEqualToString:(NSString *)kUTTypeMovie]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        if (videoURL) {
            destinationPath = @"/var/mobile/Media/DCIM/vcam_source.mp4";
            [fm removeItemAtPath:destinationPath error:nil];
            [fm copyItemAtPath:[videoURL path] toPath:destinationPath error:nil];
        }
    }

    if (destinationPath) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary dictionary];
        dict[@"mediaPath"] = destinationPath;
        dict[@"sourceType"] = [mediaType isEqualToString:(NSString *)kUTTypeMovie] ? @(1) : @(0);
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
    const char *args[] = {"killall", "-9", "mediaserverd", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
}

@end
