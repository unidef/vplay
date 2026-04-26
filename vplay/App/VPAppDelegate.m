//
//  VPAppDelegate.m
//  vplay
//

// Actions are sent down the responder chain (target nil), so the selectors are not declared in this file.
#pragma clang diagnostic ignored "-Wundeclared-selector"

#import "VPAppDelegate.h"
#import "VPWindowController.h"
#import "VPVideoView.h"
#import "VPConfigManager.h"
#import "VPURLHelper.h"
#import "VPMediaProbe.h"
#import "VPPlaylist.h"
#import "VPEffectPipeline.h"
#import "VPLicenseWindowController.h"

@interface VPAppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) VPWindowController *windowController;
@property (nonatomic, strong) VPConfigManager *configManager;
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingURLs;
@property (nonatomic, strong) VPLicenseWindowController *licenseWindowController;   // Finder opens that arrive before the window exists
@end

@implementation VPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.configManager = [[VPConfigManager alloc] init];
    if (self.startupOptions) [self.configManager applyDictionary:self.startupOptions error:nil];

    // The futuristic vplay icon doubles as the Dock icon, including when launched from a terminal.
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (icon) NSApp.applicationIconImage = icon;

    [self buildMainMenu];
    self.windowController = [[VPWindowController alloc] initWithConfigManager:self.configManager];
    [self.windowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSMutableArray<NSString *> *inputs = [NSMutableArray arrayWithArray:self.startupInputs ?: @[]];
    if (!inputs.count && self.startupInput.length) [inputs addObject:self.startupInput];
    if (!inputs.count && [self.configManager.playbackOptions[@"playlist"] isKindOfClass:NSArray.class]) [inputs addObjectsFromArray:self.configManager.playbackOptions[@"playlist"]];
    // macOS also reports command-line paths as "open file" events; keep each item once.
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithArray:[VPPlaylist URLsFromArguments:inputs]];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSURL *url in urls) [seen addObject:url.standardizedURL.absoluteString];
    for (NSURL *url in self.pendingURLs ?: @[]) if (![seen containsObject:url.standardizedURL.absoluteString]) [urls addObject:url];
    self.pendingURLs = nil;

    if (self.showBuilderOnLaunch) {
        [self.windowController showBuilder:nil];
        if (urls.count) [self.windowController openURLs:urls shuffle:self.startupShuffle];
    } else if (urls.count) {
        [self.windowController openURLs:urls shuffle:self.startupShuffle || [self.configManager.playbackOptions[@"shuffle"] boolValue]];
    } else {
        // Procedural, code-based animated logo lasting up to 7 seconds on loading of the program
        [self.windowController.videoView playIntroWithCompletion:nil];
    }
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    if (self.windowController) [self.windowController openURLs:urls shuffle:self.windowController.playlist.shuffle];
    else { if (!self.pendingURLs) self.pendingURLs = [NSMutableArray array]; [self.pendingURLs addObjectsFromArray:urls]; }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    [self application:sender openURLs:@[[NSURL fileURLWithPath:filename]]];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.windowController stopPlayback:nil];
    [self.windowController stopFFmpeg:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

#pragma mark - Menu Bar

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers to:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = modifiers;
    return item;   // target stays nil: the responder chain finds the window controller
}

- (NSMenu *)addSubmenu:(NSString *)title to:(NSMenu *)bar {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = menu;
    [bar addItem:item];
    return menu;
}

- (void)buildMainMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    NSEventModifierFlags cmd = NSEventModifierFlagCommand, opt = NSEventModifierFlagOption, shift = NSEventModifierFlagShift, ctrl = NSEventModifierFlagControl;
    NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey], *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];

    // vplay
    NSMenu *app = [self addSubmenu:@"Mac Video Player" to:bar];
    [app addItemWithTitle:@"About Mac Video Player" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [self addItem:@"License & Open Source Acknowledgements…" action:@selector(showLicenseWindow:) key:@"" modifiers:0 to:app];
    [app addItem:NSMenuItem.separatorItem];
    [self addItem:@"Play Animated Logo" action:@selector(replayIntro:) key:@"" modifiers:0 to:app];
    [self addItem:@"Settings…" action:@selector(showConfiguration:) key:@"," modifiers:cmd to:app];
    [self addItem:@"Configuration Builder…" action:@selector(showBuilder:) key:@"b" modifiers:cmd to:app];
    [app addItem:NSMenuItem.separatorItem];
    [self addItem:@"Hide Mac Video Player" action:@selector(hide:) key:@"h" modifiers:cmd to:app];
    [self addItem:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:cmd | opt to:app];
    [app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    [self addItem:@"Quit Mac Video Player" action:@selector(terminate:) key:@"q" modifiers:cmd to:app];

    // File
    NSMenu *file = [self addSubmenu:@"File" to:bar];
    [self addItem:@"Open File…" action:@selector(openDocument:) key:@"o" modifiers:cmd to:file];
    [self addItem:@"Open URL…" action:@selector(openLocation:) key:@"u" modifiers:cmd to:file];
    [self addItem:@"Open Folder or Playlist…" action:@selector(openFolder:) key:@"o" modifiers:cmd | shift to:file];
    [self addItem:@"Open Disc (DVD, Blu-ray, VCD, SVCD)…" action:@selector(openDisc:) key:@"o" modifiers:cmd | opt to:file];
    [self addItem:@"Open Disc Image (.iso)…" action:@selector(openDiscImage:) key:@"i" modifiers:cmd | opt to:file];
    [file addItem:NSMenuItem.separatorItem];
    [self addItem:@"Show Playlist" action:@selector(showPlaylist:) key:@"l" modifiers:cmd to:file];
    [file addItem:NSMenuItem.separatorItem];
    [self addItem:@"Close Window" action:@selector(performClose:) key:@"w" modifiers:cmd to:file];

    // Edit
    NSMenu *edit = [self addSubmenu:@"Edit" to:bar];
    [self addItem:@"Undo" action:@selector(undo:) key:@"z" modifiers:cmd to:edit];
    [self addItem:@"Redo" action:@selector(redo:) key:@"z" modifiers:cmd | shift to:edit];
    [edit addItem:NSMenuItem.separatorItem];
    [self addItem:@"Cut" action:@selector(cut:) key:@"x" modifiers:cmd to:edit];
    [self addItem:@"Copy" action:@selector(copy:) key:@"c" modifiers:cmd to:edit];
    [self addItem:@"Paste" action:@selector(paste:) key:@"v" modifiers:cmd to:edit];
    [self addItem:@"Select All" action:@selector(selectAll:) key:@"a" modifiers:cmd to:edit];

    // Playback (Space, Tab, arrows and letters are handled by the window so typing in fields still works)
    NSMenu *playback = [self addSubmenu:@"Playback" to:bar];
    [self addItem:@"Play" action:@selector(togglePlayPause:) key:@"" modifiers:0 to:playback].toolTip = @"Space";
    [self addItem:@"Stop" action:@selector(stopPlayback:) key:@"." modifiers:cmd to:playback];
    [playback addItem:NSMenuItem.separatorItem];
    [self addItem:@"Next in Playlist" action:@selector(playNext:) key:right modifiers:cmd | opt to:playback];
    [self addItem:@"Previous in Playlist" action:@selector(playPrevious:) key:left modifiers:cmd | opt to:playback];
    [self addItem:@"Skip Forward 5 Seconds" action:@selector(seekForward:) key:right modifiers:ctrl | opt to:playback];
    [self addItem:@"Skip Back 5 Seconds" action:@selector(seekBackward:) key:left modifiers:ctrl | opt to:playback];
    [playback addItem:NSMenuItem.separatorItem];
    [self addItem:@"Shuffle" action:@selector(toggleShuffle:) key:@"s" modifiers:cmd | opt to:playback];
    NSMenu *repeat = [self addSubmenu:@"Repeat" to:playback];
    [[self addItem:@"Off" action:@selector(setRepeatMode:) key:@"" modifiers:0 to:repeat] setTag:VPRepeatOff];
    [[self addItem:@"Whole Playlist" action:@selector(setRepeatMode:) key:@"" modifiers:0 to:repeat] setTag:VPRepeatAll];
    [[self addItem:@"Current Item" action:@selector(setRepeatMode:) key:@"" modifiers:0 to:repeat] setTag:VPRepeatOne];
    NSMenu *speed = [self addSubmenu:@"Speed" to:playback];
    for (NSNumber *percent in @[@50, @75, @100, @125, @150, @200]) {
        NSMenuItem *item = [self addItem:[NSString stringWithFormat:@"%.2g×", percent.doubleValue / 100] action:@selector(setPlaybackSpeed:) key:@"" modifiers:0 to:speed];
        item.tag = percent.integerValue;
    }
    [self addItem:@"Mute" action:@selector(toggleMute:) key:@"" modifiers:0 to:playback];

    // Audio
    NSMenu *audio = [self addSubmenu:@"Audio" to:bar];
    NSMenu *audioTracks = [self addSubmenu:@"Audio Track" to:audio]; audioTracks.delegate = self;
    [audio addItem:NSMenuItem.separatorItem];
    [self addItem:@"Visualizer over Video" action:@selector(toggleVisualizer:) key:@"v" modifiers:cmd | opt to:audio];
    [self addItem:@"Next Visualizer Style" action:@selector(cycleVisualizerStyle:) key:@"" modifiers:0 to:audio];
    [audio addItem:NSMenuItem.separatorItem];
    [self addItem:@"Audio Filters…" action:@selector(showAudioFilters:) key:@"a" modifiers:cmd | opt to:audio];
    [self addItem:@"Audio Output & Devices…" action:@selector(showAudioOutput:) key:@"o" modifiers:cmd | ctrl to:audio];

    // Video
    NSMenu *video = [self addSubmenu:@"Video" to:bar];
    NSMenu *videoTracks = [self addSubmenu:@"Video Track" to:video]; videoTracks.delegate = self;
    [video addItem:NSMenuItem.separatorItem];

    // Aspect Ratio
    NSMenu *aspectMenu = [self addSubmenu:@"Aspect Ratio" to:video];
    NSArray<NSArray *> *aspectRatios = @[
        @[@"Auto (Original)", @(VPAspectRatioAuto)],
        @[@"16:9 (Widescreen)", @(VPAspectRatio16_9)],
        @[@"16:10 (Display)", @(VPAspectRatio16_10)],
        @[@"4:3 (Classic TV)", @(VPAspectRatio4_3)],
        @[@"21:9 / 2.39:1 (Cinematic)", @(VPAspectRatio21_9)],
        @[@"1:1 (Square)", @(VPAspectRatio1_1)],
        @[@"Stretch to Window", @(VPAspectRatioStretch)],
        @[@"Zoom to Fill", @(VPAspectRatioCropFill)]
    ];
    for (NSArray *ar in aspectRatios) {
        NSMenuItem *item = [self addItem:ar[0] action:@selector(selectAspectRatio:) key:@"" modifiers:0 to:aspectMenu];
        item.tag = [ar[1] integerValue];
    }
    [video addItem:NSMenuItem.separatorItem];
    [self addItem:@"Show FPS" action:@selector(toggleFPS:) key:@"d" modifiers:cmd | opt to:video];
    [self addItem:@"Media Information" action:@selector(showMediaInfo:) key:@"i" modifiers:cmd to:video];
    [video addItem:NSMenuItem.separatorItem];

    // Video Quality Presets
    NSMenu *qualityMenu = [self addSubmenu:@"Video Quality Presets" to:video];
    for (NSString *presetName in [VPEffectPipeline videoQualityPresetNames]) {
        [self addItem:presetName action:@selector(selectVideoQualityPreset:) key:@"" modifiers:0 to:qualityMenu];
    }

    // Post-Processing Level
    NSMenu *levelMenu = [self addSubmenu:@"Post-Processing Level" to:video];
    NSArray<NSArray *> *levels = @[
        @[@"Off (0%)", @0],
        @[@"Low (25%)", @25],
        @[@"Medium (50%)", @50],
        @[@"High (75%)", @75],
        @[@"Maximum (100%)", @100]
    ];
    for (NSArray *lvl in levels) {
        NSMenuItem *item = [self addItem:lvl[0] action:@selector(selectPostProcessingLevel:) key:@"" modifiers:0 to:levelMenu];
        item.tag = [lvl[1] integerValue];
    }

    // Deinterlace & Telecine
    NSMenu *interlaceMenu = [self addSubmenu:@"Deinterlace & Telecine" to:video];
    [[self addItem:@"Off (Progressive)" action:@selector(setDeinterlaceMode:) key:@"" modifiers:0 to:interlaceMenu] setTag:0];
    [[self addItem:@"Deinterlace Video (bwdif)" action:@selector(setDeinterlaceMode:) key:@"d" modifiers:cmd | opt | shift to:interlaceMenu] setTag:1];
    [[self addItem:@"Reverse Telecine (IVTC 3:2 Pulldown)" action:@selector(setDeinterlaceMode:) key:@"t" modifiers:cmd | opt | shift to:interlaceMenu] setTag:2];
    [interlaceMenu addItem:NSMenuItem.separatorItem];
    NSMenu *fieldOrderMenu = [self addSubmenu:@"Field Order" to:interlaceMenu];
    for (NSArray *fo in @[@[@"Auto Detect", @"auto"], @[@"Top Field First (TFF)", @"tff"], @[@"Bottom Field First (BFF)", @"bff"]]) {
        NSMenuItem *item = [self addItem:fo[0] action:@selector(setDeinterlaceFieldOrder:) key:@"" modifiers:0 to:fieldOrderMenu];
        item.representedObject = fo[1];
    }

    [self addItem:@"Deinterlace" action:@selector(toggleDeinterlace:) key:@"" modifiers:0 to:video];
    [self addItem:@"Reverse Telecine (IVTC)" action:@selector(toggleInverseTelecine:) key:@"" modifiers:0 to:video];
    [video addItem:NSMenuItem.separatorItem];
    [self addItem:@"Post-Processing…" action:@selector(showPostProcessing:) key:@"p" modifiers:cmd | opt to:video];
    [self addItem:@"Shader & Filter Editor…" action:@selector(showShaderEditor:) key:@"e" modifiers:cmd | opt to:video];
    [video addItem:NSMenuItem.separatorItem];
    [self addItem:@"AirPlay…" action:@selector(showAirPlay:) key:@"" modifiers:0 to:video];
    [self addItem:@"Enter Full Screen" action:@selector(toggleFullScreen:) key:@"f" modifiers:cmd | ctrl to:video];

    // Subtitles
    NSMenu *subtitles = [self addSubmenu:@"Subtitles" to:bar]; subtitles.delegate = self;

    // Window
    NSMenu *window = [self addSubmenu:@"Window" to:bar];
    [self addItem:@"Minimize" action:@selector(performMiniaturize:) key:@"m" modifiers:cmd to:window];
    [window addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [window addItem:NSMenuItem.separatorItem];
    [self addItem:@"Show Menu Panel" action:@selector(toggleHUD:) key:@"" modifiers:0 to:window].toolTip = @"Tab";
    [window addItem:NSMenuItem.separatorItem];
    [window addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    [NSApp setWindowsMenu:window];

    // Help
    NSMenu *help = [self addSubmenu:@"Help" to:bar];
    [self addItem:@"Play Animated Logo" action:@selector(replayIntro:) key:@"" modifiers:0 to:help];
    [self addItem:@"Mac Video Player Shortcuts" action:@selector(showHelp:) key:@"?" modifiers:cmd to:help];
    [self addItem:@"License & Open Source Notice…" action:@selector(showLicenseWindow:) key:@"" modifiers:0 to:help];
    [NSApp setHelpMenu:help];

    [NSApp setMainMenu:bar];
}

#pragma mark - NSMenuDelegate (dynamic track menus)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSDictionary *kinds = @{@"Audio Track":@(VPTrackKindAudio), @"Video Track":@(VPTrackKindVideo), @"Subtitles":@(VPTrackKindSubtitle)};
    NSNumber *kind = kinds[menu.title];
    if (kind) [self.windowController populateTracksMenu:menu kind:kind.integerValue];
}


#pragma mark - Licensing & About

- (IBAction)showLicenseWindow:(id)sender {
    if (!self.licenseWindowController) {
        self.licenseWindowController = [[VPLicenseWindowController alloc] init];
    }
    [self.licenseWindowController showWindow:sender];
    [self.licenseWindowController.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)orderFrontStandardAboutPanel:(id)sender {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[NSAboutPanelOptionApplicationName] = @"Mac Video Player";
    options[NSAboutPanelOptionApplicationVersion] = @"1.0";
    options[NSAboutPanelOptionVersion] = @"vplay";
    
    NSString *creditsPath = [NSBundle.mainBundle pathForResource:@"Credits" ofType:@"rtf"];
    if (creditsPath) {
        NSURL *creditsURL = [NSURL fileURLWithPath:creditsPath];
        NSAttributedString *creditsString = [[NSAttributedString alloc] initWithURL:creditsURL options:@{NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType} documentAttributes:nil error:nil];
        if (creditsString) {
            options[NSAboutPanelOptionCredits] = creditsString;
        }
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

@end
