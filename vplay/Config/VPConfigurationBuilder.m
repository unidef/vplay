#import "VPConfigurationBuilder.h"
#import "VPConfigManager.h"
#import "VPWindowController.h"
#import "VPURLHelper.h"
#import "VPProcessingPlan.h"

@interface VPConfigurationBuilder () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) VPConfigManager *config;
@property (nonatomic, weak) VPWindowController *player;
@property (nonatomic, strong) NSTextField *input;
@property (nonatomic, strong) NSPopUpButton *backend;
@property (nonatomic, strong) NSPopUpButton *stageType;
@property (nonatomic, strong) NSTextField *stageValue;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSMutableArray *stages;
@property (nonatomic, strong) NSSlider *volume;
@property (nonatomic, strong) NSButton *loop;
@property (nonatomic, strong) NSButton *shuffle;
@property (nonatomic, strong) NSTextField *feedback;
@end

@implementation VPConfigurationBuilder
- (instancetype)initWithConfig:(VPConfigManager *)config player:(VPWindowController *)player {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 660) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        self.config = config; self.player = player;
        window.title = @"Mac Video Player Configuration Builder";
        window.releasedWhenClosed = NO; window.minSize = NSMakeSize(900, 660);
        NSView *content = window.contentView;
        NSTextField *heading = [NSTextField labelWithString:@"Choose media, build an ordered effect chain, then save or launch."];
        heading.frame = NSMakeRect(20, 618, 860, 24); heading.autoresizingMask = NSViewMinYMargin;
        [content addSubview:heading];
        self.input = [NSTextField textFieldWithString:@""];
        self.input.placeholderString = @"Media file path or URL"; self.input.accessibilityLabel = @"Media file or URL";
        self.input.frame = NSMakeRect(20, 576, 720, 28); self.input.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [content addSubview:self.input];
        [self addButton:@"Browse…" action:@selector(browse:) frame:NSMakeRect(750, 574, 130, 32) top:YES];
        self.backend = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 532, 180, 28) pullsDown:NO];
        [self.backend addItemsWithTitles:@[@"auto", @"native", @"prepared"]];
        self.backend.accessibilityLabel = @"Playback backend";
        self.backend.autoresizingMask = NSViewMinYMargin;
        [content addSubview:self.backend];
        NSTextField *backendHelp = [NSTextField labelWithString:@"Auto: native when possible; FFmpeg preparation for filters / other codecs."];
        backendHelp.frame = NSMakeRect(214, 532, 660, 24); backendHelp.autoresizingMask = NSViewMinYMargin;
        [content addSubview:backendHelp];
        self.stageType = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 486, 150, 28) pullsDown:NO];
        [self.stageType addItemsWithTitles:@[@"video", @"audio", @"effect", @"shader"]];
        self.stageType.accessibilityLabel = @"Effect stage type"; self.stageType.autoresizingMask = NSViewMinYMargin;
        [content addSubview:self.stageType];
        self.stageValue = [NSTextField textFieldWithString:@""];
        self.stageValue.placeholderString = @"FFmpeg graph, native effect (sepia:0.6), or shader path";
        self.stageValue.accessibilityLabel = @"Effect definition";
        self.stageValue.frame = NSMakeRect(180, 486, 540, 28); self.stageValue.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [content addSubview:self.stageValue];
        [self addButton:@"Add Stage" action:@selector(addStage:) frame:NSMakeRect(730, 484, 150, 32) top:YES];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 228, 860, 242)];
        scroll.hasVerticalScroller = YES; scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
        for (NSString *key in @[@"type", @"value"]) {
            NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:key];
            column.title = [key isEqual:@"type"] ? @"Stage type" : @"Definition (double-click to edit)";
            column.width = [key isEqual:@"type"] ? 120 : 720;
            column.editable = [key isEqual:@"value"];
            [self.table addTableColumn:column];
        }
        self.table.dataSource = self; self.table.delegate = self;
        self.table.rowHeight = 28; scroll.documentView = self.table;
        [content addSubview:scroll];
        [self addButton:@"Move Up" action:@selector(moveUp:) frame:NSMakeRect(20, 186, 110, 32) top:NO];
        [self addButton:@"Move Down" action:@selector(moveDown:) frame:NSMakeRect(140, 186, 110, 32) top:NO];
        [self addButton:@"Remove" action:@selector(removeStage:) frame:NSMakeRect(260, 186, 100, 32) top:NO];
        [self addButton:@"Load Shader…" action:@selector(loadShader:) frame:NSMakeRect(370, 186, 150, 32) top:NO];
        [self addButton:@"Write Shader…" action:@selector(writeShader:) frame:NSMakeRect(530, 186, 150, 32) top:NO];
        [self addButton:@"Advanced…" action:@selector(advanced:) frame:NSMakeRect(690, 186, 190, 32) top:NO];
        self.volume = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:nil action:nil];
        self.volume.frame = NSMakeRect(20, 106, 220, 24); self.volume.accessibilityLabel = @"Playback volume";
        self.volume.toolTip = @"Playback volume";
        [content addSubview:self.volume];
        self.loop = [NSButton checkboxWithTitle:@"Loop" target:nil action:nil];
        self.loop.frame = NSMakeRect(260, 104, 100, 28); [content addSubview:self.loop];
        self.shuffle = [NSButton checkboxWithTitle:@"Shuffle playlist" target:nil action:nil];
        self.shuffle.frame = NSMakeRect(20, 72, 150, 24); self.shuffle.toolTip = @"When the media is a folder or playlist, play it in random order";
        self.shuffle.autoresizingMask = NSViewMaxYMargin; [content addSubview:self.shuffle];
        [self addButton:@"Shader Editor…" action:@selector(shaderEditor:) frame:NSMakeRect(180, 70, 150, 28) top:NO];
        [self addButton:@"Post-Processing…" action:@selector(postProcessing:) frame:NSMakeRect(340, 70, 170, 28) top:NO];
        self.feedback = [NSTextField wrappingLabelWithString:@"Video/audio = FFmpeg filters. Native effect/shader stages run after FFmpeg video stages. Effects: sepia:0.6, noir, bloom:1… (see vplay effect-list). The media can be a file, folder, playlist or disc."];
        self.feedback.frame = NSMakeRect(380, 92, 500, 44); [content addSubview:self.feedback];
        [self addButton:@"Load Config…" action:@selector(loadConfig:) frame:NSMakeRect(20, 30, 160, 36) top:NO];
        [self addButton:@"Save Config…" action:@selector(saveConfig:) frame:NSMakeRect(190, 30, 160, 36) top:NO];
        [self addButton:@"Apply" action:@selector(apply:) frame:NSMakeRect(360, 30, 120, 36) top:NO];
        [self addButton:@"Launch Media" action:@selector(launch:) frame:NSMakeRect(490, 30, 210, 36) top:NO];
        [self addButton:@"Stop / Cancel" action:@selector(stop:) frame:NSMakeRect(710, 30, 170, 36) top:NO];
        [self refresh]; [window center];
    }
    return self;
}
- (void)addButton:(NSString *)title action:(SEL)action frame:(NSRect)frame top:(BOOL)top {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame; button.autoresizingMask = top ? NSViewMinYMargin : NSViewMaxYMargin;
    [self.window.contentView addSubview:button];
}
- (void)refresh {
    NSDictionary *dict = [self.config toDictionary];
    self.input.stringValue = dict[@"input"] ?: @"";
    [self.backend selectItemWithTitle:dict[@"playbackBackend"] ?: @"auto"];
    self.stages = [NSMutableArray array];
    // Materialize legacy fields so the displayed chain represents the whole configuration.
    for (NSArray *mapping in @[@[@"vf",@"video"], @[@"af",@"audio"], @[@"effect",@"effect"], @[@"shader",@"shader"]]) {
        NSString *value = dict[mapping[0]];
        if (value.length && ![value isEqual:@"none"]) [self.stages addObject:@{@"type":mapping[1], @"value":value}];
    }
    [self.stages addObjectsFromArray:dict[@"effectChain"] ?: @[]];
    self.volume.doubleValue = self.config.defaultVolume;
    self.loop.state = [dict[@"loop"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.shuffle.state = [dict[@"shuffle"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.table reloadData];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.stages.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row { return self.stages[row][column.identifier]; }
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSMutableDictionary *stage = [self.stages[row] mutableCopy]; stage[column.identifier] = value ?: @""; self.stages[row] = stage;
}
- (void)addStage:(id)sender {
    NSString *value = [self.stageValue.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) { self.feedback.stringValue = @"Enter an effect definition first."; return; }
    [self.stages addObject:@{@"type":self.stageType.titleOfSelectedItem, @"value":value}];
    [self.table reloadData]; self.stageValue.stringValue = @"";
}
- (void)move:(NSInteger)direction {
    NSInteger row = self.table.selectedRow, next = row + direction;
    if (row < 0 || next < 0 || next >= self.stages.count) return;
    [self.stages exchangeObjectAtIndex:row withObjectAtIndex:next]; [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
}
- (void)moveUp:(id)sender { [self move:-1]; }
- (void)moveDown:(id)sender { [self move:1]; }
- (void)removeStage:(id)sender {
    if (self.table.selectedRow >= 0) { [self.stages removeObjectAtIndex:self.table.selectedRow]; [self.table reloadData]; }
}
- (void)browse:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;   // folders, playlists and disc folders are valid media
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) { if (result == NSModalResponseOK) self.input.stringValue = panel.URL.path; }];
}
- (void)loadShader:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) { [self.stages addObject:@{@"type":@"shader", @"value":panel.URL.path}]; [self.table reloadData]; }
    }];
}
- (void)writeShader:(id)sender {
    NSAlert *editor = [NSAlert new]; editor.messageText = @"Define a Core Image color kernel";
    editor.informativeText = @"One __sample argument, vec4 result. Saved source is added as a shader stage.";
    [editor addButtonWithTitle:@"Save…"]; [editor addButtonWithTitle:@"Cancel"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 540, 220)];
    scroll.hasVerticalScroller = YES;
    NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
    text.richText = NO; text.automaticQuoteSubstitutionEnabled = NO;
    text.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    text.string = @"kernel vec4 effect(__sample pixel) {\n    return vec4(pixel.a - pixel.rgb, pixel.a);\n}\n";
    scroll.documentView = text; editor.accessoryView = scroll;
    [editor beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertFirstButtonReturn) return;
        NSSavePanel *panel = [NSSavePanel savePanel]; panel.nameFieldStringValue = @"effect.cikernel";
        [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response != NSModalResponseOK) return;
            NSError *error = nil;
            if (![text.string writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) { self.feedback.stringValue = error.localizedDescription; return; }
            [self.stages addObject:@{@"type":@"shader", @"value":panel.URL.path}]; [self.table reloadData];
        }];
    }];
}
- (BOOL)commit {
    [self.window makeFirstResponder:nil];
    NSMutableDictionary *dict = [[self.config toDictionary] mutableCopy];
    dict[@"input"] = self.input.stringValue;
    dict[@"playbackBackend"] = self.backend.titleOfSelectedItem;
    dict[@"volume"] = @(self.volume.doubleValue); dict[@"loop"] = @(self.loop.state == NSControlStateValueOn);
    dict[@"shuffle"] = @(self.shuffle.state == NSControlStateValueOn);
    dict[@"effectChain"] = [self.stages copy]; dict[@"vf"] = @""; dict[@"af"] = @""; dict[@"effect"] = @"none"; dict[@"shader"] = @"";
    NSError *error = nil;
    VPConfigManager *validator = [VPConfigManager new];
    if (![validator applyDictionary:dict error:&error] || ![VPProcessingPlan resolvedOptions:dict error:&error]) { self.feedback.stringValue = error.localizedDescription; return NO; }
    [self.config applyDictionary:dict error:nil];
    self.feedback.stringValue = @"Configuration applied. Launch Media starts with these settings.";
    return YES;
}
- (void)apply:(id)sender { [self commit]; }
- (void)launch:(id)sender {
    if (![self commit]) return;
    NSURL *url = [VPURLHelper urlFromString:self.input.stringValue];
    if (!self.input.stringValue.length || !url) { self.feedback.stringValue = @"Choose a media file or URL."; return; }
    [self.player showWindow:nil]; [self.player openURLs:@[url] shuffle:self.shuffle.state == NSControlStateValueOn];
}
- (void)stop:(id)sender { [self.player stopPlayback:nil]; self.feedback.stringValue = @"Stopped."; }
- (void)advanced:(id)sender { if ([self commit]) [self.player showConfiguration:nil]; }
- (void)shaderEditor:(id)sender { [self.player showShaderEditor:nil]; }
- (void)postProcessing:(id)sender { [self.player showPostProcessing:nil]; }
- (void)saveConfig:(id)sender {
    if (![self commit]) return;
    NSSavePanel *panel = [NSSavePanel savePanel]; panel.nameFieldStringValue = @"player.json";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        self.feedback.stringValue = [self.config saveToPath:panel.URL.path error:&error] ? @"Saved configuration." : error.localizedDescription;
    }];
}
- (void)loadConfig:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.config loadFromPath:panel.URL.path error:&error]) self.feedback.stringValue = error.localizedDescription;
        else { [self refresh]; self.feedback.stringValue = @"Loaded configuration."; }
    }];
}
@end
