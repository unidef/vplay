#import "VPPlaylistWindowController.h"
#import "VPURLHelper.h"
#import "VPDiscSupport.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSPasteboardType const VPPlaylistRowType = @"com.jonathanmaharaj.vplay.playlist-row";

@interface VPPlaylistTableView : NSTableView
@property (nonatomic, weak) id deleteTarget;
@property (nonatomic, assign) SEL deleteAction;
@end

@implementation VPPlaylistTableView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 51 || event.keyCode == 117) { // Delete or Forward Delete
        if (self.deleteTarget && [self.deleteTarget respondsToSelector:self.deleteAction]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.deleteTarget performSelector:self.deleteAction withObject:self];
            #pragma clang diagnostic pop
            return;
        }
    }
    if (event.keyCode == 36 || event.keyCode == 76) { // Return or Enter
        if (self.target && [self.target respondsToSelector:self.doubleAction]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.target performSelector:self.doubleAction withObject:self];
            #pragma clang diagnostic pop
            return;
        }
    }
    [super keyDown:event];
}
@end

@interface VPPlaylistWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) VPPlaylist *playlist;
@property (nonatomic, strong) VPPlaylistTableView *table;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSButton *shuffleBox;
@property (nonatomic, strong) NSPopUpButton *repeatMenu;
@property (nonatomic, strong) NSTextField *summary;
@property (nonatomic, strong) NSButton *removeButton;
@property (nonatomic, strong) NSButton *moveUpButton;
@property (nonatomic, strong) NSButton *moveDownButton;
@property (nonatomic, strong) NSButton *playButton;
@end

@implementation VPPlaylistWindowController

- (instancetype)initWithPlaylist:(VPPlaylist *)playlist {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 520)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Mac Video Player — Playlist";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(560, 380);
    window.frameAutosaveName = @"VPPlaylistWindow";
    if ((self = [super initWithWindow:window])) {
        _playlist = playlist;
        [self buildUI];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playlistChanged:) name:VPPlaylistDidChangeNotification object:playlist];
        [window center];
        [self playlistChanged:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSButton *)createButton:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.controlSize = NSControlSizeRegular;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    content.autoresizesSubviews = YES;

    // Top Summary label
    self.summary = [NSTextField labelWithString:@""];
    self.summary.frame = NSMakeRect(16, content.bounds.size.height - 30, content.bounds.size.width - 32, 20);
    self.summary.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.summary.textColor = NSColor.secondaryLabelColor;
    self.summary.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [content addSubview:self.summary];

    // Top Toolbar Stack (Add, Load, Save, Clear)
    NSButton *addF = [self createButton:@"Add Files…" action:@selector(addFiles:)];
    NSButton *addFold = [self createButton:@"Add Folder…" action:@selector(addFolder:)];
    NSButton *addD = [self createButton:@"Add Disc / ISO…" action:@selector(addDisc:)];
    NSButton *open = [self createButton:@"Load…" action:@selector(openPlaylistFile:)];
    NSButton *save = [self createButton:@"Save…" action:@selector(savePlaylistFile:)];
    NSButton *clear = [self createButton:@"Clear" action:@selector(clearAll:)];

    NSStackView *topBar = [NSStackView stackViewWithViews:@[addF, addFold, addD, open, save, [NSView new], clear]];
    topBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topBar.distribution = NSStackViewDistributionFill;
    topBar.alignment = NSLayoutAttributeCenterY;
    topBar.spacing = 8;
    topBar.frame = NSMakeRect(16, content.bounds.size.height - 68, content.bounds.size.width - 32, 32);
    topBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:topBar];

    // Middle Table View in Scroll View
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 60, content.bounds.size.width - 32, content.bounds.size.height - 136)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.table = [[VPPlaylistTableView alloc] initWithFrame:self.scrollView.bounds];
    self.table.deleteTarget = self;
    self.table.deleteAction = @selector(removeSelected:);
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.allowsMultipleSelection = YES;
    self.table.rowHeight = 24;
    self.table.doubleAction = @selector(playClicked:);
    self.table.target = self;
    self.table.usesAlternatingRowBackgroundColors = YES;
    [self.table registerForDraggedTypes:@[VPPlaylistRowType, NSPasteboardTypeFileURL]];

    NSTableColumn *colNow = [[NSTableColumn alloc] initWithIdentifier:@"now"];
    colNow.title = @"";
    colNow.width = 24;
    colNow.minWidth = colNow.maxWidth = 24;
    [self.table addTableColumn:colNow];

    NSTableColumn *colIdx = [[NSTableColumn alloc] initWithIdentifier:@"index"];
    colIdx.title = @"#";
    colIdx.width = 34;
    colIdx.minWidth = 28;
    colIdx.maxWidth = 48;
    [self.table addTableColumn:colIdx];

    NSTableColumn *colTitle = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    colTitle.title = @"Title";
    colTitle.width = 360;
    colTitle.minWidth = 160;
    [self.table addTableColumn:colTitle];

    NSTableColumn *colWhere = [[NSTableColumn alloc] initWithIdentifier:@"where"];
    colWhere.title = @"Location";
    colWhere.width = 220;
    colWhere.minWidth = 120;
    [self.table addTableColumn:colWhere];

    self.scrollView.documentView = self.table;
    [content addSubview:self.scrollView];

    // Bottom Controls Bar
    self.removeButton = [self createButton:@"Remove" action:@selector(removeSelected:)];
    self.moveUpButton = [self createButton:@"▲" action:@selector(moveUpSelected:)];
    self.moveUpButton.toolTip = @"Move Selected Up";
    self.moveDownButton = [self createButton:@"▼" action:@selector(moveDownSelected:)];
    self.moveDownButton.toolTip = @"Move Selected Down";

    NSStackView *leftGroup = [NSStackView stackViewWithViews:@[self.removeButton, self.moveUpButton, self.moveDownButton]];
    leftGroup.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    leftGroup.spacing = 6;
    leftGroup.alignment = NSLayoutAttributeCenterY;

    self.shuffleBox = [NSButton checkboxWithTitle:@"Shuffle" target:self action:@selector(shuffleChanged:)];
    self.shuffleBox.font = [NSFont systemFontOfSize:12];

    NSTextField *repeatLabel = [NSTextField labelWithString:@"Repeat:"];
    repeatLabel.font = [NSFont systemFontOfSize:12];

    self.repeatMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 78, 24) pullsDown:NO];
    [self.repeatMenu addItemsWithTitles:@[@"Off", @"All", @"One"]];
    self.repeatMenu.target = self;
    self.repeatMenu.action = @selector(repeatChanged:);
    self.repeatMenu.controlSize = NSControlSizeRegular;
    self.repeatMenu.font = [NSFont systemFontOfSize:12];

    NSStackView *centerGroup = [NSStackView stackViewWithViews:@[self.shuffleBox, repeatLabel, self.repeatMenu]];
    centerGroup.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    centerGroup.spacing = 8;
    centerGroup.alignment = NSLayoutAttributeCenterY;

    self.playButton = [self createButton:@"Play" action:@selector(playClicked:)];
    self.playButton.keyEquivalent = @"\r";
    self.playButton.bezelStyle = NSBezelStyleRounded;
    self.playButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];

    NSView *spacer1 = [NSView new];
    [spacer1 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSView *spacer2 = [NSView new];
    [spacer2 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[leftGroup, spacer1, centerGroup, spacer2, self.playButton]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomBar.distribution = NSStackViewDistributionFill;
    bottomBar.alignment = NSLayoutAttributeCenterY;
    bottomBar.frame = NSMakeRect(16, 12, content.bounds.size.width - 32, 38);
    bottomBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:bottomBar];
}

#pragma mark - Model sync

- (void)playlistChanged:(NSNotification *)note {
    [self.table reloadData];
    self.shuffleBox.state = self.playlist.shuffle ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.playlist.repeatMode >= 0 && self.playlist.repeatMode < self.repeatMenu.numberOfItems) {
        [self.repeatMenu selectItemAtIndex:self.playlist.repeatMode];
    }
    NSUInteger count = self.playlist.items.count;
    if (count == 0) {
        self.summary.stringValue = @"Playlist is empty. Add files, folder, disc / ISO, or drag items into this window.";
    } else {
        NSString *countStr = (count == 1) ? @"1 item" : [NSString stringWithFormat:@"%lu items", (unsigned long)count];
        self.summary.stringValue = self.playlist.shuffle ? [countStr stringByAppendingString:@" · Shuffled"] : countStr;
    }
    BOOL hasSelection = self.table.selectedRowIndexes.count > 0;
    self.removeButton.enabled = hasSelection;
    self.moveUpButton.enabled = hasSelection && self.table.selectedRowIndexes.firstIndex > 0;
    self.moveDownButton.enabled = hasSelection && self.table.selectedRowIndexes.lastIndex < count - 1;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSUInteger count = self.playlist.items.count;
    BOOL hasSelection = self.table.selectedRowIndexes.count > 0;
    self.removeButton.enabled = hasSelection;
    self.moveUpButton.enabled = hasSelection && self.table.selectedRowIndexes.firstIndex > 0;
    self.moveDownButton.enabled = hasSelection && self.table.selectedRowIndexes.lastIndex < count - 1;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.playlist.items.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.playlist.items.count) return nil;
    VPPlaylistItem *item = self.playlist.items[row];
    NSString *identifier = column.identifier;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 24)];
        cell.identifier = identifier;
        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.frame = cell.bounds;
        textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField = textField;
        [cell addSubview:textField];
    }

    if ([identifier isEqual:@"now"]) {
        BOOL isCurrent = (row == self.playlist.currentIndex);
        cell.textField.stringValue = isCurrent ? @"▶" : @"";
        cell.textField.textColor = NSColor.controlAccentColor;
        cell.textField.alignment = NSTextAlignmentCenter;
        cell.textField.font = [NSFont boldSystemFontOfSize:12];
    } else if ([identifier isEqual:@"index"]) {
        cell.textField.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
        cell.textField.textColor = NSColor.secondaryLabelColor;
        cell.textField.alignment = NSTextAlignmentRight;
        cell.textField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    } else if ([identifier isEqual:@"title"]) {
        cell.textField.stringValue = item.title ?: @"";
        cell.textField.textColor = (row == self.playlist.currentIndex) ? NSColor.controlAccentColor : NSColor.labelColor;
        cell.textField.font = (row == self.playlist.currentIndex) ? [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        cell.textField.alignment = NSTextAlignmentLeft;
    } else if ([identifier isEqual:@"where"]) {
        NSString *where = item.url.isFileURL ? item.url.URLByDeletingLastPathComponent.path : (item.url.host ?: item.url.absoluteString);
        cell.textField.stringValue = where ?: @"";
        cell.textField.textColor = NSColor.secondaryLabelColor;
        cell.textField.font = [NSFont systemFontOfSize:11];
        cell.textField.alignment = NSTextAlignmentLeft;
    }
    return cell;
}

#pragma mark - Drag and drop

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:@(row).stringValue forType:VPPlaylistRowType];
    return item;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    return [info.draggingPasteboard.types containsObject:VPPlaylistRowType] ? NSDragOperationMove : NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
    NSPasteboard *board = info.draggingPasteboard;
    if ([board.types containsObject:VPPlaylistRowType]) {
        NSInteger from = [[board.pasteboardItems.firstObject stringForType:VPPlaylistRowType] integerValue];
        [self.playlist moveItemFromIndex:from toIndex:from < row ? row - 1 : row];
        return YES;
    }
    NSArray<NSURL *> *urls = [board readObjectsForClasses:@[NSURL.class] options:nil];
    return urls.count && [self.playlist addInputs:urls] > 0;
}

#pragma mark - Actions

- (void)playClicked:(id)sender {
    NSInteger row = self.table.clickedRow >= 0 ? self.table.clickedRow : self.table.selectedRow;
    if (row < 0 && self.playlist.items.count) row = MAX(0, self.playlist.currentIndex);
    if (row >= 0 && self.playHandler) self.playHandler(row);
}

- (void)addFiles:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.title = @"Add Files to Playlist";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [self.playlist addInputs:panel.URLs];
    }];
}

- (void)addFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.title = @"Add Folder to Playlist";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [self.playlist addInputs:panel.URLs];
    }];
}

- (void)addDisc:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes"];
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"iso"],
        [UTType typeWithFilenameExtension:@"img"],
        [UTType typeWithFilenameExtension:@"dmg"],
        [UTType typeWithFilenameExtension:@"toast"],
        [UTType typeWithFilenameExtension:@"cdr"]
    ];
    panel.title = @"Add Disc or Disc Image (.iso)";
    panel.message = @"Choose a DVD, Blu-ray, or disc image (.iso).";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [self.playlist addInputs:@[panel.URL]];
        }
    }];
}

- (void)removeSelected:(id)sender {
    NSIndexSet *selected = self.table.selectedRowIndexes;
    if (selected.count) {
        [self.playlist removeItemsAtIndexes:selected];
    }
}

- (void)moveUpSelected:(id)sender {
    NSIndexSet *selected = self.table.selectedRowIndexes;
    if (!selected.count || selected.firstIndex == 0) return;
    NSMutableIndexSet *newSelection = [NSMutableIndexSet indexSet];
    [selected enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [self.playlist moveItemFromIndex:idx toIndex:idx - 1];
        [newSelection addIndex:idx - 1];
    }];
    [self.table selectRowIndexes:newSelection byExtendingSelection:NO];
}

- (void)moveDownSelected:(id)sender {
    NSIndexSet *selected = self.table.selectedRowIndexes;
    if (!selected.count || selected.lastIndex >= (NSUInteger)self.playlist.items.count - 1) return;
    NSMutableIndexSet *newSelection = [NSMutableIndexSet indexSet];
    [selected enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
        [self.playlist moveItemFromIndex:idx toIndex:idx + 1];
        [newSelection addIndex:idx + 1];
    }];
    [self.table selectRowIndexes:newSelection byExtendingSelection:NO];
}

- (void)clearAll:(id)sender {
    [self.playlist clear];
}

- (void)shuffleChanged:(NSButton *)sender {
    self.playlist.shuffle = sender.state == NSControlStateValueOn;
}

- (void)repeatChanged:(NSPopUpButton *)sender {
    self.playlist.repeatMode = (VPRepeatMode)sender.indexOfSelectedItem;
}

- (void)openPlaylistFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"m3u"], [UTType typeWithFilenameExtension:@"m3u8"], [UTType typeWithFilenameExtension:@"pls"]];
    panel.title = @"Load Playlist File";
    panel.message = @"Choose an .m3u, .m3u8, or .pls playlist to load.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if (![self.playlist loadPlaylistFromURL:panel.URL clearExisting:YES error:&error]) {
            if (error) [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

- (void)savePlaylistFile:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"playlist.m3u";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"m3u"]];
    panel.title = @"Save Playlist";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if (![self.playlist saveToURL:panel.URL error:&error]) {
            [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

@end
