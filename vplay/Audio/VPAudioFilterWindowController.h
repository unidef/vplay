#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Browse, configure, add/remove/update and apply FFmpeg audio filters to live playing audio.
@interface VPAudioFilterWindowController : NSWindowController
/// Called when filters are added, removed, updated or applied to live playing media.
@property (nonatomic, copy, nullable) void (^applyHandler)(void);
- (void)reload;
@end

NS_ASSUME_NONNULL_END
