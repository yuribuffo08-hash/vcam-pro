#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

@interface VCamWebInjector : NSObject

+ (instancetype)sharedInjector;
- (void)injectIntoUserContentController:(WKUserContentController *)ucc;
- (void)invalidateCache;

@end
