#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Sliders for live picture adjustments, one-click looks, and a shortcut to the shader editor.
@interface VPPostProcessingWindowController : NSWindowController
@property (nonatomic, copy, nullable) void (^openShaderEditor)(void);
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
