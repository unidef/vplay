#import <AppKit/AppKit.h>
#import "VPPlaylist.h"

NS_ASSUME_NONNULL_BEGIN

/// The playlist panel: reorder by dragging, drop files or folders in, double-click to play, shuffle and repeat.
@interface VPPlaylistWindowController : NSWindowController
/// Called when the user chooses an item to play (double-click or Play button).
@property (nonatomic, copy, nullable) void (^playHandler)(NSInteger index);
@property (nonatomic, copy, nullable) void (^discHandler)(void);
- (instancetype)initWithPlaylist:(VPPlaylist *)playlist;
@end

NS_ASSUME_NONNULL_END
