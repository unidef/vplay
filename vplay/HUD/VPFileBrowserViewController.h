//
//  VPFileBrowserViewController.h
//  vplay
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VPFileBrowserDelegate <NSObject>
- (void)fileBrowserDidSelectFileURL:(NSURL *)fileURL;
@optional
/// "Play Folder": queue the folder shown (a disc folder plays as a disc).
- (void)fileBrowserDidSelectFolderURL:(NSURL *)folderURL;
/// "Add to Playlist": append item to playlist
- (void)fileBrowserDidEnqueueFileURL:(NSURL *)fileURL;
@end

@interface VPFileBrowserViewController : NSViewController

@property (nonatomic, weak, nullable) id<VPFileBrowserDelegate> delegate;

/// Navigate to a directory
- (void)navigateToDirectory:(NSURL *)directoryURL;
- (void)refresh;
- (IBAction)goUp:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
