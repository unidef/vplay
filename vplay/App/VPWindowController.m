//
//  VPWindowController.m
//  vplay
//

#import "VPWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "VPFFmpegLibrary.h"
#import "VPFFmpegOptions.h"
#import "VPConfigurationBuilder.h"
#import "VPProcessingPlan.h"
#import "VPPreparedMedia.h"
#import "VPSkin.h"
#import "VPPlaybackEngine.h"
#import "VPFFmpegPlayer.h"
#import "VPVideoView.h"
#import "VPHUDOverlayView.h"
#import "VPConfigManager.h"
#import "VPURLHelper.h"
#import "VPMediaProbe.h"
#import "VPDiscSupport.h"
#import "VPSubtitles.h"
#import "VPEffectPipeline.h"
#import "VPEffectRenderer.h"
#import "VPPostProcessing.h"
#import "VPPostProcessingWindowController.h"
#import "VPShaderEditorWindowController.h"
#import "VPPlaylistWindowController.h"
#import "VPAIEnhancer.h"
#import "VPLicenseWindowController.h"
#import "VPAudioFilterWindowController.h"
#import "VPAudioOutputWindowController.h"
#import "VPAudioDeviceManager.h"
#import "VPAudioFilters.h"
#import "VPAudioVisualizer.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

/// Applies the playback speed; defaultRate (which keeps the speed across pauses) needs macOS 13.
static void ApplySpeed(AVPlayer *player, float speed) {
    if (@available(macOS 13.0, *)) player.defaultRate = speed;
    if (player.rate > 0) player.rate = speed;
}

static BOOL LooksLikeAudio(NSURL *url) {
    static NSSet *audio;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        audio = [NSSet setWithArray:@[@"mp3", @"mp2", @"m4a", @"m4b", @"m4r", @"aac", @"ac3", @"eac3", @"ec3", @"dts", @"dtshd", @"wav", @"w64", @"flac", @"aiff", @"aif", @"aifc",
                                      @"ogg", @"oga", @"opus", @"spx", @"wma", @"ape", @"wv", @"mka", @"mpc", @"amr", @"au", @"snd", @"caf", @"tta", @"tak", @"ra", @"gsm", @"mid", @"midi", @"alac", @"mlp", @"thd", @"dsf", @"dff"]];
    });
    return [audio containsObject:url.pathExtension.lowercaseString];
}

@interface VPWindowController () <NSWindowDelegate, VPPlaybackEngineDelegate, VPHUDOverlayDelegate, NSMenuItemValidation, NSMenuDelegate>
@property (nonatomic, strong) VPConfigurationBuilder *builder;
@property (nonatomic, strong) VPPreparedMedia *preparedMedia;
@property (nonatomic, strong) VPMediaProbe *probe;
@property (nonatomic, strong) NSURL *sourceURL;
@property (nonatomic, copy) NSString *sourceTitle;
@property (nonatomic, strong) NSMutableDictionary *activeOptions;
@property (nonatomic, strong) NSMutableDictionary *trackOverrides;     // audioStream / videoStream / burnSubtitleStream
@property (nonatomic) NSInteger subtitleSelection;                      // -1 off, otherwise subtitle track index
@property (nonatomic) NSInteger audioSelection;
@property (nonatomic) NSInteger videoSelection;
@property (nonatomic) double preparedOffset;
@property (nonatomic) NSUInteger playbackGeneration;
@property (nonatomic) NSUInteger mediaToken;           // changes only when a different item starts

@property (nonatomic) float volumeLevel;                              // 0–1, kept across items
@property (nonatomic) BOOL muted;
@property (nonatomic) BOOL preferAVPlayer;      // AirPlay needs an AVPlayer, so the in-process player is skipped for this item
@property (nonatomic) BOOL airPlayPending;       // show the route picker as soon as the AVPlayer is up
@property (nonatomic) BOOL mayFallback;
@property (nonatomic) BOOL mediaActive;
@property (nonatomic) BOOL metadataShownForMedia;
@property (nonatomic) BOOL compositionInstalled;
@property (nonatomic) float speed;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTextView *settingsText;
@property (nonatomic, strong) VPFFmpegJob *ffmpegJob;
@property (nonatomic, strong, nullable) VPLicenseWindowController *licenseWindowController;
@property (nonatomic, strong, nullable) VPAudioFilterWindowController *audioFilterController;
@property (nonatomic, strong, nullable) VPAudioOutputWindowController *audioOutputController;
@property (nonatomic, strong) NSArray<NSPopUpButton *> *qualityMenus;
@property (nonatomic, strong) VPPlaybackEngine *playbackEngine;
@property (nonatomic, strong) VPVideoView *videoView;
@property (nonatomic, strong) VPHUDOverlayView *hudOverlay;
@property (nonatomic, strong) VPConfigManager *configManager;
@property (nonatomic, strong) VPPlaylist *playlist;
@property (nonatomic, strong) VPAudioAnalyzer *analyzer;
@property (nonatomic, strong) VPPlaylistWindowController *playlistController;
@property (nonatomic, strong) VPPostProcessingWindowController *postController;
@property (nonatomic, strong) VPShaderEditorWindowController *shaderController;
@property (nonatomic, strong) id localEventMonitor;
@property (nonatomic, strong) NSTimer *preferenceTimer;
@end

@implementation VPWindowController

- (instancetype)initWithConfigManager:(VPConfigManager *)configManager {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                  styleMask:(NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"vplay";
    window.minSize = NSMakeSize(560, 340);
    window.releasedWhenClosed = NO;
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    window.backgroundColor = NSColor.blackColor;
    window.frameAutosaveName = @"VPPlayerWindow";
    if (![window setFrameUsingName:@"VPPlayerWindow"]) [window center];

    self = [super initWithWindow:window];
    if (self) {
        _configManager = configManager;
        _playlist = [VPPlaylist new];
        _speed = 1;
        _subtitleSelection = -1;
        _trackOverrides = [NSMutableDictionary dictionary];
        window.delegate = self;
        [self setupContentView];
        [self setupPlaybackEngine];
        [self loadPreferences];
        [self setupEventMonitor];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(effectsChanged:) name:VPPostProcessingDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playlistChanged:) name:VPPlaylistDidChangeNotification object:_playlist];
    }
    return self;
}

- (void)dealloc {
    if (self.localEventMonitor) [NSEvent removeMonitor:self.localEventMonitor];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Setup

- (void)setupContentView {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = [[NSColor blackColor] CGColor];

    _videoView = [[VPVideoView alloc] initWithFrame:contentView.bounds];
    _videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:_videoView];
    __weak typeof(self) weakSelf = self;
    _volumeLevel = [self.configManager.playbackOptions[@"volume"] isKindOfClass:NSNumber.class] ? [self.configManager.playbackOptions[@"volume"] floatValue] : 1;
    _videoView.seekHandler = ^(double seconds) { [weakSelf seekToAbsolute:seconds]; };
    _videoView.volumeHandler = ^(float level) { weakSelf.volumeLevel = level; if (level > 0) weakSelf.muted = NO; [weakSelf applyVolume]; [weakSelf showVolumeOSD]; };
    [_videoView setVolumeLevel:_volumeLevel muted:NO];
    _videoView.dropHandler = ^(NSArray<NSURL *> *urls) { [weakSelf openURLs:urls shuffle:weakSelf.playlist.shuffle]; };
    _videoView.contextMenu = [self buildContextMenu];
    _analyzer = [VPAudioAnalyzer new];
    _videoView.analyzer = _analyzer;

    // HUD overlay (on top of everything), inset from the window edge like a floating chrome card.
    NSRect hudFrame = NSMakeRect(12, 12, 372, contentView.bounds.size.height - 24);
    _hudOverlay = [[VPHUDOverlayView alloc] initWithFrame:hudFrame];
    _hudOverlay.delegate = self;
    _hudOverlay.autoresizingMask = NSViewHeightSizable;
    _hudOverlay.revealsOnMouseMovement = YES;
    [contentView addSubview:_hudOverlay];

    [self applySkin:VPSkin.defaultSkin];
    [self loadBackgroundImage];
    // The HUD greets the user on launch, then fades away and returns when the pointer moves.
    [_hudOverlay showAnimated:NO];
}

- (void)applySkin:(NSDictionary *)skin {
    [self.videoView applySkin:skin];
    self.hudOverlay.skin = skin;
}

- (void)loadBackgroundImage {
    NSString *path = self.configManager.backgroundImagePath;
    NSImage *image = path.length ? [[NSImage alloc] initWithContentsOfFile:path.stringByExpandingTildeInPath] : nil;
    self.videoView.splashImage = image;   // nil restores the built-in vplay artwork
}

- (void)setupPlaybackEngine {
    _playbackEngine = [[VPPlaybackEngine alloc] init];
    _playbackEngine.delegate = self;
    _playbackEngine.looping = NO;
}

- (void)setupEventMonitor {
    __weak typeof(self) weakSelf = self;
    self.localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
        VPWindowController *controller = weakSelf;
        if (!controller || event.window != controller.window) return event;
        if (event.type == NSEventTypeMouseMoved) {
            [controller.hudOverlay noteMouseMovedAtWindowPoint:event.locationInWindow];
            return event;
        }
        return [controller handleKeyEvent:event];
    }];
}

#pragma mark - Preferences

- (void)loadPreferences {
    NSDictionary *options = self.configManager.playbackOptions;
    self.videoView.fpsVisible = [options[@"showFPS"] boolValue];
    self.videoView.visualizerOverVideo = [options[@"visualizer"] boolValue];
    NSString *style = options[@"visualizerStyle"];
    self.videoView.visualizerStyle = [style isEqual:@"mirror"] ? VPVisualizerStyleMirror : ([style isEqual:@"ring"] ? VPVisualizerStyleRing : VPVisualizerStyleBars);
    self.playlist.shuffle = [options[@"shuffle"] boolValue];
    NSString *repeat = options[@"repeat"];
    self.playlist.repeatMode = [repeat isEqual:@"all"] ? VPRepeatAll : ([repeat isEqual:@"one"] ? VPRepeatOne : VPRepeatOff);
    if ([options[@"postProcessing"] isKindOfClass:NSDictionary.class]) [VPPostProcessing.shared applyDictionary:options[@"postProcessing"]];
    [self syncToggleStates];
}

/// Updates one key in the user's default config file without touching command-line overrides.
- (void)savePreference:(NSString *)key value:(id)value {
    NSString *path = [VPConfigManager defaultConfigPath];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    id parsed = existing ? [NSJSONSerialization JSONObjectWithData:existing options:0 error:nil] : nil;
    NSMutableDictionary *dict = [parsed isKindOfClass:NSDictionary.class] ? [parsed mutableCopy] : [NSMutableDictionary dictionary];
    dict[key] = value;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

- (void)syncToggleStates {
    [self.hudOverlay setToggle:@"shuffle" on:self.playlist.shuffle];
    [self.hudOverlay setToggle:@"visualizer" on:self.videoView.visualizerOverVideo];
    [self.hudOverlay setToggle:@"fps" on:self.videoView.fpsVisible];
    [self.videoView setShuffleOn:self.playlist.shuffle repeatMode:self.playlist.repeatMode];
}

#pragma mark - Keyboard

- (NSEvent *)handleKeyEvent:(NSEvent *)event {
    [self.videoView showControls];
    NSResponder *firstResponder = self.window.firstResponder;
    if ([firstResponder isKindOfClass:[NSTextView class]] || [firstResponder isKindOfClass:[NSTextField class]]) return event;   // typing in a field

    unsigned short keyCode = event.keyCode;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    NSString *character = event.charactersIgnoringModifiers.lowercaseString;

    switch (keyCode) {
        case 49: if (!command) { [self togglePlayPause:nil]; return nil; } break;   // Space
        case 48: [self toggleHUD:nil]; return nil;                                  // Tab
        case 53: if (self.hudOverlay.isVisible) { [self.hudOverlay hideAnimated:YES]; return nil; } break;   // Escape
        case 123: if (!command) { if (flags & NSEventModifierFlagShift) [self seekBackward:nil]; else [self stepFrames:-1]; return nil; } break;   // ← previous frame (⇧ 5 s back)
        case 124: if (!command) { if (flags & NSEventModifierFlagShift) [self seekForward:nil]; else [self stepFrames:1]; return nil; } break;      // → next frame (⇧ 5 s ahead)
        case 126: [self nudgeVolume:0.1f]; return nil;                              // ↑
        case 125: [self nudgeVolume:-0.1f]; return nil;                             // ↓
    }
    if (command) return event;
    if ([character isEqual:@"n"]) { [self playNext:nil]; return nil; }
    if ([character isEqual:@"p"]) { [self playPrevious:nil]; return nil; }
    if ([character isEqual:@"s"]) { [self toggleShuffle:nil]; return nil; }
    if ([character isEqual:@"r"]) { [self cycleRepeat:nil]; return nil; }
    if ([character isEqual:@"m"]) { [self toggleMute:nil]; return nil; }
    if ([character isEqual:@"v"]) { [self toggleVisualizer:nil]; return nil; }
    if ([character isEqual:@"d"]) { [self toggleFPS:nil]; return nil; }
    if ([character isEqual:@"i"]) { [self showMediaInfo:nil]; return nil; }
    if ([character isEqual:@"f"]) { [self.window toggleFullScreen:nil]; return nil; }
    if ([character isEqual:@"["]) { [self changeSpeedBy:-0.25f]; return nil; }
    if ([character isEqual:@"]"]) { [self changeSpeedBy:0.25f]; return nil; }
    return event;
}

- (void)nudgeVolume:(float)delta {
    self.volumeLevel = MAX(0, MIN(1, self.volumeLevel + delta));
    if (delta > 0) self.muted = NO;
    [self applyVolume];
    [self showVolumeOSD];
}

- (void)showVolumeOSD {
    NSString *symbol = self.muted || self.volumeLevel <= 0 ? @"speaker.slash.fill" : self.volumeLevel < 0.34 ? @"speaker.wave.1.fill" : self.volumeLevel < 0.67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
    [self.videoView showOSDText:self.muted ? @"Muted" : [NSString stringWithFormat:@"Volume %.0f%%", self.volumeLevel * 100] symbol:symbol level:self.muted ? 0 : self.volumeLevel];
}

/// Pushes the volume and mute state to whichever player is running and to the controls bar.
- (void)applyVolume {
    VPFFmpegPlayer *ffmpeg = self.playbackEngine.ffmpegPlayer;
    if (ffmpeg) ffmpeg.volume = self.muted ? 0 : self.volumeLevel;
    else if (self.playbackEngine.player) {
        self.playbackEngine.player.volume = self.volumeLevel;
        self.playbackEngine.player.muted = self.muted;
    }
    [self.videoView setVolumeLevel:self.volumeLevel muted:self.muted];
    [self.videoView showControls];
}

/// Steps the picture by whole frames; playback pauses, as in other players.
- (void)stepFrames:(NSInteger)count {
    if (!self.mediaActive) return;
    VPFFmpegPlayer *ffmpeg = self.playbackEngine.ffmpegPlayer;
    if (ffmpeg) {
        [ffmpeg stepFrames:count];
    } else if (self.playbackEngine.currentItem) {
        [self.playbackEngine pause];
        [self.playbackEngine.currentItem stepByCount:count];
    } else return;
    [self.videoView setPlaying:NO];
    [self.videoView showOSDText:count > 0 ? (count == 1 ? @"Next frame" : [NSString stringWithFormat:@"+%ld frames", (long)count]) : (count == -1 ? @"Previous frame" : [NSString stringWithFormat:@"%ld frames", (long)count])
                         symbol:count > 0 ? @"forward.frame.fill" : @"backward.frame.fill" level:-1];
}

- (void)applySpeedToPlayback {
    if (self.playbackEngine.ffmpegPlayer) self.playbackEngine.ffmpegPlayer.rate = self.speed;
    else ApplySpeed(self.playbackEngine.player, self.speed);
}

- (void)changeSpeedBy:(float)delta {
    self.speed = MAX(0.25f, MIN(4, self.speed + delta));
    [self applySpeedToPlayback];
    self.videoView.statusText = [NSString stringWithFormat:@"Speed %.2f×", self.speed];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Speed %.2f×", self.speed] symbol:@"speedometer" level:-1];
}

#pragma mark - Opening media

- (void)resolvingDiscImages:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *))completion {
    // Disc images are mounted first; their volumes replace them in the list.
    NSMutableArray *resolved = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSNumber *, NSURL *> *mounted = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < urls.count; i++) {
        if ([VPDiscSupport isDiscImage:urls[i]] && [VPDiscSupport kindForURL:urls[i]] == VPDiscKindNone) {
            dispatch_group_enter(group);
            self.videoView.statusText = @"Mounting disc image…";
            [VPDiscSupport mountImageAtURL:urls[i] completion:^(NSURL *volume, NSError *error) {
                if (volume) mounted[@(i)] = volume; else if (error) [self reportPlaybackError:error];
                dispatch_group_leave(group);
            }];
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        for (NSUInteger i = 0; i < urls.count; i++) {
            NSURL *url = mounted[@(i)] ?: urls[i];
            if (![VPDiscSupport isDiscImage:urls[i]] || mounted[@(i)] || [VPDiscSupport kindForURL:urls[i]] != VPDiscKindNone) [resolved addObject:url];
        }
        completion(resolved);
    });
}

- (void)openURLs:(NSArray<NSURL *> *)urls shuffle:(BOOL)shuffle {
    if (!urls.count) return;
    [self resolvingDiscImages:urls completion:^(NSArray<NSURL *> *resolved) {
        [self stopPlayback:nil];
        [self.playlist clear];
        if (shuffle != self.playlist.shuffle) self.playlist.shuffle = shuffle;
        NSUInteger added = [self.playlist addInputs:resolved];
        if (!added) {
            [self reportPlaybackError:[NSError errorWithDomain:@"VPlayErrorDomain" code:93 userInfo:@{NSLocalizedDescriptionKey:@"Nothing playable was found in what you chose. Folders need media files, and discs need an unprotected DVD, Blu-ray, VCD or SVCD structure."}]];
            return;
        }
        [self syncToggleStates];
        [self startPlaylistItem:[self.playlist advanceAutomatically:NO]];
    }];
}

- (void)openFile:(NSURL *)fileURL { if (fileURL) [self openURLs:@[fileURL] shuffle:self.playlist.shuffle]; }

- (void)enqueueURLs:(NSArray<NSURL *> *)urls {
    [self resolvingDiscImages:urls completion:^(NSArray<NSURL *> *resolved) {
        BOOL wasEmpty = self.playlist.items.count == 0;
        [self.playlist addInputs:resolved];
        if (wasEmpty && !self.mediaActive) [self startPlaylistItem:[self.playlist advanceAutomatically:NO]];
        else self.videoView.statusText = [NSString stringWithFormat:@"%lu items in the playlist", (unsigned long)self.playlist.items.count];
    }];
}

- (void)startPlaylistItem:(VPPlaylistItem *)item {
    if (!item) return;
    [self stopPlaybackKeepingStage];
    self.preferAVPlayer = NO; self.airPlayPending = NO;
    NSError *error = nil;
    NSDictionary *options = [VPProcessingPlan resolvedOptions:[self.configManager toDictionary] error:&error];
    if (!options) { [self reportPlaybackError:error]; return; }
    self.activeOptions = [options mutableCopy] ?: [NSMutableDictionary dictionary];
    self.sourceURL = item.url;
    self.sourceTitle = item.title;
    NSUInteger token = ++self.mediaToken;
    self.probe = nil;
    self.metadataShownForMedia = NO;
    self.mediaActive = YES;
    self.trackOverrides = [NSMutableDictionary dictionary];
    self.subtitleSelection = -1; self.audioSelection = 0; self.videoSelection = 0;
    [self.videoView setSubtitleTrack:nil];
    self.window.title = [NSString stringWithFormat:@"vplay — %@", item.title];
    self.hudOverlay.revealsOnMouseMovement = NO;
    [self.hudOverlay hideAnimated:YES];
    self.videoView.mediaLoaded = YES;
    self.videoView.hasVideo = !LooksLikeAudio(item.url);
    [self updateStatusText:@"Checking media…"];
    [self loadSubtitleSidecarForCurrentMedia];

    // Probe in parallel: it feeds the metadata card, track menus and frame-rate display.
    [VPMediaProbe probeURL:item.url completion:^(VPMediaProbe *probe) {
        if (token != self.mediaToken || !probe) return;
        [self probeDidFinish:probe];
    }];
    [self startCurrentWithResume:0 forcePrepared:NO];
}

- (void)probeDidFinish:(VPMediaProbe *)probe {
    self.probe = probe;
    self.videoView.hasVideo = probe.hasVideo;
    self.videoView.sourceFrameRate = probe.frameRate;
    if (probe.duration > 0 && self.preparedMedia) self.videoView.knownDuration = probe.duration;
    if (!self.metadataShownForMedia && ![self.configManager.playbackOptions[@"showMetadata"] isEqual:@NO]) {
        self.metadataShownForMedia = YES;
        [self.videoView showMetadataLines:[self metadataLinesForProbe:probe]];
    }
}

/// The probe's lines, with the queue title (for example "DVD — MY_MOVIE") standing in when the file carries no title tag.
- (NSArray<NSString *> *)metadataLinesForProbe:(VPMediaProbe *)probe {
    NSMutableArray *lines = [[probe overlayLinesForURL:self.sourceURL] mutableCopy];
    BOOL disc = [self.sourceURL.pathExtension.lowercaseString isEqual:@"ffconcat"];
    if (disc && self.sourceTitle.length && lines.count) lines[0] = self.sourceTitle;
    return lines;
}

- (void)updateStatusText:(NSString *)detail {
    NSString *position = self.playlist.items.count > 1 ? [NSString stringWithFormat:@"[%ld/%lu] ", (long)self.playlist.currentIndex + 1, (unsigned long)self.playlist.items.count] : @"";
    self.videoView.statusText = detail.length ? [NSString stringWithFormat:@"%@%@ — %@", position, self.sourceTitle ?: @"", detail] : [position stringByAppendingString:self.sourceTitle ?: @""];
}

#pragma mark - Playback flow

/// Starts (or restarts, after a track change or distant seek) the current source.
- (void)startCurrentWithResume:(double)resume forcePrepared:(BOOL)force {
    NSURL *url = self.sourceURL;
    NSDictionary *options = self.activeOptions;
    NSString *backend = options[@"playbackBackend"] ?: @"auto";
    BOOL disc = [url.pathExtension.lowercaseString isEqual:@"ffconcat"];
    BOOL externalFilters = [VPFFmpegOptions requiresPreparation:options];
    if ([backend isEqual:@"ffplay"]) {
        NSMutableDictionary *external = [options mutableCopy]; external[@"ffmpeg"] = @YES;
        [self startURL:url options:external fallback:NO offset:0]; return;
    }
    if ([backend isEqual:@"native"] && (externalFilters || disc)) {
        [self reportPlaybackError:[NSError errorWithDomain:@"VPlayErrorDomain" code:84 userInfo:@{NSLocalizedDescriptionKey:disc ? @"Discs need FFmpeg. Choose the auto or prepared backend." : @"Native playback cannot execute FFmpeg filter stages. Choose auto or prepared."}]];
        return;
    }
    // Anything that would need conversion plays in the in-process FFmpeg player instead: it decodes and filters live,
    // so seeks are instant because nothing is converted ahead of time.
    BOOL wantsPrepared = externalFilters || disc || force || self.trackOverrides.count;
    if (wantsPrepared && !self.preferAVPlayer && ![backend isEqual:@"prepared"] && [self canPlayInProcessWithOptions:options]) {
        if ([self startInProcessResumeAt:resume]) return;
    }
    if ([backend isEqual:@"prepared"] || externalFilters || disc || force || self.trackOverrides.count) { [self prepareCurrentMediaResumeAt:resume]; return; }
    [self updateStatusText:@"Checking media…"];
    NSUInteger generation = self.playbackGeneration;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.playbackGeneration) return;
            if (!asset.playable && [backend isEqual:@"auto"]) {
                if (self.preferAVPlayer || ![self canPlayInProcessWithOptions:options] || ![self startInProcessResumeAt:resume]) [self prepareCurrentMediaResumeAt:resume];
            }
            else [self startURL:url options:options fallback:[backend isEqual:@"auto"] offset:0];
        });
    }];
}

- (void)startURL:(NSURL *)url options:(NSDictionary *)options fallback:(BOOL)fallback offset:(double)offset {
    self.mayFallback = fallback;
    NSError *error = nil;
    if (![self.playbackEngine playURL:url options:options error:&error]) {
        if (fallback) { self.mayFallback = NO; [self prepareCurrentMediaResumeAt:0]; }
        else [self reportPlaybackError:error];
        return;
    }
    if (self.playbackEngine.player) {
        [self.videoView attachPlayer:self.playbackEngine.player];
        [self applyVolume];
        self.videoView.displayOffset = offset;
        if (self.probe.duration > 0 && self.preparedMedia) self.videoView.knownDuration = self.probe.duration;
        self.preparedOffset = offset;
        if (!self.preparedMedia && self.playbackEngine.player.currentItem) [self.analyzer attachToItem:self.playbackEngine.player.currentItem];
        if (self.speed != 1) [self applySpeedToPlayback];
        [self.videoView setPlaying:YES];
        self.compositionInstalled = [VPEffectPipeline optionsRequireProcessing:self.activeOptions] || VPPostProcessing.shared.isActive;
        [self refreshEffectsForcingRedraw:NO];
        [self updateStatusText:self.preparedMedia ? @"Converted with FFmpeg" : @""];
        if (self.airPlayPending) {
            self.airPlayPending = NO;
            [self.videoView showAirPlayOverlay];
            [self.videoView showOSDText:@"Choose an AirPlay device (top right)" symbol:@"airplayvideo" level:-1];
        }
    } else {
        [self.videoView setStatusText:@"Playing in FFplay — controls are in its window"];
    }
}

/// The user's audio filter chain plus the AI audio stage, as one libavfilter graph string.
- (NSString *)combinedAudioFilterGraph {
    NSMutableArray *audio = [NSMutableArray array];
    if ([self.activeOptions[@"af"] length]) [audio addObject:self.activeOptions[@"af"]];
    else if (VPAudioFilters.shared.isActive && VPAudioFilters.shared.graph.length) [audio addObject:VPAudioFilters.shared.graph];
    if (VPAIEnhancer.shared.isAudioAIActive && VPAIEnhancer.shared.audioFilterGraphString.length) [audio addObject:VPAIEnhancer.shared.audioFilterGraphString];
    return [audio componentsJoinedByString:@","];
}

/// YES when the only reason for preparation is audio processing, which the in-process player can do live.
- (BOOL)canPlayInProcessWithOptions:(NSDictionary *)options {
    // Raw FFplay arguments were never supported, and burned-in bitmap subtitles need the converter.
    return ![options[@"ffplayArguments"] count] && !self.trackOverrides[@"burnSubtitleStream"];
}

/// Plays through VPFFmpegPlayer: demuxed, decoded and filtered in memory, frames drawn by Metal/Core Image.
- (BOOL)startInProcessResumeAt:(double)resume {
    NSMutableDictionary *opts = [self.activeOptions mutableCopy];
    [opts addEntriesFromDictionary:self.trackOverrides];
    opts[@"af"] = [self combinedAudioFilterGraph];
    // AI audio upsampling decides the speaker layout and sample rate the output device is opened with.
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (ai.isAudioAIActive) {
        NSString *layout = [opts[@"audioLayout"] length] ? opts[@"audioLayout"] : @"auto";
        if ([layout isEqual:@"auto"]) {
            if ([ai.surroundMethod hasSuffix:@"_51"]) layout = @"5.1";
            else if ([ai.surroundMethod hasSuffix:@"_71"]) layout = @"7.1";
            else if (![ai.targetLayout isEqual:@"auto"]) layout = ai.targetLayout;
            opts[@"audioLayout"] = layout;
        }
        NSString *rate = [opts[@"audioSampleRate"] description];
        if ((!rate.length || [rate isEqual:@"auto"]) && ai.targetSampleRate.doubleValue >= 8000) opts[@"audioSampleRate"] = ai.targetSampleRate;
    }
    opts[@"playbackBackend"] = @"ffmpeg";   // make the engine use the in-process player even for natively playable files

    // Video-side stages (vf, deinterlace, telecine, lanczos upscale) become a live libavfilter graph in the player.
    NSMutableDictionary *videoOptions = [opts mutableCopy];
    videoOptions[@"effect"] = @"none"; videoOptions[@"shader"] = @""; videoOptions[@"nativeStages"] = @[];
    if (![opts[@"scaler"] isEqual:@"lanczos"]) videoOptions[@"upscale"] = @1;
    NSDictionary *graphs = [VPFFmpegOptions filterGraphsForOptions:videoOptions error:nil];
    if (!graphs) return NO;
    NSString *video = graphs[@"videoFilter"] ?: @"";
    NSString *ext = self.sourceURL.pathExtension.lowercaseString;
    if ([@[@"ffconcat", @"vob"] containsObject:ext] && ![video containsString:@"bwdif"]) {
        // DVD-style sources look combed otherwise; only frames flagged as interlaced are touched.
        NSString *deint = @"bwdif=mode=send_frame:deint=interlaced";
        video = video.length ? [deint stringByAppendingFormat:@",%@", video] : deint;
    }
    if (video.length) opts[@"videoFilterGraph"] = video;

    [self.preparedMedia cancel]; self.preparedMedia = nil;
    [self.playbackEngine stop]; [self.videoView detachPlayer];
    NSError *error = nil;
    if (![self.playbackEngine playURL:self.sourceURL options:opts error:&error]) return NO;
    VPFFmpegPlayer *player = self.playbackEngine.ffmpegPlayer;
    if (!player) return NO;
    if (resume > 0) [player seekToSeconds:resume];
    if (self.speed != 1) player.rate = self.speed;
    self.videoView.displayOffset = 0;
    self.preparedOffset = 0;
    [self.videoView attachFFmpegPlayer:player];
    [self applyVolume];
    [self.videoView setPlaying:YES];
    self.compositionInstalled = NO;
    [self refreshEffectsForcingRedraw:NO];
    [self updateStatusText:@""];
    return YES;
}

- (void)prepareCurrentMediaResumeAt:(double)resume {
    self.mayFallback = NO;
    [self.playbackEngine stop]; [self.videoView detachPlayer];
    [self.preparedMedia cancel];
    self.preparedMedia = [VPPreparedMedia new];
    [self updateStatusText:[VPFFmpegLibrary supportsStreamingConversion] ? @"Preparing with FFmpeg…" : @"Converting with FFmpeg… playback begins when conversion finishes"];
    NSUInteger generation = self.playbackGeneration;
    NSMutableDictionary *prep = [self.activeOptions mutableCopy];
    [prep addEntriesFromDictionary:self.trackOverrides];
    prep[@"startOffset"] = @(resume);
    prep[@"audioOnly"] = @(self.probe ? !self.probe.hasVideo : LooksLikeAudio(self.sourceURL));
    VPPreparedMedia *media = self.preparedMedia;
    __weak typeof(self) weakSelf = self;
    [media prepareURL:self.sourceURL options:prep completion:^(NSURL *url, NSError *error) {
        VPWindowController *self = weakSelf;
        if (!self || generation != self.playbackGeneration || media != self.preparedMedia) return;
        if (error) { [self.preparedMedia cancel]; self.preparedMedia = nil; [self reportPlaybackError:error]; return; }
        NSMutableDictionary *native = [self.activeOptions mutableCopy];
        native[@"vf"] = @""; native[@"af"] = @""; native[@"ffmpeg"] = @NO; native[@"ffplayArguments"] = @[];
        native[@"audioLayout"] = @"auto"; native[@"deinterlace"] = @NO; native[@"inverseTelecine"] = @NO;
        native[@"hls"] = @(media.streaming);
        native[@"alreadyPrepared"] = @YES;   // FFmpeg has applied every filter; the engine must not reroute to its in-process player
        if ([native[@"scaler"] isEqual:@"lanczos"]) native[@"upscale"] = @1;
        [self startURL:url options:native fallback:NO offset:resume];
    }];
}

- (void)stopPlaybackKeepingStage {
    self.playbackGeneration++;
    [self.playbackEngine stop];
    [self.analyzer detach];
    [self.videoView detachPlayer];
    [self.preparedMedia cancel]; self.preparedMedia = nil;
    self.compositionInstalled = NO;
    self.mediaActive = NO;
}

- (void)playbackEngineDidFail:(NSError *)error {
    if (self.mayFallback) { self.mayFallback = NO; [self prepareCurrentMediaResumeAt:0]; }
    else [self reportPlaybackError:error];
}

- (void)reportPlaybackError:(NSError *)error {
    [self.videoView setStatusText:error.localizedDescription ?: @"Playback failed"];
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Unable to play media";
    alert.informativeText = error.localizedDescription ?: @"The installed decoders could not open this input.";
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Seeking

- (void)seekToAbsolute:(double)target {
    if (self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
        double length = self.playbackEngine.duration;
        target = MAX(0, target);
        if (isfinite(length) && length > 0) target = MIN(target, MAX(0, length - 0.5));
        [self.playbackEngine seekToSeconds:target];
        return;
    }
    AVPlayer *player = self.playbackEngine.player;
    if (!player) return;
    target = MAX(0, target);
    double duration = self.videoView.knownDuration > 0 ? self.videoView.knownDuration : CMTimeGetSeconds(player.currentItem.duration);
    if (isfinite(duration) && duration > 0) target = MIN(target, MAX(0, duration - 0.5));
    if (!self.preparedMedia) { [self.playbackEngine seekToSeconds:target]; return; }
    double local = target - self.preparedOffset;
    NSValue *rangeValue = player.currentItem.seekableTimeRanges.lastObject;
    double seekableEnd = rangeValue ? CMTimeGetSeconds(CMTimeRangeGetEnd(rangeValue.CMTimeRangeValue)) : 0;
    if (local < 0 || (self.preparedMedia.streaming && local > seekableEnd - 1)) {
        // Outside what FFmpeg has produced so far: restart the conversion at the requested position.
        [self restartAtPosition:target];
    } else [self.playbackEngine seekToSeconds:local];
}

- (void)restartAtPosition:(double)seconds {
    self.playbackGeneration++;
    [self.playbackEngine stop]; [self.analyzer detach]; [self.videoView detachPlayer];
    [self updateStatusText:@"Seeking…"];
    [self startCurrentWithResume:seconds forcePrepared:YES];
}

- (void)seekByDelta:(double)delta {
    if (!self.playbackEngine.player && !self.playbackEngine.ffmpegPlayer) return;
    double target = MAX(0, [self.videoView currentMediaTime] + delta);
    [self seekToAbsolute:target];
    [self.videoView showOSDText:[NSString stringWithFormat:@"%@%.0fs", delta > 0 ? @"+" : @"−", fabs(delta)] symbol:delta > 0 ? @"goforward" : @"gobackward" level:-1];
}
- (IBAction)seekForward:(id)sender { [self seekByDelta:5]; }
- (IBAction)seekBackward:(id)sender { [self seekByDelta:-5]; }

#pragma mark - Effects

- (void)effectsChanged:(NSNotification *)note {
    [self refreshEffectsForcingRedraw:YES];
    [self.preferenceTimer invalidate];
    self.preferenceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *timer) {
        [self savePreference:@"postProcessing" value:[VPPostProcessing.shared dictionaryRepresentation]];
    }];
}

/// Makes the picture reflect the shader, filter chain and post-processing settings right now.
- (void)refreshEffectsForcingRedraw:(BOOL)redraw {
    if (self.playbackEngine.isFFmpegPlaying && self.activeOptions) {
        VPEffectRenderer *renderer = self.videoView.effectRenderer;
        BOOL needed = [VPEffectPipeline optionsRequireProcessing:self.activeOptions] || VPPostProcessing.shared.isActive;
        NSError *error = nil;
        renderer.processor = needed ? [VPEffectPipeline processorForOptions:self.activeOptions error:&error] : nil;
        if (redraw) [renderer setNeedsRedraw];
        return;
    }
    AVPlayerItem *item = self.playbackEngine.currentItem;
    if (!item || !self.activeOptions) return;
    BOOL needed = [VPEffectPipeline optionsRequireProcessing:self.activeOptions] || VPPostProcessing.shared.isActive;
    if (self.preparedMedia.streaming) {
        // HLS cannot take a video composition, so draw processed frames ourselves.
        VPEffectRenderer *renderer = self.videoView.effectRenderer;
        if (needed) {
            NSError *error = nil;
            VPImageProcessor processor = [VPEffectPipeline processorForOptions:self.activeOptions error:&error];
            renderer.processor = processor;
            if (!renderer.running) { [renderer startWithItem:item]; self.videoView.playerLayer.hidden = YES; }
            else if (redraw) [renderer setNeedsRedraw];
        } else if (renderer.running) {
            [renderer stop]; self.videoView.playerLayer.hidden = NO;
        }
        return;
    }
    if (needed != self.compositionInstalled) {
        NSError *error = nil;
        if (![VPEffectPipeline configureItem:item options:self.activeOptions error:&error]) [self.videoView setStatusText:error.localizedDescription];
        self.compositionInstalled = needed;
        redraw = YES;
    }
    AVPlayer *player = self.playbackEngine.player;
    if (redraw && needed && player.rate == 0) {
        // A paused frame is only re-rendered when the player seeks to it.
        [player seekToTime:player.currentTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
}

#pragma mark - Transport actions

- (IBAction)togglePlayPause:(id)sender {
    if (!self.mediaActive && self.playlist.items.count) { [self startPlaylistItem:self.playlist.currentItem ?: [self.playlist advanceAutomatically:NO]]; return; }
    [self.playbackEngine togglePlayPause];
    BOOL nowPlaying = self.playbackEngine.ffmpegPlayer ? self.playbackEngine.ffmpegPlayer.isPlaying : self.playbackEngine.player.rate > 0;
    [self.videoView setPlaying:nowPlaying];
    [self.videoView showOSDText:nowPlaying ? @"Play" : @"Paused" symbol:nowPlaying ? @"play.fill" : @"pause.fill" level:-1];
}

- (IBAction)stopPlayback:(id)sender {
    [self stopPlaybackKeepingStage];
    [self.videoView setSubtitleTrack:nil];
    [self.videoView hideMetadata];
    self.videoView.mediaLoaded = NO;
    self.videoView.hasVideo = YES;
    [self.videoView setPlaying:NO];
    [self.videoView setStatusText:@"Stopped — open media from the menu or press Tab"];
    self.window.title = @"vplay";
    self.hudOverlay.revealsOnMouseMovement = YES;
}

- (IBAction)playNext:(id)sender {
    VPPlaylistItem *item = [self.playlist advanceAutomatically:NO];
    if (item) [self startPlaylistItem:item]; else [self.videoView setStatusText:@"The playlist is empty"];
}

- (IBAction)playPrevious:(id)sender {
    // Like most players: a restart if we are past the first few seconds, otherwise the previous item.
    if ([self.videoView currentMediaTime] > 4 && (self.playbackEngine.player || self.playbackEngine.ffmpegPlayer)) { [self seekToAbsolute:0]; return; }
    VPPlaylistItem *item = [self.playlist retreat];
    if (item) [self startPlaylistItem:item];
}

- (IBAction)toggleShuffle:(id)sender {
    self.playlist.shuffle = !self.playlist.shuffle;
    [self savePreference:@"shuffle" value:@(self.playlist.shuffle)];
    [self syncToggleStates];
    self.videoView.statusText = self.playlist.shuffle ? @"Shuffle on" : @"Shuffle off";
    [self.videoView showOSDText:self.playlist.shuffle ? @"Shuffle on" : @"Shuffle off" symbol:@"shuffle" level:-1];
}

- (IBAction)cycleRepeat:(id)sender {
    self.playlist.repeatMode = (VPRepeatMode)((self.playlist.repeatMode + 1) % 3);
    [self persistRepeat];
}
- (IBAction)setRepeatMode:(NSMenuItem *)sender {
    self.playlist.repeatMode = (VPRepeatMode)sender.tag;
    [self persistRepeat];
}
- (void)persistRepeat {
    NSArray *names = @[@"off", @"all", @"one"];
    [self savePreference:@"repeat" value:names[self.playlist.repeatMode]];
    [self syncToggleStates];
    self.videoView.statusText = [NSString stringWithFormat:@"Repeat %@", names[self.playlist.repeatMode]];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Repeat %@", names[self.playlist.repeatMode]] symbol:self.playlist.repeatMode == VPRepeatOne ? @"repeat.1" : @"repeat" level:-1];
}

- (IBAction)toggleMute:(id)sender {
    self.muted = !self.muted;
    [self applyVolume];
    self.videoView.statusText = self.muted ? @"Muted" : @"Sound on";
    [self showVolumeOSD];
}

- (IBAction)setPlaybackSpeed:(NSMenuItem *)sender {
    self.speed = sender.tag / 100.0f;
    ApplySpeed(self.playbackEngine.player, self.speed);
    self.videoView.statusText = [NSString stringWithFormat:@"Speed %.2f×", self.speed];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Speed %.2f×", self.speed] symbol:@"speedometer" level:-1];
}

- (void)playlistChanged:(NSNotification *)note { [self syncToggleStates]; }

#pragma mark - Opening panels

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.message = @"Choose one or more audio or video files. Several files become a playlist.";
    // Accept all files; the decoders, not filename extensions, decide what is playable.
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URLs.count) [self openURLs:panel.URLs shuffle:self.playlist.shuffle];
    }];
}

- (IBAction)openFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.message = @"Choose folders to queue, or .m3u / .pls playlist files.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URLs.count) [self openURLs:panel.URLs shuffle:self.playlist.shuffle];
    }];
}

- (IBAction)openDisc:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes"];
    NSArray *discs = [VPDiscSupport mountedDiscs];
    panel.message = discs.count ? [NSString stringWithFormat:@"Choose a disc, a disc folder (VIDEO_TS, BDMV) or a disc image. Detected: %@.", [[discs valueForKey:@"lastPathComponent"] componentsJoinedByString:@", "]]
                                : @"Choose a mounted DVD, Blu-ray, VCD or SVCD, a ripped disc folder, or an .iso image.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) [self openURLs:@[panel.URL] shuffle:NO];
    }];
}

- (IBAction)openLocation:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Open URL";
    alert.informativeText = @"Enter the address of a video, audio file or stream (http, https, rtsp, rtmp, udp, HLS…).";
    [alert addButtonWithTitle:@"Open"]; [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)];
    field.placeholderString = @"https://example.com/stream.m3u8";
    alert.accessoryView = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSURL *url = [VPURLHelper urlFromString:[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        if (url) [self openURLs:@[url] shuffle:NO];
    }];
    [alert.window makeFirstResponder:field];
}

- (IBAction)showPlaylist:(id)sender {
    if (!self.playlistController) {
        self.playlistController = [[VPPlaylistWindowController alloc] initWithPlaylist:self.playlist];
        __weak typeof(self) weakSelf = self;
        self.playlistController.playHandler = ^(NSInteger index) { [weakSelf startPlaylistItem:[weakSelf.playlist selectIndex:index]]; };
        self.playlistController.discHandler = ^{ [weakSelf openDisc:nil]; };
    }
    [self.playlistController showWindow:nil];
}

#pragma mark - VPHUDOverlayDelegate

- (void)hudOverlayDidSelectFileURL:(NSURL *)fileURL { [self openFile:fileURL]; }
- (void)hudOverlayDidSelectFolderURL:(NSURL *)folderURL { [self openURLs:@[folderURL] shuffle:self.playlist.shuffle]; }

#pragma mark - Tracks and subtitles

- (void)populateTracksMenu:(NSMenu *)menu kind:(NSInteger)kind {
    [menu removeAllItems];
    VPMediaProbe *probe = self.probe;
    if (kind == VPTrackKindSubtitle) {
        NSMenuItem *off = [menu addItemWithTitle:@"Off" action:@selector(selectSubtitleTrack:) keyEquivalent:@""];
        off.tag = -1;
        off.target = self;
        off.state = self.subtitleSelection == -1 ? NSControlStateValueOn : NSControlStateValueOff;
        for (VPTrack *track in probe.subtitleTracks) {
            NSMenuItem *item = [menu addItemWithTitle:[track displayName] action:@selector(selectSubtitleTrack:) keyEquivalent:@""];
            item.tag = track.index;
            item.target = self;
            item.state = self.subtitleSelection == track.index ? NSControlStateValueOn : NSControlStateValueOff;
            if (track.bitmap) item.toolTip = @"Picture-based subtitles are drawn onto the video by FFmpeg, which restarts playback at the current position.";
        }
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *loadItem = [menu addItemWithTitle:@"Load Subtitle File…" action:@selector(loadSubtitleFile:) keyEquivalent:@""];
        loadItem.target = self;
        return;
    }
    NSArray<VPTrack *> *tracks = kind == VPTrackKindAudio ? probe.audioTracks : probe.videoTracks;
    NSInteger selected = kind == VPTrackKindAudio ? self.audioSelection : self.videoSelection;
    if (!tracks.count) {
        NSString *message = !self.mediaActive ? @"Open media to see its tracks" : (probe ? @"No tracks" : @"Track details need ffprobe (install FFmpeg)");
        NSMenuItem *none = [menu addItemWithTitle:message action:nil keyEquivalent:@""];
        none.enabled = NO;
        return;
    }
    for (VPTrack *track in tracks) {
        NSMenuItem *item = [menu addItemWithTitle:[track displayName] action:kind == VPTrackKindAudio ? @selector(selectAudioTrack:) : @selector(selectVideoTrack:) keyEquivalent:@""];
        item.tag = track.index;
        item.target = self;
        item.state = selected == track.index ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (NSMenu *)buildTracksMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tracks"];
    menu.autoenablesItems = YES;
    NSArray *sections = @[@[@"Audio Track", @(VPTrackKindAudio)], @[@"Video Track", @(VPTrackKindVideo)], @[@"Subtitles", @(VPTrackKindSubtitle)]];
    for (NSArray *section in sections) {
        if ([section[1] integerValue] == VPTrackKindVideo && self.probe.videoTracks.count < 2) continue;
        NSMenuItem *header = [menu addItemWithTitle:section[0] action:nil keyEquivalent:@""];
        header.enabled = NO;
        NSMenu *scratch = [NSMenu new];
        [self populateTracksMenu:scratch kind:[section[1] integerValue]];
        for (NSMenuItem *item in [scratch.itemArray copy]) { [scratch removeItem:item]; item.indentationLevel = 1; [menu addItem:item]; }
        [menu addItem:NSMenuItem.separatorItem];
    }
    [menu removeItemAtIndex:menu.numberOfItems - 1];
    return menu;
}

- (IBAction)showTracksMenu:(id)sender {
    NSMenu *menu = [self buildTracksMenu];
    if ([sender isKindOfClass:NSView.class]) [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, ((NSView *)sender).bounds.size.height + 4) inView:sender];
    else [menu popUpMenuPositioningItem:nil atLocation:NSEvent.mouseLocation inView:nil];
}

- (IBAction)selectAudioTrack:(NSMenuItem *)sender {
    NSInteger index = sender.tag;
    self.audioSelection = index;
    self.trackOverrides[@"audioStream"] = @(index);
    
    // Seamless dynamic track switch in FFmpeg player if currently playing with FFmpeg
    if (self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
        if ([self.playbackEngine selectAudioTrack:index]) {
            [self updateStatusText:[NSString stringWithFormat:@"Audio Track %ld", (long)(index + 1)]];
            return;
        }
    }
    
    AVPlayerItem *item = self.playbackEngine.currentItem;
    if (self.preparedMedia || !item || self.probe.audioTracks.count < 2) {
        [self restartAtPosition:[self.videoView currentMediaTime]];
        return;
    }
    // Native playback: switch inside the item without interrupting it.
    [item.asset loadMediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible completionHandler:^(AVMediaSelectionGroup *group, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (group && (NSInteger)group.options.count > index) {
                [item selectMediaOption:group.options[index] inMediaSelectionGroup:group];
                [self updateStatusText:[NSString stringWithFormat:@"Audio Track %ld", (long)(index + 1)]];
            } else {
                self.trackOverrides[@"playbackBackend"] = @"ffmpeg";
                [self restartAtPosition:[self.videoView currentMediaTime]];
            }
        });
    }];
}

- (IBAction)selectVideoTrack:(NSMenuItem *)sender {
    self.videoSelection = sender.tag;
    self.trackOverrides[@"videoStream"] = @(sender.tag);
    [self restartAtPosition:[self.videoView currentMediaTime]];
}

- (IBAction)selectSubtitleTrack:(NSMenuItem *)sender {
    NSInteger index = sender.tag;
    BOOL hadBurn = self.trackOverrides[@"burnSubtitleStream"] != nil;
    self.subtitleSelection = index;
    [self.trackOverrides removeObjectForKey:@"burnSubtitleStream"];
    [self.videoView setSubtitleTrack:nil];
    if (index < 0) {
        if (hadBurn) [self restartAtPosition:[self.videoView currentMediaTime]];
        [self updateStatusText:@"Subtitles Off"];
        return;
    }
    VPTrack *track = nil;
    for (VPTrack *candidate in self.probe.subtitleTracks) {
        if (candidate.index == index) {
            track = candidate;
            break;
        }
    }
    if (track.bitmap) {
        self.trackOverrides[@"burnSubtitleStream"] = @(index);
        [self prepareCurrentMediaResumeAt:[self.videoView currentMediaTime]];
        return;
    }
    if (hadBurn) [self restartAtPosition:[self.videoView currentMediaTime]];
    self.videoView.statusText = @"Loading subtitles…";
    NSUInteger token = self.mediaToken;
    [VPSubtitleTrack extractFromMedia:self.sourceURL subtitleIndex:index completion:^(VPSubtitleTrack *subtitles, NSError *error) {
        if (token != self.mediaToken || self.subtitleSelection != index) return;
        if (!subtitles) {
            self.subtitleSelection = -1;
            self.videoView.statusText = error.localizedDescription ?: @"These subtitles could not be converted to text.";
            return;
        }
        [self.videoView setSubtitleTrack:subtitles];
        [self updateStatusText:[NSString stringWithFormat:@"Subtitles: %@", track.displayName ?: @"On"]];
    }];
}

- (IBAction)loadSubtitleFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = @"Choose a subtitle file (.srt, .vtt, .ass, .ssa).";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        VPSubtitleTrack *track = [VPSubtitleTrack trackWithContentsOfURL:panel.URL error:&error];
        if (!track) { [self reportPlaybackError:error]; return; }
        [self.trackOverrides removeObjectForKey:@"burnSubtitleStream"];
        self.subtitleSelection = -2;      // external file: no embedded track is checked
        [self.videoView setSubtitleTrack:track];
        self.videoView.statusText = [NSString stringWithFormat:@"Subtitles: %@", panel.URL.lastPathComponent];
    }];
}

/// Picks up "Movie.srt" next to "Movie.mkv" automatically.
- (void)loadSubtitleSidecarForCurrentMedia {
    if (!self.sourceURL.isFileURL) return;
    NSURL *base = [self.sourceURL URLByDeletingPathExtension];
    for (NSString *ext in @[@"srt", @"vtt", @"ass", @"ssa"]) {
        NSURL *candidate = [base URLByAppendingPathExtension:ext];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate.path]) continue;
        VPSubtitleTrack *track = [VPSubtitleTrack trackWithContentsOfURL:candidate error:nil];
        if (track) { self.subtitleSelection = -2; [self.videoView setSubtitleTrack:track]; return; }
    }
}

#pragma mark - Display actions

- (IBAction)toggleHUD:(id)sender { [self.hudOverlay toggle]; }

- (IBAction)toggleVisualizer:(id)sender {
    self.videoView.visualizerOverVideo = !self.videoView.visualizerOverVideo;
    [self savePreference:@"visualizer" value:@(self.videoView.visualizerOverVideo)];
    [self syncToggleStates];
    self.videoView.statusText = self.videoView.visualizerOverVideo ? @"Visualizer on (always shown for audio-only media)" : @"Visualizer over video off";
}

- (IBAction)cycleVisualizerStyle:(id)sender {
    VPVisualizerStyle next = (VPVisualizerStyle)((self.videoView.visualizerStyle + 1) % 3);
    self.videoView.visualizerStyle = next;
    [self savePreference:@"visualizerStyle" value:@[@"bars", @"mirror", @"ring"][next]];
    self.videoView.statusText = [NSString stringWithFormat:@"Visualizer style: %@", @[@"bars", @"mirror", @"ring"][next]];
}

- (IBAction)toggleFPS:(id)sender {
    self.videoView.fpsVisible = !self.videoView.fpsVisible;
    [self savePreference:@"showFPS" value:@(self.videoView.fpsVisible)];
    [self syncToggleStates];
}

- (IBAction)showMediaInfo:(id)sender {
    if (!self.probe) { self.videoView.statusText = self.mediaActive ? @"Media details are still loading (or ffprobe is missing)" : @"Open media first"; return; }
    [self.videoView showMetadataLines:[self metadataLinesForProbe:self.probe]];
}

- (IBAction)showAirPlay:(id)sender {
    [self.hudOverlay hideAnimated:YES];
    if (!self.mediaActive) { self.videoView.statusText = @"Start playing something, then choose an AirPlay device"; return; }
    if (!self.playbackEngine.player) {
        // The in-process player has no AVPlayer to hand to AirPlay; continue this item through the AVPlayer path instead.
        self.preferAVPlayer = YES;
        self.airPlayPending = YES;
        [self.videoView showOSDText:@"Preparing for AirPlay…" symbol:@"airplayvideo" level:-1];
        [self restartAtPosition:[self.videoView currentMediaTime]];
        return;
    }
    [self.videoView showAirPlayOverlay];
    [self.videoView showOSDText:@"Choose an AirPlay device (top right)" symbol:@"airplayvideo" level:-1];
}

- (IBAction)showPostProcessing:(id)sender {
    if (!self.postController) {
        self.postController = [VPPostProcessingWindowController new];
        __weak typeof(self) weakSelf = self;
        self.postController.openShaderEditor = ^{ [weakSelf showShaderEditor:nil]; };
    }
    [self.postController refresh];
    [self.postController showWindow:nil];
}

- (IBAction)showShaderEditor:(id)sender {
    if (!self.shaderController) {
        self.shaderController = [VPShaderEditorWindowController new];
        __weak typeof(self) weakSelf = self;
        self.shaderController.itemProvider = ^AVPlayerItem *{ return weakSelf.playbackEngine.currentItem; };
    }
    [self.shaderController showWindow:nil];
}

- (IBAction)showHelp:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"vplay shortcuts";
    alert.informativeText = @"Space  play / pause\nTab  show or hide the menu panel\n← →  previous / next frame     ⇧← ⇧→  seek 5 seconds     ↑ ↓  volume\nN / P  next / previous     S  shuffle     R  repeat\nF  full screen     M  mute     I  media info\nV  visualizer over video     D  FPS display\n[ and ]  slower / faster\n\n⌘O open file    ⌘U open URL    ⌘L playlist\n⌘B configuration builder    ⌘,  settings\n\nDrop files, folders, playlists or disc folders onto the window. Right-click for quick options.\nCommand line: vplay play a.mkv b.mp3 --shuffle   ·   vplay help";
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    BOOL playing = self.playbackEngine.ffmpegPlayer ? self.playbackEngine.ffmpegPlayer.isPlaying : self.playbackEngine.player.rate > 0;
    if (action == @selector(togglePlayPause:)) { item.title = playing ? @"Pause" : @"Play"; return self.mediaActive || self.playlist.items.count > 0; }
    if (action == @selector(stopPlayback:) || action == @selector(seekForward:) || action == @selector(seekBackward:) || action == @selector(toggleMute:) || action == @selector(setPlaybackSpeed:)) {
        if (action == @selector(setPlaybackSpeed:)) item.state = fabsf(item.tag / 100.0f - self.speed) < 0.01f ? NSControlStateValueOn : NSControlStateValueOff;
        if (action == @selector(toggleMute:)) item.state = self.muted ? NSControlStateValueOn : NSControlStateValueOff;
        return self.mediaActive;
    }
    if (action == @selector(playNext:) || action == @selector(playPrevious:)) return self.playlist.items.count > 0;
    if (action == @selector(toggleShuffle:)) { item.state = self.playlist.shuffle ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(setRepeatMode:)) { item.state = item.tag == self.playlist.repeatMode ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(toggleVisualizer:)) { item.state = self.videoView.visualizerOverVideo ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(toggleFPS:)) { item.state = self.videoView.fpsVisible ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(toggleHUD:)) { item.state = self.hudOverlay.isVisible ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(showAirPlay:) || action == @selector(showMediaInfo:) || action == @selector(loadSubtitleFile:)) return self.mediaActive;
    return YES;
}

#pragma mark - Context menu

- (NSMenu *)buildContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"vplay"];
    menu.autoenablesItems = YES;
    menu.delegate = self;   // rebuilt each time it opens so checkmarks match the current state
    return menu;
}

- (NSMenuItem *)addTo:(NSMenu *)menu title:(NSString *)title action:(SEL)action object:(id)object checked:(BOOL)checked {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self; item.representedObject = object;
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (NSMenu *)submenuNamed:(NSString *)title in:(NSMenu *)menu {
    NSMenuItem *parent = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
    sub.autoenablesItems = YES;
    parent.submenu = sub;
    return sub;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.videoView.contextMenu) return;
    [menu removeAllItems];
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    for (NSArray *row in @[@[@"Play", @"togglePlayPause:"], @[@"Next", @"playNext:"], @[@"Previous", @"playPrevious:"], @[@"Mute", @"toggleMute:"]]) {
        [self addTo:menu title:row[0] action:NSSelectorFromString(row[1]) object:nil checked:NO];
    }
    NSMenu *speed = [self submenuNamed:@"Speed" in:menu];
    for (NSNumber *percent in @[@25, @50, @75, @100, @125, @150, @200, @300, @400]) {
        NSMenuItem *item = [self addTo:speed title:[NSString stringWithFormat:@"%.2g×", percent.doubleValue / 100] action:@selector(setPlaybackSpeed:) object:nil checked:fabsf(percent.floatValue / 100 - self.speed) < 0.01f];
        item.tag = percent.integerValue;
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self addTo:menu title:@"Tracks & Subtitles…" action:@selector(showTracksMenu:) object:nil checked:NO];
    [self addTo:menu title:@"Playlist…" action:@selector(showPlaylist:) object:nil checked:NO];
    [self addTo:menu title:@"AirPlay…" action:@selector(showAirPlay:) object:nil checked:self.playbackEngine.player.externalPlaybackActive];
    [self addTo:menu title:@"Show Menu Panel" action:@selector(toggleHUD:) object:nil checked:NO];
    [menu addItem:NSMenuItem.separatorItem];

    // Video
    NSMenu *video = [self submenuNamed:@"Video" in:menu];
    NSMenu *aspect = [self submenuNamed:@"Aspect Ratio" in:video];
    NSArray *aspects = @[@"Auto", @"16:9", @"16:10", @"4:3", @"21:9", @"1:1", @"Stretch", @"Crop to Fill"];
    for (NSUInteger i = 0; i < aspects.count; i++) {
        NSMenuItem *item = [self addTo:aspect title:aspects[i] action:@selector(selectAspectRatio:) object:nil checked:(NSUInteger)self.videoView.aspectRatio == i];
        item.tag = (NSInteger)i;
    }
    NSMenu *quality = [self submenuNamed:@"Quality Presets" in:video];
    for (NSString *name in [VPEffectPipeline videoQualityPresetNames]) {
        [self addTo:quality title:name action:@selector(selectVideoQualityPreset:) object:name checked:NO];
    }
    [self addTo:video title:@"Deinterlace" action:@selector(toggleDeinterlace:) object:nil checked:[self.activeOptions[@"deinterlace"] boolValue]];
    [self addTo:video title:@"Inverse Telecine" action:@selector(toggleInverseTelecine:) object:nil checked:[self.activeOptions[@"inverseTelecine"] boolValue]];
    [video addItem:NSMenuItem.separatorItem];
    [self addTo:video title:@"Post-Processing…" action:@selector(showPostProcessing:) object:nil checked:NO];
    [self addTo:video title:@"Shader Editor…" action:@selector(showShaderEditor:) object:nil checked:NO];

    // AI video
    NSMenu *aiVideo = [self submenuNamed:@"AI Video Enhancement" in:menu];
    NSString *activeVideo = ai.isVideoAIActive ? ai.activeVideoPreset : @"none";
    [self addTo:aiVideo title:@"Off" action:@selector(selectAIVideoPreset:) object:@"none" checked:!ai.isVideoAIActive];
    [aiVideo addItem:NSMenuItem.separatorItem];
    NSArray *videoPresets = @[@[@"Vivid & Crisp", @"vivid_crisp"], @[@"Cinema HDR", @"cinema_hdr"], @[@"Anime Pop", @"anime_pop"], @[@"Super Resolution 2×", @"super_resolution_2x"], @[@"Clean Restore (Denoise)", @"clean_restore"]];
    for (NSArray *preset in videoPresets) [self addTo:aiVideo title:preset[0] action:@selector(selectAIVideoPreset:) object:preset[1] checked:[activeVideo isEqual:preset[1]]];
    [aiVideo addItem:NSMenuItem.separatorItem];
    NSMenu *upscale = [self submenuNamed:@"AI Upscaling" in:aiVideo];
    for (NSNumber *factor in @[@1, @1.5, @2, @3, @4]) {
        NSMenuItem *item = [self addTo:upscale title:factor.doubleValue <= 1 ? @"Off" : [NSString stringWithFormat:@"%.2g×", factor.doubleValue] action:@selector(selectAIUpscale:) object:factor checked:ai.isVideoAIActive ? fabs(ai.upscaleFactor - factor.doubleValue) < 0.01 : factor.doubleValue <= 1];
        (void)item;
    }
    NSArray *videoToggles = @[@[@"Clarity", @"clarityBoost", @0.6], @[@"Sharpen", @"luminanceSharpness", @0.6], @[@"Denoise", @"adaptiveDenoise", @0.5], @[@"Micro Contrast", @"microContrast", @0.5], @[@"Vivid Color", @"vividVibrance", @0.7]];
    for (NSArray *t in videoToggles) [self addTo:aiVideo title:t[0] action:@selector(toggleAIVideoLevel:) object:t checked:ai.videoAIEnabled && [[ai valueForKey:t[1]] doubleValue] > 0.01];
    [self addTo:aiVideo title:@"HDR Tone Mapping" action:@selector(toggleAIVideoFlag:) object:@"hdrDynamicTone" checked:ai.videoAIEnabled && ai.hdrDynamicTone];
    [self addTo:aiVideo title:@"Cinema Color Grade" action:@selector(toggleAIVideoFlag:) object:@"cinemaColorGrade" checked:ai.videoAIEnabled && ai.cinemaColorGrade];
    [self addTo:aiVideo title:@"Subject Focus (Vision)" action:@selector(toggleAIVideoFlag:) object:@"visionSaliencyFocus" checked:ai.videoAIEnabled && ai.visionSaliencyFocus];

    // AI audio
    NSMenu *aiAudio = [self submenuNamed:@"AI Audio" in:menu];
    NSString *activeAudio = ai.isAudioAIActive ? ai.activeAudioPreset : @"none";
    [self addTo:aiAudio title:@"Off" action:@selector(selectAIAudioPreset:) object:@"none" checked:!ai.isAudioAIActive];
    [aiAudio addItem:NSMenuItem.separatorItem];
    NSArray *audioPresets = @[@[@"Clear Dialogue", @"clear_dialogue"], @[@"Spatial 3D", @"spatial_3d"], @[@"Surround 5.1 Upmix", @"surround_51"], @[@"Surround 7.1 Upmix", @"surround_71"], @[@"Studio Master", @"studio_master"], @[@"Night Mode", @"night_mode"], @[@"Loudness Normalize", @"loudnorm"], @[@"Bass Punch", @"bass_punch"]];
    for (NSArray *preset in audioPresets) [self addTo:aiAudio title:preset[0] action:@selector(selectAIAudioPreset:) object:preset[1] checked:[activeAudio isEqual:preset[1]]];
    [aiAudio addItem:NSMenuItem.separatorItem];
    NSMenu *surround = [self submenuNamed:@"Upsample to Surround" in:aiAudio];
    NSArray *methods = @[@[@"Off", @"none"], @[@"Spatial Stereo (Apple-style)", @"apple_spatial"], @[@"5.1 (Apple-style)", @"apple_51"], @[@"7.1 (Apple-style)", @"apple_71"], @[@"5.1 (FFmpeg)", @"ffmpeg_51"], @[@"7.1 (FFmpeg)", @"ffmpeg_71"], @[@"Wide Stereo", @"stereo_wide"], @[@"Virtual Subwoofer 2.1", @"subwoofer_21"]];
    for (NSArray *m in methods) [self addTo:surround title:m[0] action:@selector(selectAISurroundMethod:) object:m[1] checked:[ai.surroundMethod isEqual:m[1]]];
    NSMenu *rate = [self submenuNamed:@"Upsample Sample Rate" in:aiAudio];
    for (NSString *r in @[@"auto", @"48000", @"96000", @"192000", @"384000"]) {
        [self addTo:rate title:[r isEqual:@"auto"] ? @"Source Rate" : [NSString stringWithFormat:@"%g kHz", r.doubleValue / 1000] action:@selector(selectAISampleRate:) object:r checked:[ai.targetSampleRate isEqual:r]];
    }
    NSArray *audioToggles = @[@[@"Dialogue Boost", @"dialogueBoost"], @[@"Harmonic Crystalizer", @"harmonicCrystalizer"], @[@"Bass Impact", @"bassImpact"], @[@"Treble Sparkle", @"trebleSparkle"], @[@"Night Mode Compression", @"nightMode"], @[@"Loudness Normalization", @"loudnessNormalize"]];
    [aiAudio addItem:NSMenuItem.separatorItem];
    for (NSArray *t in audioToggles) [self addTo:aiAudio title:t[0] action:@selector(toggleAIAudioFlag:) object:t[1] checked:ai.audioAIEnabled && [[ai valueForKey:t[1]] boolValue]];
    [aiAudio addItem:NSMenuItem.separatorItem];
    [self addTo:aiAudio title:@"Audio Filters…" action:@selector(showAudioFilters:) object:nil checked:NO];
    [self addTo:aiAudio title:@"Audio Output…" action:@selector(showAudioOutput:) object:nil checked:NO];

    [menu addItem:NSMenuItem.separatorItem];
    [self addTo:menu title:@"Shuffle" action:@selector(toggleShuffle:) object:nil checked:self.playlist.shuffle];
    [self addTo:menu title:@"Visualizer" action:@selector(toggleVisualizer:) object:nil checked:self.videoView.visualizerOverVideo];
    [self addTo:menu title:@"FPS Display" action:@selector(toggleFPS:) object:nil checked:self.videoView.fpsVisible];
    [self addTo:menu title:@"Take Snapshot" action:@selector(takeSnapshot:) object:nil checked:NO];
    [self addTo:menu title:@"Media Info" action:@selector(showMediaInfo:) object:nil checked:NO];
}

#pragma mark - AI actions

/// Redraws the picture after an AI video setting changed.
- (void)aiVideoDidChangeWithMessage:(NSString *)message {
    [VPAIEnhancer.shared changed];
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView showOSDText:message symbol:@"sparkles" level:-1];
}

/// Audio changes alter the filter graph and often the output layout, so playback restarts at the same spot (instant in the in-process player).
- (void)aiAudioDidChangeWithMessage:(NSString *)message {
    [VPAIEnhancer.shared changed];
    [self.videoView showOSDText:message symbol:@"waveform.badge.magnifyingglass" level:-1];
    if (self.mediaActive) [self restartAtPosition:[self.videoView currentMediaTime]];
}

- (IBAction)selectAIVideoPreset:(NSMenuItem *)sender {
    NSString *name = sender.representedObject;
    if ([name isEqual:@"none"]) { VPAIEnhancer.shared.videoAIEnabled = NO; [VPAIEnhancer.shared resetVideoAI]; }
    else [VPAIEnhancer.shared applyVideoPreset:name];
    [self aiVideoDidChangeWithMessage:[name isEqual:@"none"] ? @"AI Video: Off" : [NSString stringWithFormat:@"AI Video: %@", sender.title]];
}

- (IBAction)selectAIUpscale:(NSMenuItem *)sender {
    double factor = [sender.representedObject doubleValue];
    VPAIEnhancer.shared.upscaleFactor = factor;
    if (factor > 1) VPAIEnhancer.shared.videoAIEnabled = YES;
    [self aiVideoDidChangeWithMessage:factor > 1 ? [NSString stringWithFormat:@"AI Upscale %.2g×", factor] : @"AI Upscale: Off"];
}

- (IBAction)toggleAIVideoLevel:(NSMenuItem *)sender {
    NSArray *spec = sender.representedObject;
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    BOOL on = ai.videoAIEnabled && [[ai valueForKey:spec[1]] doubleValue] > 0.01;
    [ai setValue:on ? @0 : spec[2] forKey:spec[1]];
    if (!on) ai.videoAIEnabled = YES;
    [self aiVideoDidChangeWithMessage:[NSString stringWithFormat:@"AI %@: %@", spec[0], on ? @"Off" : @"On"]];
}

- (IBAction)toggleAIVideoFlag:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    BOOL on = ai.videoAIEnabled && [[ai valueForKey:sender.representedObject] boolValue];
    [ai setValue:@(!on) forKey:sender.representedObject];
    if (!on) ai.videoAIEnabled = YES;
    [self aiVideoDidChangeWithMessage:[NSString stringWithFormat:@"%@: %@", sender.title, on ? @"Off" : @"On"]];
}

- (IBAction)selectAIAudioPreset:(NSMenuItem *)sender {
    NSString *name = sender.representedObject;
    if ([name isEqual:@"none"]) { VPAIEnhancer.shared.audioAIEnabled = NO; [VPAIEnhancer.shared resetAudioAI]; }
    else [VPAIEnhancer.shared applyAudioPreset:name];
    [self aiAudioDidChangeWithMessage:[name isEqual:@"none"] ? @"AI Audio: Off" : [NSString stringWithFormat:@"AI Audio: %@", sender.title]];
}

- (IBAction)selectAISurroundMethod:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    ai.surroundMethod = sender.representedObject;
    ai.audioAIEnabled = YES;
    [self aiAudioDidChangeWithMessage:[NSString stringWithFormat:@"Upsample: %@", sender.title]];
}

- (IBAction)selectAISampleRate:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    ai.targetSampleRate = sender.representedObject;
    if (![sender.representedObject isEqual:@"auto"]) ai.audioAIEnabled = YES;
    [self aiAudioDidChangeWithMessage:[NSString stringWithFormat:@"Sample Rate: %@", sender.title]];
}

- (IBAction)toggleAIAudioFlag:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    BOOL on = ai.audioAIEnabled && [[ai valueForKey:sender.representedObject] boolValue];
    [ai setValue:@(!on) forKey:sender.representedObject];
    if (!on) ai.audioAIEnabled = YES;
    [self aiAudioDidChangeWithMessage:[NSString stringWithFormat:@"%@: %@", sender.title, on ? @"Off" : @"On"]];
}

#pragma mark - Windows and tools

- (void)showBuilder:(id)sender {
    if (!self.builder) self.builder = [[VPConfigurationBuilder alloc] initWithConfig:self.configManager player:self];
    [self.builder refresh]; [self.builder showWindow:nil];
}
- (void)windowWillClose:(NSNotification *)notification { [self stopPlaybackKeepingStage]; }

#pragma mark - VPPlaybackEngineDelegate

- (void)playbackEngineDidStartPlaying { [self.videoView setPlaying:YES]; }
- (void)playbackEngineDidPause { [self.videoView setPlaying:NO]; }
- (void)playbackEngineDidStop { }

- (void)playbackEngineDidReachEnd {
    [self.videoView setPlaying:NO];
    VPPlaylistItem *next = [self.playlist advanceAutomatically:YES];
    if (next) { [self startPlaylistItem:next]; return; }
    // End of the queue: return to the stage and bring the menu back.
    [self stopPlayback:nil];
    [self.videoView setStatusText:@"Finished"];
    [self.hudOverlay showAnimated:YES];
}

- (void)playbackEngineDidUpdateTime:(CMTime)time { }

#pragma mark - Configuration window (advanced JSON editor)

- (void)showConfiguration:(id)sender {
    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 560) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.releasedWhenClosed = NO;
        self.settingsWindow.minSize = NSMakeSize(760, 560);
        self.settingsWindow.title = @"Configuration — JSON options and FFmpeg arguments";
        NSView *content = self.settingsWindow.contentView;
        NSTextField *help = [NSTextField wrappingLabelWithString:@"Edit all configuration keys below. Apply affects the next opened media. FFplay has its own playback window. Run FFmpeg uses ffmpegArguments exactly as entered; include input and output paths."];
        help.frame = NSMakeRect(16, 490, 728, 54);
        help.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [content addSubview:help];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 64, 728, 326)];
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scroll.hasVerticalScroller = YES;
        self.settingsText = [[NSTextView alloc] initWithFrame:scroll.bounds];
        self.settingsText.richText = NO;
        self.settingsText.automaticQuoteSubstitutionEnabled = NO;
        self.settingsText.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        self.settingsText.autoresizingMask = NSViewWidthSizable;
        scroll.documentView = self.settingsText;
        [content addSubview:scroll];
        NSArray *labels = @[@"Audio sample rate", @"Video processing", @"Upscale factor", @"Scaling backend"];
        NSArray *choices = @[
            @[@"auto", @"max", @"44100", @"48000", @"88200", @"96000", @"176400", @"192000", @"384000", @"768000"],
            @[@"none", @"deinterlace", @"inverseTelecine"],
            @[@"1", @"1.5", @"2", @"3", @"4"],
            @[@"metal", @"lanczos"]
        ];
        NSMutableArray *menus = [NSMutableArray array];
        for (NSUInteger i = 0; i < labels.count; i++) {
            NSTextField *label = [NSTextField labelWithString:labels[i]];
            label.frame = NSMakeRect(16 + i * 183, 453, 176, 22);
            label.autoresizingMask = NSViewMinYMargin;
            [content addSubview:label];
            NSPopUpButton *menu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16 + i * 183, 417, 176, 28) pullsDown:NO];
            [menu addItemsWithTitles:choices[i]];
            menu.tag = i;
            menu.target = self;
            menu.action = @selector(qualityOptionChanged:);
            menu.autoresizingMask = NSViewMinYMargin;
            menu.accessibilityLabel = labels[i];
            [content addSubview:menu];
            [menus addObject:menu];
        }
        self.qualityMenus = menus;
        NSArray *titles = @[@"Load…", @"Save As…", @"Apply", @"Run FFmpeg", @"Stop FFmpeg", @"5.1 Preset"];
        NSArray *selectors = @[@"loadConfiguration:", @"saveConfiguration:", @"applyConfiguration:", @"runFFmpeg:", @"stopFFmpeg:", @"surroundPreset:"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSButton *button = [NSButton buttonWithTitle:titles[i] target:self action:NSSelectorFromString(selectors[i])];
            button.frame = NSMakeRect(16 + i * 121, 18, 116, 32);
            [content addSubview:button];
        }
        [self.settingsWindow center];
    }
    [self refreshConfiguration];
    [self.settingsWindow makeKeyAndOrderFront:nil];
}

- (void)refreshConfiguration {
    NSMutableDictionary *dict = [[self.configManager toDictionary] mutableCopy];
    NSDictionary *examples = @{@"audioSampleRate":@"auto", @"deinterlace":@NO, @"inverseTelecine":@NO, @"fieldOrder":@"auto", @"upscale":@1, @"scaler":@"metal", @"audioLayout":@"auto", @"effect":@"none", @"shader":@"", @"vf":@"", @"af":@"", @"ffplayArguments":@[], @"ffmpegArguments":@[], @"loop":@NO, @"mute":@NO, @"ffmpeg":@NO, @"showMetadata":@YES, @"showFPS":@NO, @"visualizer":@NO, @"shuffle":@NO, @"repeat":@"off"};
    for (NSString *key in examples) if (!dict[key]) dict[key] = examples[key];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    self.settingsText.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *selections = @[dict[@"audioSampleRate"], [dict[@"inverseTelecine"] boolValue] ? @"inverseTelecine" : ([dict[@"deinterlace"] boolValue] ? @"deinterlace" : @"none"), [dict[@"upscale"] stringValue], dict[@"scaler"]];
    for (NSUInteger i = 0; i < self.qualityMenus.count; i++) {
        NSPopUpButton *menu = self.qualityMenus[i];
        if ([menu indexOfItemWithTitle:selections[i]] < 0) [menu addItemWithTitle:selections[i]];
        [menu selectItemWithTitle:selections[i]];
    }
}

- (void)qualityOptionChanged:(NSPopUpButton *)sender {
    if (![self readConfiguration]) return;
    NSMutableDictionary *dict = [[self.configManager toDictionary] mutableCopy];
    NSString *value = sender.titleOfSelectedItem;
    switch (sender.tag) {
        case 0: dict[@"audioSampleRate"] = value; break;
        case 1:
            dict[@"deinterlace"] = @([value isEqual:@"deinterlace"]);
            dict[@"inverseTelecine"] = @([value isEqual:@"inverseTelecine"]);
            if (![value isEqual:@"none"]) dict[@"scaler"] = @"lanczos";
            break;
        case 2: dict[@"upscale"] = @(value.doubleValue); break;
        case 3: dict[@"scaler"] = value; break;
    }
    NSError *error = nil;
    if (![self.configManager applyDictionary:dict error:&error]) [self configurationError:error];
    else [self refreshConfiguration];
}

- (void)configurationError:(NSError *)error {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Configuration";
    alert.informativeText = error.localizedDescription ?: @"Invalid JSON object.";
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
}

- (BOOL)readConfiguration {
    NSError *error = nil;
    id dict = [NSJSONSerialization JSONObjectWithData:[self.settingsText.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    if (![dict isKindOfClass:NSDictionary.class] || ![self.configManager applyDictionary:dict error:&error]) {
        [self configurationError:error]; return NO;
    }
    return YES;
}

- (void)applyConfiguration:(id)sender {
    if ([self readConfiguration]) { [self loadBackgroundImage]; [self loadPreferences]; }
}

- (void)surroundPreset:(id)sender {
    if (![self readConfiguration]) return;
    NSMutableDictionary *dict = [[self.configManager toDictionary] mutableCopy];
    dict[@"audioLayout"] = @"5.1"; dict[@"effect"] = @"none"; dict[@"shader"] = @""; dict[@"rate"] = @1;
    [self.configManager applyDictionary:dict error:nil];
    [self refreshConfiguration];
}

- (void)loadConfiguration:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.configManager loadFromPath:panel.URL.path error:&error]) [self configurationError:error];
        else { [self loadPreferences]; [self refreshConfiguration]; }
    }];
}

- (void)saveConfiguration:(id)sender {
    if (![self readConfiguration]) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"config.json";
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.configManager saveToPath:panel.URL.path error:&error]) [self configurationError:error];
    }];
}

- (void)runFFmpeg:(id)sender {
    if (![self readConfiguration] || self.ffmpegJob.running) return;
    NSArray *args = self.configManager.playbackOptions[@"ffmpegArguments"];
    if (!args.count) {
        [self configurationError:[NSError errorWithDomain:@"VPlayErrorDomain" code:73 userInfo:@{NSLocalizedDescriptionKey:@"Enter ffmpegArguments as an array of individual argument strings."}]];
        return;
    }
    NSURL *input = nil, *output = nil;
    NSDictionary *options = nil;
    NSError *error = nil;
    if (![VPFFmpegLibrary parseArguments:args input:&input output:&output options:&options error:&error]) {
        [self configurationError:error];
        return;
    }
    self.ffmpegJob = [VPFFmpegJob new];
    __weak typeof(self) weakSelf = self;
    [self.ffmpegJob startInput:input output:output options:options completion:^(NSError * _Nullable jobError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (jobError) {
                [weakSelf configurationError:jobError];
            } else {
                [weakSelf configurationError:[NSError errorWithDomain:@"VPlayFFmpeg" code:0 userInfo:@{NSLocalizedDescriptionKey:@"FFmpeg conversion finished successfully."}]];
            }
        });
    }];
}
- (void)stopFFmpeg:(id)sender {
    if (self.ffmpegJob.running) [self.ffmpegJob cancel];
}


#pragma mark - Aspect Ratio, Quality Presets, Snapshot & Missing Actions

- (IBAction)selectAspectRatio:(nullable NSMenuItem *)sender {
    if (!sender) return;
    VPAspectRatio ar = (VPAspectRatio)sender.tag;
    self.videoView.aspectRatio = ar;
    self.activeOptions[@"aspectRatio"] = @(ar);
    [self.videoView setNeedsLayout:YES];
    [self.videoView layoutSubtreeIfNeeded];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Aspect Ratio: %@", sender.title]];
}

- (void)updateProcessingHUD {
    [self.hudOverlay setNeedsDisplay:YES];
}

- (IBAction)openStream:(id)sender {
    [self openLocation:sender];
}

- (IBAction)openDiscImage:(id)sender {
    [self openDisc:sender];
}

- (IBAction)openPlaylistFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"m3u", @"m3u8", @"pls"];
#pragma clang diagnostic pop
    panel.message = @"Choose a playlist file to load.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            if ([self.playlist loadPlaylistFromURL:panel.URL clearExisting:YES error:&err]) {
                if (self.playlist.items.count > 0) {
                    [self startPlaylistItem:[self.playlist selectIndex:0]];
                }
                [self.videoView setStatusText:[NSString stringWithFormat:@"Loaded playlist with %lu items", (unsigned long)self.playlist.items.count]];
            } else {
                [self.videoView setStatusText:err.localizedDescription ?: @"Failed to load playlist"];
            }
        }
    }];
}

- (IBAction)savePlaylistFile:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"m3u"];
#pragma clang diagnostic pop
    panel.nameFieldStringValue = @"playlist.m3u";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            if ([self.playlist saveToURL:panel.URL error:&err]) {
                [self.videoView setStatusText:@"Playlist saved successfully"];
            } else {
                [self.videoView setStatusText:err.localizedDescription ?: @"Failed to save playlist"];
            }
        }
    }];
}

- (IBAction)chooseSubtitleFont:(id)sender {
    NSFontManager *fm = [NSFontManager sharedFontManager];
    [fm orderFrontFontPanel:sender];
}

- (IBAction)setSubtitleFontFromMenu:(NSMenuItem *)sender {
    if (sender.title.length) {
        self.activeOptions[@"subtitleFont"] = sender.title;
        [self.videoView setStatusText:[NSString stringWithFormat:@"Subtitle Font: %@", sender.title]];
    }
}

- (IBAction)setSubtitleStyleFromMenu:(NSMenuItem *)sender {
    if (sender.title.length) {
        self.activeOptions[@"subtitleStyle"] = sender.title;
        [self.videoView setStatusText:[NSString stringWithFormat:@"Subtitle Style: %@", sender.title]];
    }
}

- (IBAction)selectSubtitlePosition:(NSMenuItem *)sender {
    if (sender.title.length) {
        self.activeOptions[@"subtitlePosition"] = sender.title;
        [self.videoView setStatusText:[NSString stringWithFormat:@"Subtitle Position: %@", sender.title]];
    }
}

- (IBAction)selectPostProcessingLevel:(NSMenuItem *)sender {
    double level = sender.tag / 100.0;
    VPPostProcessing.shared.level = level;
    VPPostProcessing.shared.enabled = (level > 0.01);
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Post-Processing: %.0f%%", level * 100.0]];
}

- (void)applyVideoQualityPresetNamed:(NSString *)name {
    NSDictionary *preset = [VPEffectPipeline optionsForVideoQualityPresetNamed:name];
    if (!preset) return;
    [self.activeOptions addEntriesFromDictionary:preset];
    if (preset[@"upscale"]) {
        VPAIEnhancer.shared.upscaleFactor = [preset[@"upscale"] doubleValue];
    }
    if (preset[@"enabled"]) {
        VPPostProcessing.shared.enabled = [preset[@"enabled"] boolValue];
    }
    if (preset[@"level"]) {
        VPPostProcessing.shared.level = [preset[@"level"] doubleValue];
    }
    if (preset[@"contrast"]) VPPostProcessing.shared.contrast = [preset[@"contrast"] doubleValue];
    if (preset[@"sharpness"]) VPPostProcessing.shared.sharpness = [preset[@"sharpness"] doubleValue];
    if (preset[@"saturation"]) VPPostProcessing.shared.saturation = [preset[@"saturation"] doubleValue];
    if (preset[@"noiseReduction"]) VPPostProcessing.shared.noiseReduction = [preset[@"noiseReduction"] doubleValue];
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Preset: %@", name]];
}

- (IBAction)selectVideoQualityPreset:(NSMenuItem *)sender {
    [self applyVideoQualityPresetNamed:sender.representedObject ?: sender.title];
}

- (IBAction)toggleDeinterlace:(id)sender {
    BOOL current = [self.activeOptions[@"deinterlace"] boolValue];
    self.activeOptions[@"deinterlace"] = @(!current);
    if (!current) self.activeOptions[@"inverseTelecine"] = @NO;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:!current ? @"Deinterlace: Enabled" : @"Deinterlace: Disabled"];
}

- (IBAction)toggleInverseTelecine:(id)sender {
    BOOL current = [self.activeOptions[@"inverseTelecine"] boolValue];
    self.activeOptions[@"inverseTelecine"] = @(!current);
    if (!current) self.activeOptions[@"deinterlace"] = @NO;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:!current ? @"Inverse Telecine: Enabled" : @"Inverse Telecine: Disabled"];
}

- (IBAction)setDeinterlaceMode:(NSMenuItem *)sender {
    self.activeOptions[@"deinterlaceMode"] = sender.representedObject ?: sender.title;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Deinterlace Mode: %@", sender.title]];
}

- (IBAction)setDeinterlaceFieldOrder:(NSMenuItem *)sender {
    self.activeOptions[@"fieldOrder"] = sender.representedObject ?: sender.title;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Field Order: %@", sender.title]];
}

- (IBAction)takeSnapshot:(id)sender {
    CIImage *image = self.videoView.effectRenderer.currentImage ?: self.videoView.effectRenderer.currentSourceImage;
    if (!image) {
        [self.videoView setStatusText:@"No video frame available for snapshot"];
        return;
    }
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [ctx createCGImage:image fromRect:image.extent];
    if (!cgImage) {
        [self.videoView setStatusText:@"Snapshot capture failed"];
        return;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    CGImageRelease(cgImage);
    // PNG is lossless; the frame is captured now so the saved image matches what was on screen
    // when the user asked, even though the save panel is modal.
    NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!pngData) {
        [self.videoView setStatusText:@"Snapshot capture failed"];
        return;
    }

    static NSString *const kLastSnapshotDirKey = @"VPLastSnapshotDirectory";
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Save Snapshot";
    panel.message = @"Choose where to save the snapshot as a lossless PNG.";
    panel.allowedContentTypes = @[UTTypePNG];
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = [NSString stringWithFormat:@"vplay_snapshot_%@.png", [df stringFromDate:[NSDate date]]];
    NSString *lastDir = [[NSUserDefaults standardUserDefaults] stringForKey:kLastSnapshotDirKey];
    if (lastDir.length) panel.directoryURL = [NSURL fileURLWithPath:lastDir isDirectory:YES];

    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if (![pngData writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            [weakSelf.videoView setStatusText:[NSString stringWithFormat:@"Snapshot save failed: %@", error.localizedDescription]];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:panel.URL.URLByDeletingLastPathComponent.path forKey:kLastSnapshotDirKey];

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setData:pngData forType:NSPasteboardTypePNG];

        [weakSelf.videoView setStatusText:[NSString stringWithFormat:@"Snapshot saved: %@", panel.URL.lastPathComponent]];
        [weakSelf.videoView showOSDText:@"Snapshot saved" symbol:@"camera.fill" level:-1];
    }];
}

- (IBAction)replayIntro:(id)sender {
    [self.videoView playIntroWithCompletion:nil];
}

- (IBAction)showLicenseWindow:(id)sender {
    if (!self.licenseWindowController) {
        self.licenseWindowController = [[VPLicenseWindowController alloc] init];
    }
    [self.licenseWindowController showWindow:sender];
    [self.licenseWindowController.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)toggleControlsOverlay:(id)sender {
    self.videoView.controlsEnabled = !self.videoView.controlsEnabled;
    [self.videoView setStatusText:self.videoView.controlsEnabled ? @"Controls enabled" : @"Controls hidden"];
    [self.hudOverlay setToggle:@"controls" on:self.videoView.controlsEnabled];
}

- (IBAction)showAudioFilters:(id)sender {
    if (!self.audioFilterController) {
        self.audioFilterController = [VPAudioFilterWindowController new];
        __weak typeof(self) weakSelf = self;
        self.audioFilterController.applyHandler = ^{
            [weakSelf applyAudioFiltersNow];
        };
    }
    [self.audioFilterController reload];
    [self.audioFilterController showWindow:nil];
}

- (void)applyAudioFiltersNow {
    NSString *graph = [self combinedAudioFilterGraph];
    
    if (self.playbackEngine.ffmpegPlayer) {
        [self.playbackEngine.ffmpegPlayer applyAudioFiltersGraph:graph];
        if (graph.length > 0) {
            [self.videoView setStatusText:[NSString stringWithFormat:@"Audio filter: %@", graph]];
        } else {
            [self.videoView setStatusText:@"Audio filters bypassed / cleared"];
        }
    } else if (self.mediaActive) {
        NSMutableDictionary *opts = [self.activeOptions mutableCopy] ?: [NSMutableDictionary dictionary];
        opts[@"af"] = graph;
        opts[@"ffmpeg"] = @YES;
        self.activeOptions = opts;
        double pos = [self.videoView currentMediaTime];
        [self restartAtPosition:pos];
    }
}

- (IBAction)showAudioOutput:(id)sender {
    if (!self.audioOutputController) {
        self.audioOutputController = [VPAudioOutputWindowController new];
        __weak typeof(self) weakSelf = self;
        self.audioOutputController.currentSettings = ^NSDictionary<NSString *,NSString *> *{
            NSMutableDictionary *settings = [NSMutableDictionary dictionary];
            settings[@"audioSampleRate"] = weakSelf.activeOptions[@"audioSampleRate"] ?: @"auto";
            settings[@"audioLayout"] = weakSelf.activeOptions[@"audioLayout"] ?: @"auto";
            settings[@"audioDevice"] = weakSelf.activeOptions[@"audioDevice"] ?: @"";
            return settings;
        };
        self.audioOutputController.applyHandler = ^(NSDictionary<NSString *,NSString *> *settings) {
            [weakSelf applyAudioOutputSettings:settings];
        };
    }
    [self.audioOutputController reload];
    [self.audioOutputController showWindow:nil];
}

- (void)applyAudioOutputSettings:(NSDictionary<NSString *, NSString *> *)settings {
    NSString *uid = settings[@"audioDevice"];
    if (uid.length > 0) {
        NSError *error = nil;
        [VPAudioDeviceManager setOutputDeviceUID:uid error:&error];
        if (error) {
            [self.videoView setStatusText:error.localizedDescription];
        } else {
            [self.videoView setStatusText:[NSString stringWithFormat:@"Audio output: %@", uid]];
        }
    }
    
    NSMutableDictionary *opts = [self.activeOptions mutableCopy] ?: [NSMutableDictionary dictionary];
    if (settings[@"audioSampleRate"]) opts[@"audioSampleRate"] = settings[@"audioSampleRate"];
    if (settings[@"audioLayout"]) opts[@"audioLayout"] = settings[@"audioLayout"];
    if (settings[@"audioDevice"]) opts[@"audioDevice"] = settings[@"audioDevice"];
    self.activeOptions = opts;
    
    if (self.mediaActive) {
        double pos = [self.videoView currentMediaTime];
        [self restartAtPosition:pos];
    }
}
@end
