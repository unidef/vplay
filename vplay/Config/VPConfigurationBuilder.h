#import <AppKit/AppKit.h>
@class VPConfigManager, VPWindowController;
@interface VPConfigurationBuilder : NSWindowController
- (instancetype)initWithConfig:(VPConfigManager *)config player:(VPWindowController *)player;
- (void)refresh;
@end
