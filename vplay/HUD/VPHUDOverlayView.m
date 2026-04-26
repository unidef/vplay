//
//  VPHUDOverlayView.m
//  vplay
//

// Actions are sent down the responder chain (target nil), so the selectors are not declared in this file.
#pragma clang diagnostic ignored "-Wundeclared-selector"

#import "VPHUDOverlayView.h"

static const CGFloat kRowHeight = 32, kGap = 8, kMargin = 16;

@interface VPHUDOverlayView ()
@property (nonatomic, assign) BOOL isVisible;
@property (nonatomic, strong) NSImageView *icon;
@property (nonatomic, strong) NSTextField *title;
@property (nonatomic, strong) NSTextField *hint;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, strong) NSButton *customizeButton;
@property (nonatomic, strong) NSMutableArray<NSButton *> *buttons;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *toggles;
@property (nonatomic, strong) NSTimer *hideTimer;
@property (nonatomic, strong) NSTrackingArea *tracking;
@property (nonatomic) BOOL pointerInside;
@property (nonatomic) NSUInteger generation;
@end

@implementation VPHUDOverlayView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.allowsTexture = NO; // Menus and dialogs are NOT textured by default
        _buttons = [NSMutableArray array];
        _toggles = [NSMutableDictionary dictionary];
        _hiddenItems = @[];
        [self buildHeader];
        [self buildButtons];
    }
    return self;
}

- (void)setSkin:(NSDictionary *)skin {
    self.allowsTexture = [skin[@"textureMenus"] boolValue];
    [super setSkin:skin];
    // The menu panel's text is always white, whatever the chrome colors are.
    NSColor *text = NSColor.whiteColor, *accent = [VPSkin color:skin[@"accentColor"]];
    self.title.textColor = text; self.hint.textColor = text;
    for (NSButton *button in self.buttons) button.contentTintColor = text;
    self.closeButton.contentTintColor = text; self.customizeButton.contentTintColor = text;
    self.icon.contentTintColor = accent;
}

#pragma mark - Building

- (void)buildHeader {
    _icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage ?: [NSImage imageNamed:NSImageNameApplicationIcon]];
    [self addSubview:_icon];
    _title = [NSTextField labelWithString:@"Mac Video Player"];
    _title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightLight];
    [self addSubview:_title];
    _hint = [NSTextField labelWithString:@"Tab shows or hides this panel"];
    _hint.font = [NSFont systemFontOfSize:11];
    [self addSubview:_hint];

    // One click on × hides the panel; the ⋯ menu chooses which items it shows.
    _closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Hide the menu panel"] target:self action:@selector(closePanel:)];
    _closeButton.bordered = NO; _closeButton.toolTip = @"Hide this panel";
    [self addSubview:_closeButton];
    _customizeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis.circle" accessibilityDescription:@"Choose which items this panel shows"] target:self action:@selector(showCustomizeMenu:)];
    _customizeButton.bordered = NO; _customizeButton.toolTip = @"Choose which items this panel shows";
    [self addSubview:_customizeButton];
}

- (NSButton *)addButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action tip:(NSString *)tip toggle:(NSString *)toggle {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:action];
    button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    button.imagePosition = NSImageLeft;
    button.alignment = NSTextAlignmentLeft;
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:12];
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSForegroundColorAttributeName: NSColor.whiteColor, NSFontAttributeName: button.font}];
    button.toolTip = tip;
    button.identifier = NSStringFromSelector(action);
    button.lineBreakMode = NSLineBreakByTruncatingTail;
    if (toggle) { [button setButtonType:NSButtonTypePushOnPushOff]; self.toggles[toggle] = button; }
    [self addSubview:button];
    [self.buttons addObject:button];
    return button;
}

- (void)buildButtons {
    // Two columns, in reading order. Actions travel the responder chain to the window controller.
    [self addButton:@"Open File…" symbol:@"doc.badge.plus" action:@selector(openDocument:) tip:@"Open a media file (⌘O)" toggle:nil];
    [self addButton:@"Open URL…" symbol:@"link" action:@selector(openLocation:) tip:@"Play a web address or network stream (⌘U)" toggle:nil];
    [self addButton:@"Open Folder…" symbol:@"folder" action:@selector(openFolder:) tip:@"Queue every media file in a folder or open a playlist file" toggle:nil];
    [self addButton:@"Open Disc…" symbol:@"opticaldisc" action:@selector(openDisc:) tip:@"Play a DVD, Blu-ray, VCD or SVCD" toggle:nil];
    [self addButton:@"Open ISO Image…" symbol:@"externaldrive.badge.plus" action:@selector(openDiscImage:) tip:@"Play a DVD, Blu-ray or CD disc image (.iso)" toggle:nil];
    [self addButton:@"Playlist" symbol:@"list.bullet.rectangle" action:@selector(showPlaylist:) tip:@"Show the playlist (⌘L)" toggle:nil];
    [self addButton:@"Shuffle" symbol:@"shuffle" action:@selector(toggleShuffle:) tip:@"Play the playlist in random order (S)" toggle:@"shuffle"];
    [self addButton:@"Tracks & Subtitles" symbol:@"captions.bubble" action:@selector(showTracksMenu:) tip:@"Choose audio, video and subtitle tracks" toggle:nil];
    [self addButton:@"AirPlay" symbol:@"airplayvideo" action:@selector(showAirPlay:) tip:@"Send to an AirPlay device" toggle:nil];
    [self addButton:@"Snapshot" symbol:@"camera" action:@selector(takeSnapshot:) tip:@"Save the current frame as a picture (C)" toggle:nil];
    [self addButton:@"Visualizer" symbol:@"waveform" action:@selector(toggleVisualizer:) tip:@"Show the audio visualizer over video (V)" toggle:@"visualizer"];
    [self addButton:@"FPS Display" symbol:@"speedometer" action:@selector(toggleFPS:) tip:@"Show frames per second (D)" toggle:@"fps"];
    [self addButton:@"Post-Processing" symbol:@"slider.horizontal.3" action:@selector(showPostProcessing:) tip:@"Brightness, contrast, color, sharpness and more" toggle:nil];
    [self addButton:@"Shader Editor" symbol:@"wand.and.stars" action:@selector(showShaderEditor:) tip:@"Write shaders and chain filters with a live preview" toggle:nil];
    [self addButton:@"Audio Filters" symbol:@"waveform.path.ecg" action:@selector(showAudioFilters:) tip:@"Build, demo and apply a chain of audio filters" toggle:nil];
    [self addButton:@"Audio Output" symbol:@"hifispeaker.2" action:@selector(showAudioOutput:) tip:@"Sample rate (upsampling) and speaker layout: mono, 2.0, 4.1, 5.1…" toggle:nil];
    [self addButton:@"Config Builder" symbol:@"gearshape.2" action:@selector(showBuilder:) tip:@"Chain FFmpeg, shader and audio effects (⌘B)" toggle:nil];
    [self addButton:@"Settings" symbol:@"gearshape" action:@selector(showConfiguration:) tip:@"Advanced configuration (⌘,)" toggle:nil];
    [self addButton:@"Controls Bar" symbol:@"dock.rectangle" action:@selector(toggleControlsOverlay:) tip:@"Show or hide the playback controls bar" toggle:@"controls"];
    [self addButton:@"Hide Overlays" symbol:@"eye.slash" action:@selector(toggleOverlays:) tip:@"Hide every overlay for a clean picture (H)" toggle:nil];
    [self addButton:@"Help" symbol:@"questionmark.circle" action:@selector(showHelp:) tip:@"Keyboard shortcuts and tips" toggle:nil];
    [self addButton:@"Replay Intro" symbol:@"sparkles" action:@selector(replayIntro:) tip:@"Play the animated logo again" toggle:nil];
}


#pragma mark - Item visibility

- (void)setHiddenItems:(NSArray<NSString *> *)hidden {
    _hiddenItems = [hidden copy] ?: @[];
    for (NSButton *button in self.buttons) button.hidden = [_hiddenItems containsObject:button.identifier];
    self.needsLayout = YES;
}

- (void)closePanel:(id)sender { [self hideAnimated:YES]; }

- (void)showCustomizeMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Panel items"];
    NSMenuItem *header = [menu addItemWithTitle:@"Show these items in the panel" action:nil keyEquivalent:@""]; header.enabled = NO;
    for (NSButton *button in self.buttons) {
        NSMenuItem *item = [menu addItemWithTitle:button.title action:@selector(toggleItemVisibility:) keyEquivalent:@""];
        item.target = self; item.representedObject = button.identifier;
        item.state = [self.hiddenItems containsObject:button.identifier] ? NSControlStateValueOff : NSControlStateValueOn;
        item.image = button.image;
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *all = [menu addItemWithTitle:@"Show All Items" action:@selector(showAllItems:) keyEquivalent:@""]; all.target = self;
    [self scheduleAutoHide];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}

- (void)toggleItemVisibility:(NSMenuItem *)item {
    NSMutableArray *hidden = [self.hiddenItems mutableCopy];
    if ([hidden containsObject:item.representedObject]) [hidden removeObject:item.representedObject]; else [hidden addObject:item.representedObject];
    [self applyHiddenItems:hidden];
}
- (void)showAllItems:(id)sender { [self applyHiddenItems:@[]]; }
- (void)applyHiddenItems:(NSArray *)hidden {
    self.hiddenItems = hidden;
    if ([self.delegate respondsToSelector:@selector(hudOverlayDidChangeHiddenItems:)]) [self.delegate hudOverlayDidChangeHiddenItems:hidden];
}

#pragma mark - Layout

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    CGFloat top = bounds.size.height;
    self.icon.frame = NSMakeRect(kMargin, top - 62, 46, 46);
    self.title.frame = NSMakeRect(kMargin + 56, top - 44, bounds.size.width - 160, 30);
    self.hint.frame = NSMakeRect(kMargin + 58, top - 60, bounds.size.width - 160, 14);
    self.closeButton.frame = NSMakeRect(bounds.size.width - 14 - 28, top - 14 - 28, 28, 28);
    self.customizeButton.frame = NSMakeRect(bounds.size.width - 14 - 28 - 32, top - 14 - 28, 28, 28);
    CGFloat columnWidth = (bounds.size.width - 2 * kMargin - kGap) / 2;
    CGFloat y = top - 62 - 12;
    NSUInteger slot = 0;
    for (NSButton *button in self.buttons) {
        if (button.hidden) continue;
        NSUInteger column = slot % 2;
        if (column == 0) y -= kRowHeight + (slot == 0 ? 0 : kGap - 2);
        button.frame = NSMakeRect(kMargin + column * (columnWidth + kGap), y, columnWidth, kRowHeight - 2);
        slot++;
    }
}

#pragma mark - Show / hide

- (void)showAnimated:(BOOL)animated {
    self.generation++;
    self.hidden = NO;
    if (animated && !self.isVisible) {
        self.alphaValue = 0.0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.25; self.animator.alphaValue = 1.0; }];
    } else {
        self.alphaValue = 1.0;
    }
    _isVisible = YES;
    [self scheduleAutoHide];
}

- (void)hideAnimated:(BOOL)animated {
    [self.hideTimer invalidate]; self.hideTimer = nil;
    NSUInteger generation = ++self.generation;
    _isVisible = NO;
    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.35;
            self.animator.alphaValue = 0.0;
        } completionHandler:^{ if (generation == self.generation) self.hidden = YES; }];
    } else {
        self.alphaValue = 0.0;
        self.hidden = YES;
    }
}

- (void)toggle { if (self.isVisible) [self hideAnimated:YES]; else [self showAnimated:YES]; }

- (void)scheduleAutoHide {
    [self.hideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.hideTimer = [NSTimer timerWithTimeInterval:6 repeats:NO block:^(NSTimer *timer) {
        VPHUDOverlayView *view = weakSelf;
        if (!view || !view.isVisible) return;
        // Stay put while the pointer is over the panel, a button is held, or a menu is open.
        if (view.pointerInside || NSEvent.pressedMouseButtons) { [view scheduleAutoHide]; return; }
        [view hideAnimated:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.hideTimer forMode:NSRunLoopCommonModes];
}

- (void)noteMouseMovedAtWindowPoint:(NSPoint)point {
    // Menu does not appear or reappear on mouse movement.
    // It is opened intentionally via Tab, the sidebar button, or menu bar.
    if (self.isVisible && self.pointerInside) {
        [self scheduleAutoHide];
    }
}

- (void)setToggle:(NSString *)identifier on:(BOOL)on {
    self.toggles[identifier].state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - Mouse handling

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event { self.pointerInside = YES; [self scheduleAutoHide]; }
- (void)mouseExited:(NSEvent *)event { self.pointerInside = NO; [self scheduleAutoHide]; }
- (void)mouseMoved:(NSEvent *)event { [self scheduleAutoHide]; }
- (void)mouseDown:(NSEvent *)event { /* consume clicks inside the panel so they never reach the video */ }

- (NSView *)hitTest:(NSPoint)point {
    if (!self.isVisible) return nil;
    return [super hitTest:point];
}


@end
