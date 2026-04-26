#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A shader and filter editor with a live preview.
///
/// Left: a Core Image color-kernel editor (with templates) above an ordered filter chain.
/// Right: the result, drawn from the frame that is playing right now (or a built-in test pattern).
/// "Apply to Player" installs the shader and chain on the video immediately.
@interface VPShaderEditorWindowController : NSWindowController
/// Supplies the item whose frames feed the preview; returns nil when nothing is playing.
@property (nonatomic, copy, nullable) AVPlayerItem * _Nullable (^itemProvider)(void);
/// Supplies a direct CIImage frame for live preview (e.g. from FFmpeg or videoView).
@property (nonatomic, copy, nullable) CIImage * _Nullable (^imageProvider)(void);
/// Called after the user applies or clears the effect so the player can refresh.
@property (nonatomic, copy, nullable) void (^didApply)(void);
- (void)reloadFromLiveState;
@end

NS_ASSUME_NONNULL_END
