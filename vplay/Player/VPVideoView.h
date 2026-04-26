//
//  VPVideoView.h
//  vplay
//

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import "VPPlaylist.h"
#import "VPAudioVisualizer.h"

@class VPSubtitleTrack, VPEffectRenderer, VPFFmpegPlayer;

NS_ASSUME_NONNULL_BEGIN

/// The player surface. From back to front it stacks: the black stage with the vplay logo, the video (or the
/// effect renderer's frames), the audio visualizer, the subtitle line, the fading metadata card, the FPS pill,
/// the AirPlay overlay and the playback controls. Controls and the AirPlay overlay fade four seconds after the
/// pointer last entered, moved in or left the window.
typedef NS_ENUM(NSInteger, VPAspectRatio) {
    VPAspectRatioAuto = 0,
    VPAspectRatio16_9,
    VPAspectRatio16_10,
    VPAspectRatio4_3,
    VPAspectRatio21_9,
    VPAspectRatio1_1,
    VPAspectRatioStretch,
    VPAspectRatioCropFill
};

@interface VPVideoView : NSView

@property (nonatomic, strong, readonly) AVPlayerLayer *playerLayer;
@property (nonatomic, strong, readonly) VPEffectRenderer *effectRenderer;
@property (nonatomic, strong, nullable) VPAudioAnalyzer *analyzer;

/// Called with an absolute media position (seconds) when the user drags the position slider.
@property (nonatomic, copy, nullable) void (^seekHandler)(double seconds);
/// Called with dropped file URLs.
@property (nonatomic, copy, nullable) void (^dropHandler)(NSArray<NSURL *> *urls);
/// Seconds to add to the player's clock (media converted starting part-way through).
@property (nonatomic) double displayOffset;
@property (nonatomic) VPAspectRatio aspectRatio;
/// Duration of the whole media when the player cannot report one (streamed conversions).
@property (nonatomic) double knownDuration;
/// Replaces the vplay logo shown on the empty stage (nil restores the built-in artwork).
@property (nonatomic, strong, nullable) NSImage *splashImage;
@property (nonatomic, strong, nullable) NSMenu *contextMenu;
@property (nonatomic, copy, nullable) NSMenu * _Nullable (^contextMenuProvider)(void);

@property (nonatomic, readonly) BOOL controlsVisible;
/// The pressed look of the always-visible menu-panel button.
@property (nonatomic) BOOL hudVisible;
/// When NO the playback controls never appear (the menu-panel button, AirPlay and other overlays still do).
@property (nonatomic) BOOL controlsEnabled;
/// Hides every overlay at once: controls, AirPlay, info card, FPS pill, subtitles stay. Shown again with the same call.
@property (nonatomic) BOOL overlaysHidden;
@property (nonatomic, readonly) BOOL introRunning;
/// Plays the five-second animated logo on the empty stage; `completion` runs when it ends or is skipped.
- (void)playIntroWithCompletion:(nullable void (^)(void))completion;
- (void)cancelIntro;
@property (nonatomic, readonly) BOOL airPlayOverlayVisible;

- (void)attachPlayer:(nullable AVPlayer *)player;
- (void)attachFFmpegPlayer:(nullable VPFFmpegPlayer *)ffmpegPlayer;
- (void)detachPlayer;
- (void)updatePlaybackTimeDisplay;
- (void)showControls;
- (void)showAirPlayOverlay;
- (void)setStatusText:(NSString *)text;
- (void)applySkin:(NSDictionary *)skin;
@property (nonatomic, copy, readonly, nullable) NSDictionary *skin;

/// Whether the current media has a picture. Audio-only media gets the full-size visualizer.
@property (nonatomic) BOOL hasVideo;
@property (nonatomic) BOOL visualizerOverVideo;
@property (nonatomic) VPVisualizerStyle visualizerStyle;
@property (nonatomic) BOOL fpsVisible;
@property (nonatomic) BOOL mediaLoaded;          // false shows the logo stage
@property (nonatomic) double sourceFrameRate;     // from the probe, shown next to the measured rate

/// Called with 0–1 when the user drags the volume slider.
@property (nonatomic, copy, nullable) void (^volumeHandler)(float level);
/// Shows the volume slider and mute button for the given state.
- (void)setVolumeLevel:(float)level muted:(BOOL)muted;
/// Flashes a short message over the picture (volume, seeking, speed…). `level` 0–1 adds a bar; pass -1 for none.
- (void)showOSDText:(NSString *)text symbol:(nullable NSString *)symbol level:(double)level;
- (void)setPlaying:(BOOL)playing;
- (void)setShuffleOn:(BOOL)on repeatMode:(VPRepeatMode)mode;
/// Shows the metadata card for about eight seconds, then fades it away.
- (void)showMetadataLines:(NSArray<NSString *> *)lines;
- (void)hideMetadata;
- (void)setSubtitleTrack:(nullable VPSubtitleTrack *)track;
/// Current playback position in media seconds (player clock plus offset).
- (double)currentMediaTime;

@end

NS_ASSUME_NONNULL_END
