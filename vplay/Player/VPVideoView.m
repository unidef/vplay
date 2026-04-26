// Actions are sent down the responder chain (target nil), so the selectors are not declared in this file.
#pragma clang diagnostic ignored "-Wundeclared-selector"

#import "VPVideoView.h"
#import "VPFFmpegPlayer.h"
#import "VPSkin.h"
#import "VPSubtitles.h"
#import "VPEffectRenderer.h"
#import "VPFrameRateMeter.h"
#import "VPIntroView.h"
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

static NSImage *Symbol(NSString *name, NSString *description) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
}

@interface VPVideoView () <AVRoutePickerViewDelegate>
@property (nonatomic, strong) CALayer *splashLayer;
@property (nonatomic, strong) VPEffectRenderer *effectRenderer;
@property (nonatomic, strong) VPVisualizerView *visualizer;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) VPChromeView *metadataCard;
@property (nonatomic, strong) NSTextField *metadataLabel;
@property (nonatomic, strong) VPChromeView *fpsPill;
@property (nonatomic, strong) VPChromeView *osdPill;            // transient on-screen display for volume, seeking, speed…
@property (nonatomic, strong) NSImageView *osdIcon;
@property (nonatomic, strong) NSTextField *osdLabel;
@property (nonatomic, strong) NSView *osdBarTrack;
@property (nonatomic, strong) NSView *osdBarFill;
@property (nonatomic) double osdLevel;                          // negative: no level bar
@property (nonatomic) NSUInteger osdGeneration;
@property (nonatomic, strong) VPChromeView *hudToggleBack;
@property (nonatomic, strong) NSButton *hudToggle;
@property (nonatomic, strong) VPIntroView *intro;
@property (nonatomic, copy) void (^introCompletion)(void);
@property (nonatomic, strong) NSTextField *fpsLabel;
@property (nonatomic, strong) VPChromeView *airPlayOverlay;
@property (nonatomic, strong) VPChromeView *controls;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *timeLabel;
@property (nonatomic, strong) NSSlider *position;
@property (nonatomic, strong) NSSlider *volume;
@property (nonatomic, strong) NSButton *muteButton;
@property (nonatomic, strong) NSButton *airPlayButton;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *shuffleButton;
@property (nonatomic, strong) NSButton *repeatButton;
@property (nonatomic, strong) NSArray<NSButton *> *leftButtons;
@property (nonatomic, strong) NSArray<NSButton *> *rightButtons;
@property (nonatomic, strong) AVRoutePickerView *routePicker;
@property (nonatomic, strong) NSTrackingArea *mouseTracking;
@property (nonatomic, strong) NSTimer *hideTimer;
@property (nonatomic, strong) NSTimer *metadataTimer;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, weak) AVPlayer *observedPlayer;
@property (nonatomic, weak) VPFFmpegPlayer *observedFFmpegPlayer;
@property (nonatomic, strong) NSTimer *ffmpegTimeTimer;
@property (nonatomic, strong) VPFrameRateMeter *frameMeter;
@property (nonatomic, strong) VPSubtitleTrack *subtitleTrack;
@property (nonatomic, copy) NSDictionary *skin;
@property (nonatomic, strong) NSImage *skinStageImage;
@property (nonatomic) BOOL routesPresented;
@property (nonatomic) BOOL showsPause;
@property (nonatomic) BOOL chromeShown;
@property (nonatomic) NSUInteger visibilityGeneration;
@property (nonatomic) NSUInteger metadataGeneration;
@property (nonatomic) double lastMeasuredFPS;
@property (nonatomic) CVPixelBufferRef latestFFmpegPixelBuffer;
@property (nonatomic) os_unfair_lock ffmpegBufferLock;
@property (nonatomic) BOOL ffmpegRenderPending;
@end

@implementation VPVideoView

#pragma mark - Setup

- (void)setAspectRatio:(VPAspectRatio)aspectRatio {
    _aspectRatio = aspectRatio;
    [self setNeedsLayout:YES];
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _skin = [VPSkin defaultSkin];

        _splashLayer = [CALayer layer];
        _splashLayer.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_splashLayer];
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:nil];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _playerLayer.zPosition = 0;
        [self.layer addSublayer:_playerLayer];
        _effectRenderer = [VPEffectRenderer new];
        _effectRenderer.layer.zPosition = 1;
        [self.layer addSublayer:_effectRenderer.layer];
        [self loadBuiltInSplash];

        _visualizer = [[VPVisualizerView alloc] initWithFrame:NSZeroRect];
        _visualizer.hidden = YES;
        _visualizer.wantsLayer = YES;
        _visualizer.layer.zPosition = 10;
        [self addSubview:_visualizer];

        _subtitleLabel = [NSTextField wrappingLabelWithString:@""];
        _subtitleLabel.alignment = NSTextAlignmentCenter;
        _subtitleLabel.maximumNumberOfLines = 4;
        _subtitleLabel.hidden = YES;
        _subtitleLabel.wantsLayer = YES;
        _subtitleLabel.layer.zPosition = 200;
        _subtitleLabel.layer.cornerRadius = 6.0;
        _subtitleLabel.layer.masksToBounds = YES;
        _subtitleLabel.drawsBackground = YES;
        _subtitleLabel.backgroundColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.65];
        [self addSubview:_subtitleLabel positioned:NSWindowAbove relativeTo:nil];

        [self buildMetadataCard];
        [self buildFPSPill];
        [self buildOSD];
        [self buildAirPlayOverlay];
        [self buildControls];
        [self buildHUDToggle];
        _controlsEnabled = YES;
        _ffmpegBufferLock = OS_UNFAIR_LOCK_INIT;
        [self applySkin:VPSkin.defaultSkin];
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL]];
        [self setPlaying:NO];
        [self showControls];
    }
    return self;
}

- (void)loadBuiltInSplash {
    NSImage *image = [NSBundle.mainBundle imageForResource:@"vplay-splash"];
    self.splashImage = image;
}

- (void)setSplashImage:(NSImage *)image {
    _splashImage = image;
    NSImage *effective = image ?: self.skinStageImage ?: [NSBundle.mainBundle imageForResource:@"vplay-splash"];
    CGImageRef cg = [effective CGImageForProposedRect:NULL context:nil hints:nil];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.splashLayer.contents = cg ? (__bridge id)cg : nil;
    [CATransaction commit];
}

- (NSButton *)iconButton:(NSString *)symbol tip:(NSString *)tip action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:Symbol(symbol, tip) target:nil action:action];
    button.bordered = NO;
    button.toolTip = tip;
    button.accessibilityLabel = tip;
    button.imageScaling = NSImageScaleProportionallyDown;
    [self.controls addSubview:button];
    return button;
}

- (void)buildControls {
    _controls = [[VPChromeView alloc] initWithFrame:NSZeroRect];
    _controls.wantsLayer = YES;
    _controls.layer.zPosition = 300;
    [self addSubview:_controls];
    _statusLabel = [NSTextField labelWithString:@"Open media from the menu, drop a file here, or press Tab"];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_controls addSubview:_statusLabel];
    _position = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(seek:)];
    _position.continuous = NO;
    _position.accessibilityLabel = @"Playback position";
    [_controls addSubview:_position];
    _timeLabel = [NSTextField labelWithString:@"00:00 / --:--"];
    _timeLabel.alignment = NSTextAlignmentCenter;
    [_controls addSubview:_timeLabel];
    _volume = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(changeVolume:)];
    _volume.accessibilityLabel = @"Volume";
    [_controls addSubview:_volume];

    NSButton *previous = [self iconButton:@"backward.end.fill" tip:@"Previous" action:@selector(playPrevious:)];
    _playButton = [self iconButton:@"play.fill" tip:@"Play / Pause" action:@selector(togglePlayPause:)];
    NSButton *next = [self iconButton:@"forward.end.fill" tip:@"Next" action:@selector(playNext:)];
    NSButton *stop = [self iconButton:@"stop.fill" tip:@"Stop" action:@selector(stopPlayback:)];
    _leftButtons = @[previous, _playButton, next, stop];
    _muteButton = [self iconButton:@"speaker.wave.2.fill" tip:@"Mute (M)" action:@selector(toggleMute:)];

    _shuffleButton = [self iconButton:@"shuffle" tip:@"Shuffle" action:@selector(toggleShuffle:)];
    _repeatButton = [self iconButton:@"repeat" tip:@"Repeat" action:@selector(cycleRepeat:)];
    _airPlayButton = [self iconButton:@"airplayvideo" tip:@"AirPlay" action:@selector(showAirPlay:)];
    NSButton *tracks = [self iconButton:@"captions.bubble" tip:@"Audio, video and subtitle tracks" action:@selector(showTracksMenu:)];
    NSButton *playlist = [self iconButton:@"list.bullet" tip:@"Playlist" action:@selector(showPlaylist:)];
    NSButton *full = [self iconButton:@"arrow.up.left.and.arrow.down.right" tip:@"Full Screen" action:@selector(toggleFullScreen:)];
    NSButton *menu = [self iconButton:@"line.3.horizontal" tip:@"Show menu (Tab)" action:@selector(toggleHUD:)];
    // Order from the right edge inward.
    _rightButtons = @[menu, full, playlist, _airPlayButton, tracks, _repeatButton, _shuffleButton];
}

- (void)buildHUDToggle {
    _hudToggleBack = [[VPChromeView alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)];
    _hudToggleBack.wantsLayer = YES;
    _hudToggleBack.layer.zPosition = 300;
    _hudToggle = [NSButton buttonWithImage:Symbol(@"sidebar.left", @"Show or hide the menu panel") target:nil action:@selector(toggleHUD:)];
    _hudToggle.bordered = NO; _hudToggle.frame = NSMakeRect(2, 2, 36, 36);
    _hudToggle.toolTip = @"Show or hide the menu panel (Tab)";
    _hudToggle.accessibilityLabel = @"Show or hide the menu panel";
    _hudToggle.imageScaling = NSImageScaleProportionallyDown;
    [_hudToggleBack addSubview:_hudToggle];
    [self addSubview:_hudToggleBack];
}

- (void)setHudVisible:(BOOL)visible {
    _hudVisible = visible;
    self.hudToggle.image = Symbol(visible ? @"sidebar.left" : @"sidebar.left", @"Show or hide the menu panel");
    self.hudToggle.contentTintColor = visible ? [VPSkin color:self.skin[@"accentColor"]] : [VPSkin color:self.skin[@"textColor"]];
}

- (void)buildAirPlayOverlay {
    _airPlayOverlay = [[VPChromeView alloc] initWithFrame:NSMakeRect(0, 0, 58, 46)];
    _airPlayOverlay.wantsLayer = YES;
    _airPlayOverlay.layer.zPosition = 300;
    _routePicker = [[AVRoutePickerView alloc] initWithFrame:NSMakeRect(9, 6, 40, 34)];
    _routePicker.delegate = self;
    _routePicker.toolTip = @"AirPlay";
    _routePicker.accessibilityLabel = @"AirPlay output";
    [_airPlayOverlay addSubview:_routePicker];
    [self addSubview:_airPlayOverlay];
    _airPlayOverlay.hidden = YES;
}

- (void)buildFPSPill {
    _fpsPill = [[VPChromeView alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    _fpsPill.wantsLayer = YES;
    _fpsPill.layer.zPosition = 300;
    _fpsLabel = [NSTextField labelWithString:@"FPS —"];
    _fpsLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    _fpsLabel.alignment = NSTextAlignmentCenter;
    [_fpsPill addSubview:_fpsLabel];
    _fpsPill.hidden = YES;
    [self addSubview:_fpsPill];
}

- (void)buildOSD {
    _osdPill = [[VPChromeView alloc] initWithFrame:NSMakeRect(0, 0, 220, 64)];
    _osdPill.wantsLayer = YES;
    _osdPill.layer.zPosition = 400;
    _osdIcon = [NSImageView imageViewWithImage:Symbol(@"speaker.wave.2.fill", @"")];
    _osdIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightSemibold];
    _osdIcon.contentTintColor = NSColor.whiteColor;
    [_osdPill addSubview:_osdIcon];
    _osdLabel = [NSTextField labelWithString:@""];
    _osdLabel.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightSemibold];
    _osdLabel.textColor = NSColor.whiteColor;
    [_osdPill addSubview:_osdLabel];
    _osdBarTrack = [[NSView alloc] initWithFrame:NSZeroRect];
    _osdBarTrack.wantsLayer = YES;
    _osdBarTrack.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.28].CGColor;
    _osdBarTrack.layer.cornerRadius = 2;
    [_osdPill addSubview:_osdBarTrack];
    _osdBarFill = [[NSView alloc] initWithFrame:NSZeroRect];
    _osdBarFill.wantsLayer = YES;
    _osdBarFill.layer.backgroundColor = NSColor.whiteColor.CGColor;
    _osdBarFill.layer.cornerRadius = 2;
    [_osdBarTrack addSubview:_osdBarFill];
    _osdPill.alphaValue = 0;
    _osdPill.hidden = YES;
    [self addSubview:_osdPill];
}

- (void)layoutOSD {
    BOOL bar = self.osdLevel >= 0;
    CGFloat textWidth = ceil([self.osdLabel.stringValue sizeWithAttributes:@{NSFontAttributeName: self.osdLabel.font}].width);
    CGFloat width = MIN(MAX(150, 20 + 34 + 10 + textWidth + 20), MAX(150, self.bounds.size.width - 40));
    CGFloat height = bar ? 74 : 56;
    self.osdPill.frame = NSMakeRect(round((self.bounds.size.width - width) / 2), round(self.bounds.size.height * 0.62), width, height);
    CGFloat top = bar ? 20 : 0;
    self.osdIcon.frame = NSMakeRect(18, top + (height - top - 30) / 2, 34, 30);
    self.osdLabel.frame = NSMakeRect(60, top + (height - top - 22) / 2, width - 60 - 16, 22);
    self.osdBarTrack.hidden = !bar;
    self.osdBarTrack.frame = NSMakeRect(18, 14, width - 36, 4);
    self.osdBarFill.frame = NSMakeRect(0, 0, MAX(0, MIN(1, self.osdLevel)) * (width - 36), 4);
}

- (void)showOSDText:(NSString *)text symbol:(NSString *)symbol level:(double)level {
    if (self.overlaysHidden) return;
    self.osdLabel.stringValue = text ?: @"";
    self.osdIcon.image = Symbol(symbol ?: @"info.circle", text);
    self.osdLevel = level;
    [self layoutOSD];
    self.osdPill.hidden = NO;
    NSUInteger generation = ++self.osdGeneration;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.1;
        self.osdPill.animator.alphaValue = 1;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.osdGeneration) return;   // a newer event keeps the display up
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.35;
            self.osdPill.animator.alphaValue = 0;
        } completionHandler:^{
            if (generation == self.osdGeneration) self.osdPill.hidden = YES;
        }];
    });
}

- (void)buildMetadataCard {
    _metadataCard = [[VPChromeView alloc] initWithFrame:NSZeroRect];
    _metadataCard.wantsLayer = YES;
    _metadataCard.layer.zPosition = 300;
    _metadataLabel = [NSTextField wrappingLabelWithString:@""];
    [_metadataCard addSubview:_metadataLabel];
    _metadataCard.hidden = YES;
    _metadataCard.alphaValue = 0;
    [self addSubview:_metadataCard];
}

- (void)dealloc {
    [self.hideTimer invalidate]; [self.metadataTimer invalidate];
    [self removeTimeObserver];
    [self.frameMeter stop];
    os_unfair_lock_lock(&_ffmpegBufferLock);
    if (_latestFFmpegPixelBuffer) {
        CVPixelBufferRelease(_latestFFmpegPixelBuffer);
        _latestFFmpegPixelBuffer = NULL;
    }
    _ffmpegRenderPending = NO;
    os_unfair_lock_unlock(&_ffmpegBufferLock);
}

#pragma mark - Layout

- (BOOL)controlsVisible { return self.chromeShown; }
- (BOOL)airPlayOverlayVisible { return !self.airPlayOverlay.hidden && self.airPlayOverlay.alphaValue > 0.5; }
- (BOOL)isFlipped { return NO; }

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;
    NSRect videoRect = bounds;
    if (self.aspectRatio == VPAspectRatioAuto) {
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.effectRenderer.layer.contentsGravity = kCAGravityResizeAspect;
    } else if (self.aspectRatio == VPAspectRatioStretch) {
        self.playerLayer.videoGravity = AVLayerVideoGravityResize;
        self.effectRenderer.layer.contentsGravity = kCAGravityResize;
    } else if (self.aspectRatio == VPAspectRatioCropFill) {
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.effectRenderer.layer.contentsGravity = kCAGravityResizeAspectFill;
    } else {
        double ratio = 16.0 / 9.0;
        if (self.aspectRatio == VPAspectRatio16_10) ratio = 16.0 / 10.0;
        else if (self.aspectRatio == VPAspectRatio4_3) ratio = 4.0 / 3.0;
        else if (self.aspectRatio == VPAspectRatio21_9) ratio = 2.3869;
        else if (self.aspectRatio == VPAspectRatio1_1) ratio = 1.0;
        
        CGFloat boundsRatio = w / (h > 0 ? h : 1);
        if (boundsRatio > ratio) {
            CGFloat targetW = round(h * ratio);
            videoRect = NSMakeRect(round((w - targetW) / 2.0), 0, targetW, h);
        } else {
            CGFloat targetH = round(w / ratio);
            videoRect = NSMakeRect(0, round((h - targetH) / 2.0), w, targetH);
        }
        self.playerLayer.videoGravity = AVLayerVideoGravityResize;
        self.effectRenderer.layer.contentsGravity = kCAGravityResize;
    }

    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.splashLayer.frame = NSInsetRect(bounds, 0, 0);
    self.playerLayer.frame = videoRect;
    self.effectRenderer.layer.frame = videoRect;
    [CATransaction commit];

    self.visualizer.frame = self.hasVideo ? NSMakeRect(0, 0, w, h * 0.30) : NSMakeRect(w * 0.08, h * 0.2, w * 0.84, h * 0.55);

    CGFloat barWidth = MAX(340, MIN(860, w - 32));
    self.controls.frame = NSMakeRect((w - barWidth) / 2, 18, barWidth, 112);
    self.statusLabel.frame = NSMakeRect(16, 84, barWidth - 32, 20);
    self.position.frame = NSMakeRect(16, 60, barWidth - 32, 18);
    CGFloat left = 10;
    for (NSButton *button in self.leftButtons) { button.frame = NSMakeRect(left, 14, 34, 32); left += 36; }
    BOOL roomy = barWidth >= 560, medium = barWidth >= 460;
    CGFloat right = barWidth - 10;
    for (NSButton *button in self.rightButtons) {
        BOOL optional = button == self.shuffleButton || button == self.repeatButton || button == self.airPlayButton;
        BOOL show = optional ? roomy : (button.toolTip.length && [button.toolTip hasPrefix:@"Playlist"] ? medium : YES);
        button.hidden = !show;
        if (!show) continue;
        right -= 36; button.frame = NSMakeRect(right, 14, 34, 32);
    }
    self.volume.hidden = !medium; self.muteButton.hidden = !medium;
    if (medium) {
        right -= 96; self.volume.frame = NSMakeRect(right, 20, 90, 20);
        right -= 36; self.muteButton.frame = NSMakeRect(right, 14, 34, 32);
    }
    CGFloat timeWidth = right - left - 12;
    self.timeLabel.hidden = timeWidth < 90;
    self.timeLabel.frame = NSMakeRect(left + 6, 20, MAX(0, timeWidth), 20);

    self.hudToggleBack.frame = NSMakeRect(16, h - 40 - 12, 40, 40);
    self.airPlayOverlay.frame = NSMakeRect(w - 58 - 16, h - 46 - 16, 58, 46);
    self.fpsPill.frame = NSMakeRect(w - 150 - 16, h - 46 - 16 - 8 - 26, 150, 26);
    self.fpsLabel.frame = NSMakeRect(6, 3, 138, 20);
    if (!self.osdPill.hidden) [self layoutOSD];
    [self layoutMetadataCard];
    [self layoutSubtitle];
}

- (void)layoutMetadataCard {
    CGFloat maxWidth = MIN(520, self.bounds.size.width - 200);
    NSAttributedString *text = self.metadataLabel.attributedStringValue;
    NSRect box = [text boundingRectWithSize:NSMakeSize(maxWidth - 28, 600) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    CGFloat cardWidth = MIN(maxWidth, ceil(box.size.width) + 48), cardHeight = ceil(box.size.height) + 24;
    self.metadataCard.frame = NSMakeRect(66, self.bounds.size.height - 16 - cardHeight, cardWidth, cardHeight);
    self.metadataLabel.frame = NSMakeRect(16, 12, cardWidth - 32, cardHeight - 24);
}

- (void)layoutSubtitle {
    if (self.subtitleLabel.hidden) return;
    CGFloat maxWidth = self.bounds.size.width * 0.85;
    if (maxWidth < 100) return;
    NSAttributedString *attrStr = self.subtitleLabel.attributedStringValue;
    if (!attrStr.length) return;
    NSRect box = [attrStr boundingRectWithSize:NSMakeSize(maxWidth, 400) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    CGFloat width = MIN(maxWidth, ceil(box.size.width) + 32);
    CGFloat height = ceil(box.size.height) + 14;
    CGFloat y = self.chromeShown ? 148 : 46;
    self.subtitleLabel.frame = NSMakeRect(floor((self.bounds.size.width - width) / 2.0), y, width, height);
}

#pragma mark - Mouse, dragging, menu

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.mouseTracking) [self removeTrackingArea:self.mouseTracking];
    self.mouseTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways owner:self userInfo:nil];
    [self addTrackingArea:self.mouseTracking];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; self.window.acceptsMouseMovedEvents = YES; }
- (void)mouseEntered:(NSEvent *)event { [self showControls]; }
- (void)mouseExited:(NSEvent *)event { [self showControls]; }
- (void)mouseMoved:(NSEvent *)event { [self showControls]; }
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) [self.window toggleFullScreen:nil];
    else [super mouseDown:event];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (self.contextMenuProvider) {
        NSMenu *menu = self.contextMenuProvider();
        if (menu) return menu;
    }
    return self.contextMenu ?: [super menuForEvent:event];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:nil];
    if (!urls.count || !self.dropHandler) return NO;
    self.dropHandler(urls);
    return YES;
}

#pragma mark - Controls visibility

- (void)setChromeAlpha:(CGFloat)alpha animated:(BOOL)animated {
    if (self.overlaysHidden) alpha = 0;
    BOOL show = alpha > 0 && self.mediaLoaded;      // the empty stage shows only the logo, the menu panel and its button
    BOOL airPlayAvailable = self.playerLayer.player != nil;
    CGFloat controlsAlpha = show && self.controlsEnabled ? alpha : 0;
    CGFloat toggleAlpha = self.overlaysHidden ? 0 : (self.mediaLoaded ? alpha : 1);   // always reachable while idle
    self.controls.hidden = NO; self.hudToggleBack.hidden = NO;
    if (show && airPlayAvailable) self.airPlayOverlay.hidden = NO;
    self.chromeShown = controlsAlpha > 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = animated ? 0.25 : 0;
        self.controls.animator.alphaValue = controlsAlpha;
        self.airPlayOverlay.animator.alphaValue = show && airPlayAvailable ? alpha : 0;
        self.hudToggleBack.animator.alphaValue = toggleAlpha;
    } completionHandler:^{
        if (controlsAlpha == 0) self.controls.hidden = YES;
        if (!(show && airPlayAvailable)) self.airPlayOverlay.hidden = YES;
        if (toggleAlpha == 0) self.hudToggleBack.hidden = YES;
    }];
    [self layoutSubtitle];
}

- (void)setControlsEnabled:(BOOL)enabled { _controlsEnabled = enabled; [self setChromeAlpha:1 animated:YES]; [self showControls]; }

- (void)setOverlaysHidden:(BOOL)hidden {
    _overlaysHidden = hidden;
    if (hidden) {
        [self.hideTimer invalidate];
        [self setChromeAlpha:0 animated:YES];
        self.fpsPill.hidden = YES; self.metadataCard.hidden = YES;
    } else {
        self.fpsPill.hidden = !self.fpsVisible;
        [self showControls];
    }
}

- (void)showControls {
    self.visibilityGeneration++;
    [self.hideTimer invalidate];
    if (self.overlaysHidden) return;
    if (!self.chromeShown || self.controls.alphaValue < 1 || self.controls.hidden || self.hudToggleBack.alphaValue < 1) [self setChromeAlpha:1 animated:YES];
    if (self.routesPresented) return;
    __weak typeof(self) weakSelf = self;
    self.hideTimer = [NSTimer timerWithTimeInterval:4 repeats:NO block:^(NSTimer *timer) {
        VPVideoView *view = weakSelf;
        if (!view) return;
        if (NSEvent.pressedMouseButtons || view.routesPresented) { [view showControls]; return; }
        [view setChromeAlpha:0 animated:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.hideTimer forMode:NSRunLoopCommonModes];
}

- (void)showAirPlayOverlay { [self showControls]; }
- (void)routePickerViewWillBeginPresentingRoutes:(AVRoutePickerView *)routePickerView { self.routesPresented = YES; [self showControls]; }
- (void)routePickerViewDidEndPresentingRoutes:(AVRoutePickerView *)routePickerView { self.routesPresented = NO; [self showControls]; }

- (void)setStatusText:(NSString *)text { self.statusLabel.stringValue = text ?: @""; [self showControls]; }

#pragma mark - Skin

- (void)applySkin:(NSDictionary *)skin {
    self.skin = skin;
    NSColor *text = [VPSkin color:skin[@"textColor"]], *accent = [VPSkin color:skin[@"accentColor"]];
    self.layer.backgroundColor = [VPSkin color:skin[@"backgroundColor"]].CGColor;
    self.skinStageImage = [skin[@"stageImage"] length] ? [[NSImage alloc] initWithContentsOfFile:skin[@"stageImage"]] : nil;
    [self setSplashImage:self.splashImage];
    NSDictionary *pillSkin = skin;
    for (VPChromeView *panel in @[self.controls, self.airPlayOverlay, self.metadataCard, self.fpsPill, self.hudToggleBack, self.osdPill]) panel.skin = pillSkin;
    self.hudVisible = self.hudVisible;
    self.airPlayOverlay.skin = skin;
    CGFloat size = [skin[@"fontSize"] doubleValue];
    self.statusLabel.textColor = text; self.statusLabel.font = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    self.timeLabel.textColor = text; self.timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:size - 1 weight:NSFontWeightRegular];
    self.fpsLabel.textColor = text;
    for (NSButton *button in [[self.leftButtons arrayByAddingObjectsFromArray:self.rightButtons] arrayByAddingObject:self.muteButton]) button.contentTintColor = text;
    self.position.trackFillColor = accent; self.volume.trackFillColor = accent;
    [self.routePicker setRoutePickerButtonColor:text forState:AVRoutePickerViewButtonStateNormal];
    [self.routePicker setRoutePickerButtonColor:accent forState:AVRoutePickerViewButtonStateActive];
    self.visualizer.accentColor = accent;
    [self refreshModeButtons];
}

- (void)refreshModeButtons {
    NSColor *accent = [VPSkin color:self.skin[@"accentColor"]], *text = [VPSkin color:self.skin[@"textColor"]];
    self.shuffleButton.contentTintColor = self.shuffleButton.state == NSControlStateValueOn ? accent : text;
    self.repeatButton.contentTintColor = self.repeatButton.state == NSControlStateValueOn ? accent : text;
}

#pragma mark - Stage state

- (void)setMediaLoaded:(BOOL)loaded {
    _mediaLoaded = loaded;
    if (loaded) [self cancelIntro];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.4;
        self.splashLayer.opacity = loaded ? 0 : 1;
    }];
    [self updateVisualizerVisibility];
    if (loaded) [self showControls]; else [self setChromeAlpha:0 animated:NO];
}

- (void)setHasVideo:(BOOL)hasVideo {
    BOOL changed = _hasVideo != hasVideo;
    _hasVideo = hasVideo; [self updateVisualizerVisibility]; self.needsLayout = YES;
    if (changed && self.fpsVisible) [self startFrameMeter];
}
- (void)setVisualizerOverVideo:(BOOL)over { _visualizerOverVideo = over; [self updateVisualizerVisibility]; }
- (void)setVisualizerStyle:(VPVisualizerStyle)style { _visualizerStyle = style; self.visualizer.style = style; }
- (void)setAnalyzer:(VPAudioAnalyzer *)analyzer { _analyzer = analyzer; self.visualizer.analyzer = analyzer; }

- (void)updateVisualizerVisibility {
    BOOL show = self.mediaLoaded && (!self.hasVideo || self.visualizerOverVideo);
    self.visualizer.hidden = !show;
    self.visualizer.animating = show;
}

- (void)setFpsVisible:(BOOL)visible {
    _fpsVisible = visible;
    self.fpsPill.hidden = !visible || self.overlaysHidden;
    if (!visible) { [self.frameMeter stop]; self.frameMeter = nil; return; }
    [self startFrameMeter];
}

- (void)startFrameMeter {
    AVPlayerItem *item = self.playerLayer.player.currentItem;
    [self.frameMeter stop]; self.frameMeter = nil;
    self.fpsLabel.stringValue = @"FPS —";
    if (!self.fpsVisible || !item || !self.hasVideo) return;
    VPFrameRateMeter *meter = [VPFrameRateMeter new];
    __weak typeof(self) weakSelf = self;
    meter.onUpdate = ^(double fps) {
        VPVideoView *view = weakSelf;
        if (!view) return;
        // The player pauses frame delivery; show 0 rather than a stale rate.
        BOOL playing = view.playerLayer.player.rate > 0;
        double shown = playing ? fps : 0;
        view.fpsLabel.stringValue = view.sourceFrameRate > 0 ? [NSString stringWithFormat:@"FPS %.1f / %.2f", shown, view.sourceFrameRate] : [NSString stringWithFormat:@"FPS %.1f", shown];
    };
    [meter startWithItem:item];
    self.frameMeter = meter;
}

- (void)syncPlayingIcon {
    BOOL playing = self.observedFFmpegPlayer ? self.observedFFmpegPlayer.isPlaying : self.playerLayer.player.rate > 0;
    if (playing != self.showsPause) [self setPlaying:playing];
}

- (void)setPlaying:(BOOL)playing {
    self.showsPause = playing;
    self.playButton.image = Symbol(playing ? @"pause.fill" : @"play.fill", playing ? @"Pause" : @"Play");
}

- (void)setShuffleOn:(BOOL)on repeatMode:(VPRepeatMode)mode {
    self.shuffleButton.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    self.repeatButton.state = mode == VPRepeatOff ? NSControlStateValueOff : NSControlStateValueOn;
    self.repeatButton.image = Symbol(mode == VPRepeatOne ? @"repeat.1" : @"repeat", mode == VPRepeatOne ? @"Repeat one" : @"Repeat");
    [self refreshModeButtons];
}

#pragma mark - Intro

- (BOOL)introRunning { return self.intro != nil; }

- (void)playIntroWithCompletion:(void (^)(void))completion {
    [self cancelIntro];
    self.introCompletion = completion;
    self.splashLayer.opacity = 0;
    VPIntroView *intro = [[VPIntroView alloc] initWithFrame:self.bounds];
    intro.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    intro.accentColor = [VPSkin color:self.skin[@"accentColor"]];
    [self addSubview:intro positioned:NSWindowBelow relativeTo:self.visualizer];
    self.intro = intro;
    __weak typeof(self) weakSelf = self;
    __weak VPIntroView *weakIntro = intro;
    intro.finishHandler = ^{
        VPVideoView *view = weakSelf;
        VPIntroView *finished = weakIntro;
        if (!view || !finished) return;
        // Cross-fade into the static logo, which lines up with the animation's last frame.
        BOOL stageVisible = !view.mediaLoaded;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = stageVisible ? 0.6 : 0.1;
            finished.animator.alphaValue = 0;
            if (stageVisible) view.splashLayer.opacity = 1;
        } completionHandler:^{
            [finished removeFromSuperview];
            if (view.intro == finished) view.intro = nil;
        }];
        void (^done)(void) = view.introCompletion; view.introCompletion = nil;
        if (done) done();
    };
    [intro start];
}

- (void)cancelIntro {
    if (!self.intro) return;
    VPIntroView *intro = self.intro;
    self.intro = nil;
    intro.finishHandler = nil;
    [intro skip];
    [intro removeFromSuperview];
    self.splashLayer.opacity = self.mediaLoaded ? 0 : 1;
    void (^done)(void) = self.introCompletion; self.introCompletion = nil;
    if (done) done();
}

#pragma mark - Metadata

- (void)showMetadataLines:(NSArray<NSString *> *)lines {
    if (!lines.count) return;
    NSColor *text = [VPSkin color:self.skin[@"textColor"]];
    CGFloat size = [self.skin[@"fontSize"] doubleValue];
    NSMutableAttributedString *content = [NSMutableAttributedString new];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSFont *font = i == 0 ? [NSFont systemFontOfSize:size + 5 weight:NSFontWeightBold] : [NSFont systemFontOfSize:size - 1 weight:NSFontWeightRegular];
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new]; style.paragraphSpacing = i == 0 ? 6 : 2;
        NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:i == 0 ? text : [text colorWithAlphaComponent:0.88], NSParagraphStyleAttributeName:style};
        [content appendAttributedString:[[NSAttributedString alloc] initWithString:[lines[i] stringByAppendingString:i + 1 < lines.count ? @"\n" : @""] attributes:attributes]];
    }
    self.metadataLabel.attributedStringValue = content;
    [self layoutMetadataCard];
    self.metadataCard.hidden = NO;
    NSUInteger generation = ++self.metadataGeneration;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) { context.duration = 0.3; self.metadataCard.animator.alphaValue = 1; }];
    [self.metadataTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.metadataTimer = [NSTimer scheduledTimerWithTimeInterval:8 repeats:NO block:^(NSTimer *timer) {
        VPVideoView *view = weakSelf;
        if (view && view.metadataGeneration == generation) [view hideMetadata];
    }];
}

- (void)hideMetadata {
    [self.metadataTimer invalidate]; self.metadataTimer = nil;
    NSUInteger generation = ++self.metadataGeneration;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 1.0;
        self.metadataCard.animator.alphaValue = 0;
    } completionHandler:^{ if (generation == self.metadataGeneration) self.metadataCard.hidden = YES; }];
}

#pragma mark - Subtitles

- (void)setSubtitleTrack:(VPSubtitleTrack *)track {
    _subtitleTrack = track;
    [self updateSubtitleForTime:[self currentMediaTime]];
}

- (void)updateSubtitleForTime:(double)seconds {
    NSString *text = [self.subtitleTrack textAtTime:seconds];
    if (!text.length) {
        if (!self.subtitleLabel.hidden) {
            self.subtitleLabel.hidden = YES;
            self.subtitleLabel.stringValue = @"";
        }
        return;
    }
    if ([self.subtitleLabel.stringValue isEqual:text] && !self.subtitleLabel.hidden) return;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineSpacing = 2;
    // No NSShadow: the label already has a dark backing box, and a blurred shadow on top of it
    // (clipped by masksToBounds) shows up as black smudges around the glyphs.
    CGFloat size = MAX(18, MIN(36, self.bounds.size.height / 24));
    self.subtitleLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:NSColor.whiteColor,
        NSStrokeColorAttributeName:NSColor.blackColor,
        NSStrokeWidthAttributeName:@-2.5,
        NSParagraphStyleAttributeName:style
    }];
    self.subtitleLabel.hidden = NO;
    [self layoutSubtitle];
    self.subtitleLabel.needsDisplay = YES;
}

#pragma mark - Player

- (double)currentMediaTime {
    if (self.observedFFmpegPlayer) {
        return self.observedFFmpegPlayer.currentTime;
    }
    double now = CMTimeGetSeconds(self.playerLayer.player.currentTime);
    return (isfinite(now) ? MAX(0, now) : 0) + self.displayOffset;
}

- (double)effectiveDuration {
    if (self.knownDuration > 0) return self.knownDuration;
    if (self.observedFFmpegPlayer) {
        double d = self.observedFFmpegPlayer.duration;
        return isfinite(d) && d > 0 ? d : 0;
    }
    double duration = CMTimeGetSeconds(self.playerLayer.player.currentItem.duration);
    return isfinite(duration) && duration > 0 ? duration : 0;
}

static NSString *Clock(double seconds) {
    long s = isfinite(seconds) ? MAX(0, (long)seconds) : 0;
    return s >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60] : [NSString stringWithFormat:@"%02ld:%02ld", s / 60, s % 60];
}

- (void)removeTimeObserver {
    if (self.timeObserver && self.observedPlayer) [self.observedPlayer removeTimeObserver:self.timeObserver];
    self.timeObserver = nil; self.observedPlayer = nil;
}

- (void)attachPlayer:(AVPlayer *)player {
    [self detachPlayer];
    self.playerLayer.player = player;
    self.routePicker.player = player;
    player.allowsExternalPlayback = YES;
    self.volume.doubleValue = player.volume;
    self.position.enabled = player != nil;
    self.playButton.enabled = player != nil;
    self.observedPlayer = player;
    __weak typeof(self) weakSelf = self;
    if (player) self.timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        VPVideoView *view = weakSelf;
        if (!view) return;
        double current = [view currentMediaTime], duration = [view effectiveDuration];
        BOOL seekable = duration > 0;
        view.position.enabled = seekable;
        if (seekable && !NSEvent.pressedMouseButtons) view.position.doubleValue = MIN(1, current / duration);
        view.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", Clock(current), seekable ? Clock(duration) : @"--:--"];
        [view updateSubtitleForTime:current];
        [view syncPlayingIcon];
    }];
    [self startFrameMeter];
    [self setChromeAlpha:1 animated:NO];
    [self showControls];
}

- (void)updatePlaybackTimeDisplay {
    double current = [self currentMediaTime], duration = [self effectiveDuration];
    BOOL seekable = duration > 0;
    self.position.enabled = seekable;
    if (seekable && !NSEvent.pressedMouseButtons) self.position.doubleValue = MIN(1, current / duration);
    self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", Clock(current), seekable ? Clock(duration) : @"--:--"];
    [self updateSubtitleForTime:current];
    [self syncPlayingIcon];
}

- (void)attachFFmpegPlayer:(VPFFmpegPlayer *)ffmpegPlayer {
    [self detachPlayer];
    self.observedFFmpegPlayer = ffmpegPlayer;
    self.volume.doubleValue = ffmpegPlayer.volume;
    self.position.enabled = ffmpegPlayer != nil;
    self.playButton.enabled = ffmpegPlayer != nil;
    self.playerLayer.hidden = YES;
    
    __weak typeof(self) weakSelf = self;
    ffmpegPlayer.frameHandler = ^(CVPixelBufferRef pixelBuffer, double pts) {
        if (!pixelBuffer) return;
        VPVideoView *strongSelf = weakSelf;
        if (!strongSelf) return;
        
        CVPixelBufferRetain(pixelBuffer);
        os_unfair_lock_lock(&strongSelf->_ffmpegBufferLock);
        if (strongSelf->_latestFFmpegPixelBuffer) {
            CVPixelBufferRelease(strongSelf->_latestFFmpegPixelBuffer);
        }
        strongSelf->_latestFFmpegPixelBuffer = pixelBuffer;
        BOOL shouldSchedule = !strongSelf->_ffmpegRenderPending;
        strongSelf->_ffmpegRenderPending = YES;
        os_unfair_lock_unlock(&strongSelf->_ffmpegBufferLock);
        
        if (shouldSchedule) {
            dispatch_async(dispatch_get_main_queue(), ^{
                VPVideoView *selfRef = weakSelf;
                if (!selfRef) return;
                
                CVPixelBufferRef bufferToRender = NULL;
                os_unfair_lock_lock(&selfRef->_ffmpegBufferLock);
                bufferToRender = selfRef->_latestFFmpegPixelBuffer;
                selfRef->_latestFFmpegPixelBuffer = NULL;
                selfRef->_ffmpegRenderPending = NO;
                os_unfair_lock_unlock(&selfRef->_ffmpegBufferLock);
                
                if (bufferToRender) {
                    if (selfRef.effectRenderer) {
                        [selfRef.effectRenderer renderPixelBuffer:bufferToRender];
                    }
                    CVPixelBufferRelease(bufferToRender);
                }
            });
        }
    };
    
    self.ffmpegTimeTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [weakSelf updatePlaybackTimeDisplay];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.ffmpegTimeTimer forMode:NSRunLoopCommonModes];
    
    [self startFrameMeter];
    [self setChromeAlpha:1 animated:NO];
    [self showControls];
}

- (void)detachPlayer {
    [self removeTimeObserver];
    [self.ffmpegTimeTimer invalidate];
    self.ffmpegTimeTimer = nil;
    self.observedFFmpegPlayer.frameHandler = nil;
    self.observedFFmpegPlayer = nil;
    os_unfair_lock_lock(&_ffmpegBufferLock);
    if (_latestFFmpegPixelBuffer) {
        CVPixelBufferRelease(_latestFFmpegPixelBuffer);
        _latestFFmpegPixelBuffer = NULL;
    }
    _ffmpegRenderPending = NO;
    os_unfair_lock_unlock(&_ffmpegBufferLock);
    [self.frameMeter stop]; self.frameMeter = nil;
    [self.effectRenderer stop];
    self.routePicker.player = nil;
    self.playerLayer.player = nil;
    self.position.enabled = NO; self.playButton.enabled = NO;
    self.position.doubleValue = 0;
    self.timeLabel.stringValue = @"00:00 / --:--";
    self.displayOffset = 0; self.knownDuration = 0;
    self.subtitleLabel.hidden = YES;
    self.playerLayer.hidden = NO;
}

- (void)seek:(NSSlider *)sender {
    double duration = [self effectiveDuration];
    if (duration > 0) {
        double target = sender.doubleValue * duration;
        self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", Clock(target), Clock(duration)];
        if (self.seekHandler) self.seekHandler(target);
        else [self.playerLayer.player seekToTime:CMTimeMakeWithSeconds(target - self.displayOffset, 600)];
    }
    [self showControls];
}
- (void)setVolumeLevel:(float)level muted:(BOOL)muted {
    self.volume.doubleValue = level;
    NSString *symbol = muted || level <= 0 ? @"speaker.slash.fill" : level < 0.34 ? @"speaker.wave.1.fill" : level < 0.67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
    self.muteButton.image = Symbol(symbol, muted ? @"Unmute (M)" : @"Mute (M)");
    self.muteButton.toolTip = muted ? @"Unmute (M)" : @"Mute (M)";
}

- (void)changeVolume:(NSSlider *)sender {
    if (self.volumeHandler) {
        self.volumeHandler(sender.floatValue);
    } else if (self.observedFFmpegPlayer) {
        self.observedFFmpegPlayer.volume = sender.floatValue;
    } else {
        self.playerLayer.player.volume = sender.floatValue;
    }
    [self showControls];
}
@end
