//
//  VPHUDOverlayView.h
//  vplay
//

#import <AppKit/AppKit.h>
#import "VPSkin.h"

NS_ASSUME_NONNULL_BEGIN

@protocol VPHUDOverlayDelegate <NSObject>
- (void)hudOverlayDidSelectFileURL:(NSURL *)fileURL;
@optional
/// A folder (or disc) was chosen in the browser's "Play Folder" button.
- (void)hudOverlayDidSelectFolderURL:(NSURL *)folderURL;
/// A file was added to queue from the browser.
- (void)hudOverlayDidEnqueueFileURL:(NSURL *)fileURL;
/// The user showed or hid individual menu items; `hidden` holds the identifiers now hidden.
- (void)hudOverlayDidChangeHiddenItems:(NSArray<NSString *> *)hidden;
@end

/// The slide-in menu panel: every vplay feature as a button.
/// It appears at launch, fades away after a few seconds of inactivity and comes back when the pointer moves
/// (while nothing is playing), touches the left edge, the always-visible panel button is clicked, or Tab is
/// pressed. The × in its header hides it with one click, and the ⋯ menu chooses which items it shows.
/// Buttons send their actions down the responder chain, so the window controller and the menu bar share one
/// implementation.
@interface VPHUDOverlayView : VPChromeView

@property (nonatomic, weak, nullable) id<VPHUDOverlayDelegate> delegate;
@property (nonatomic, assign, readonly) BOOL isVisible;
/// When YES (nothing is playing) any pointer movement reveals the panel.
@property (nonatomic) BOOL revealsOnMouseMovement;
/// Identifiers of items hidden from the panel (see the ⋯ menu).
@property (nonatomic, copy) NSArray<NSString *> *hiddenItems;

/// YES when video or media processing (filters, shaders, adjustments, or preparation) is active.
@property (nonatomic, assign) BOOL processingEngaged;
/// Current progress (0.0 to 1.0) while processing, or negative for indeterminate.
@property (nonatomic, assign) double processingProgress;
/// Optional status message displayed with the progress bar (e.g. "PROCESSING ENGAGED").
@property (nonatomic, copy, nullable) NSString *processingStatus;

/// Progress indicator showing processing activity on the HUD.
@property (nonatomic, strong, readonly) NSProgressIndicator *processingProgressBar;

- (void)setProcessingEngaged:(BOOL)engaged;
- (void)setProcessingProgress:(double)progress;

- (void)showAnimated:(BOOL)animated;
- (void)hideAnimated:(BOOL)animated;
- (void)toggle;
/// Starts (or restarts) the countdown that fades the panel away.
- (void)scheduleAutoHide;
/// The window controller forwards pointer movement here (window coordinates).
- (void)noteMouseMovedAtWindowPoint:(NSPoint)point;
/// Updates the pressed look of a toggle button: "shuffle", "visualizer", "fps" or "controls".
- (void)setToggle:(NSString *)identifier on:(BOOL)on;

@end

NS_ASSUME_NONNULL_END
