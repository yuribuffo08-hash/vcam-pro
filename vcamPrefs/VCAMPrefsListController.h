#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

@interface VCAMPrefsListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
- (void)selectMediaFromGallery;
- (void)respringUserspace;
@end
