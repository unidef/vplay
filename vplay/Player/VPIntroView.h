#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A seven-second animated vplay logo, generated procedurally with a fresh random seed each time:
/// particles spiral in and form the ring, the chrome ring and tick marks draw themselves, orbit arcs sweep,
/// the play triangle ignites, and the wordmark appears letter by letter. The final frame lines up with the
/// static logo image so the stage can cross-fade into it.
@interface VPIntroView : NSView
@property (nonatomic, readonly) NSTimeInterval duration;
/// Called once when the animation ends or is skipped.
@property (nonatomic, copy, nullable) void (^finishHandler)(void);
@property (nonatomic, copy) NSColor *accentColor;
- (void)start;
- (void)skip;
@end

NS_ASSUME_NONNULL_END
