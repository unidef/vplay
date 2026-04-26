//
//  VPWindowController.h
//  vplay
//

#import <AppKit/AppKit.h>
#import "VPPlaylist.h"

@class VPPlaybackEngine;
@class VPVideoView;
@class VPHUDOverlayView;
@class VPConfigManager;

NS_ASSUME_NONNULL_BEGIN

// VPAspectRatio defined in VPVideoView.h

/// Owns the player window: the stage, HUD, playback flow, playlist, tracks, subtitles and the helper windows.
/// Menu items and on-screen buttons both send their actions down the responder chain to this class.
@interface VPWindowController : NSWindowController

- (instancetype)initWithConfigManager:(VPConfigManager *)configManager;

@property (nonatomic, strong, readonly) VPPlaybackEngine *playbackEngine;
@property (nonatomic, strong, readonly) VPVideoView *videoView;
@property (nonatomic, strong, readonly) VPHUDOverlayView *hudOverlay;
@property (nonatomic, strong, readonly) VPConfigManager *configManager;
@property (nonatomic, strong, readonly) VPPlaylist *playlist;
/// YES when video processing (filters, shaders, adjustments, or preparation) is engaged.
@property (nonatomic, readonly) BOOL isProcessingEngaged;
- (void)updateProcessingHUD;

/// Replaces the play queue with these files, folders, playlists or discs and starts the first item.
- (void)openURLs:(NSArray<NSURL *> *)urls shuffle:(BOOL)shuffle;
- (void)openFile:(NSURL *)fileURL;
/// Adds items to the end of the queue without interrupting playback.
- (void)enqueueURLs:(NSArray<NSURL *> *)urls;

// Audio tools
- (IBAction)showAudioFilters:(nullable id)sender;
- (IBAction)showAudioOutput:(nullable id)sender;

// Files, Streams and queue
- (IBAction)openDocument:(nullable id)sender;
- (IBAction)openLocation:(nullable id)sender;
- (IBAction)openStream:(nullable id)sender;
- (IBAction)openFolder:(nullable id)sender;
- (IBAction)openDisc:(nullable id)sender;
- (IBAction)openDiscImage:(nullable id)sender;
- (IBAction)openPlaylistFile:(nullable id)sender;
- (IBAction)savePlaylistFile:(nullable id)sender;
- (IBAction)showPlaylist:(nullable id)sender;
- (IBAction)playNext:(nullable id)sender;
- (IBAction)playPrevious:(nullable id)sender;
- (IBAction)toggleShuffle:(nullable id)sender;
- (IBAction)cycleRepeat:(nullable id)sender;
- (IBAction)setRepeatMode:(nullable NSMenuItem *)sender;

// Transport
- (IBAction)togglePlayPause:(nullable id)sender;
- (IBAction)stopPlayback:(nullable id)sender;
- (IBAction)seekForward:(nullable id)sender;
- (IBAction)seekBackward:(nullable id)sender;
- (IBAction)toggleMute:(nullable id)sender;
- (IBAction)setPlaybackSpeed:(nullable NSMenuItem *)sender;

// Tracks and subtitles
- (IBAction)showTracksMenu:(nullable id)sender;
- (IBAction)selectAudioTrack:(nullable NSMenuItem *)sender;
- (IBAction)selectVideoTrack:(nullable NSMenuItem *)sender;
- (IBAction)selectSubtitleTrack:(nullable NSMenuItem *)sender;
- (IBAction)loadSubtitleFile:(nullable id)sender;
- (IBAction)chooseSubtitleFont:(nullable id)sender;
- (IBAction)setSubtitleFontFromMenu:(nullable NSMenuItem *)sender;
- (IBAction)setSubtitleStyleFromMenu:(nullable NSMenuItem *)sender;
- (IBAction)selectSubtitlePosition:(nullable NSMenuItem *)sender;
- (IBAction)selectAspectRatio:(nullable NSMenuItem *)sender;

// Video quality presets and post-processing level
- (IBAction)selectPostProcessingLevel:(nullable NSMenuItem *)sender;
- (IBAction)selectVideoQualityPreset:(nullable NSMenuItem *)sender;
- (void)applyVideoQualityPresetNamed:(NSString *)name;

// Deinterlace and reverse telecine
- (IBAction)toggleDeinterlace:(nullable id)sender;
- (IBAction)toggleInverseTelecine:(nullable id)sender;
- (IBAction)setDeinterlaceMode:(nullable NSMenuItem *)sender;
- (IBAction)setDeinterlaceFieldOrder:(nullable NSMenuItem *)sender;

// Display
- (IBAction)toggleHUD:(nullable id)sender;
- (IBAction)toggleVisualizer:(nullable id)sender;
- (IBAction)cycleVisualizerStyle:(nullable id)sender;
- (IBAction)toggleFPS:(nullable id)sender;
- (IBAction)showMediaInfo:(nullable id)sender;
- (IBAction)showAirPlay:(nullable id)sender;
- (IBAction)showPostProcessing:(nullable id)sender;
- (IBAction)showShaderEditor:(nullable id)sender;
- (IBAction)takeSnapshot:(nullable id)sender;
- (IBAction)toggleControlsOverlay:(nullable id)sender;
- (IBAction)replayIntro:(nullable id)sender;

// Tools and help
- (IBAction)showConfiguration:(nullable id)sender;
- (IBAction)showBuilder:(nullable id)sender;
- (IBAction)showHelp:(nullable id)sender;
- (IBAction)showLicenseWindow:(nullable id)sender;
- (void)stopFFmpeg:(nullable id)sender;

/// Fills a menu with the current audio, video or subtitle tracks (used by the menu bar's dynamic menus).
- (void)populateTracksMenu:(NSMenu *)menu kind:(NSInteger)kind;
@end

NS_ASSUME_NONNULL_END
