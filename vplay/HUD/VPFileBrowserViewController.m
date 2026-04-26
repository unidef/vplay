//
//  VPFileBrowserViewController.m
//  vplay
//

#import "VPFileBrowserViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "VPURLHelper.h"
#import "VPDiscSupport.h"
#import "VPPlaylist.h"

// ---------------------------------------------------------------------------------------------
// VPFileBrowserEntry
// ---------------------------------------------------------------------------------------------

@interface VPFileBrowserEntry : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isParent;
@property (nonatomic, assign) BOOL isDirectory;
@property (nonatomic, assign) BOOL isMedia;
@property (nonatomic, assign) BOOL isAudio;
@property (nonatomic, assign) BOOL isDisc;
@property (nonatomic, copy, nullable) NSString *sizeString;
@property (nonatomic, assign) unsigned long long sizeBytes;
@property (nonatomic, strong, nullable) NSDate *dateModified;
@property (nonatomic, copy, nullable) NSString *dateString;
@end

@implementation VPFileBrowserEntry
@end

// ---------------------------------------------------------------------------------------------
// VPFileBrowserTableView
// ---------------------------------------------------------------------------------------------

@interface VPFileBrowserTableView : NSTableView
@end

@implementation VPFileBrowserTableView

- (void)keyDown:(NSEvent *)event {
    unsigned short code = event.keyCode;
    // Return (36) / Enter (76) or Right Arrow (124)
    if (code == 36 || code == 76 || code == 124) {
        if (self.target && [self.target respondsToSelector:self.doubleAction]) {
            [self sendAction:self.doubleAction to:self.target];
            return;
        }
    }
    // Delete (51) or Left Arrow (123)
    if (code == 51 || code == 123) {
        if (self.target && [self.target respondsToSelector:@selector(goUp:)]) {
            [self sendAction:@selector(goUp:) to:self.target];
            return;
        }
    }
    [super keyDown:event];
}

@end

// ---------------------------------------------------------------------------------------------
// VPFileBrowserViewController
// ---------------------------------------------------------------------------------------------

@interface VPFileBrowserViewController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSURL *currentDirectory;
@property (nonatomic, strong) NSMutableArray<VPFileBrowserEntry *> *allEntries;
@property (nonatomic, strong) NSMutableArray<VPFileBrowserEntry *> *filteredEntries;

@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) VPFileBrowserTableView *tableView;
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, strong) NSButton *upButton;
@property (nonatomic, strong) NSPopUpButton *placesPopup;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *filterPopup;
@property (nonatomic, strong) NSPopUpButton *sortPopup;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *queueButton;
@property (nonatomic, strong) NSButton *playFolderButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;

@property (nonatomic, assign) BOOL mediaOnlyFilter;
@property (nonatomic, copy) NSString *sortKey;
@property (nonatomic, assign) BOOL sortAscending;
@end

@implementation VPFileBrowserViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 600)];
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.96].CGColor;
    self.view.layer.cornerRadius = 8.0;
    self.view.layer.borderColor = [NSColor colorWithWhite:0.80 alpha:1.0].CGColor;
    self.view.layer.borderWidth = 1.0;
    self.view.layer.masksToBounds = YES;

    _allEntries = [NSMutableArray array];
    _filteredEntries = [NSMutableArray array];
    _sortKey = @"name";
    _sortAscending = YES;
    _mediaOnlyFilter = NO;

    [self setupUI];

    // Restore last visited directory or default to Movies / Home
    NSString *lastPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"vplay.filebrowser.lastdir"];
    NSURL *startDir = nil;
    if (lastPath.length && [[NSFileManager defaultManager] fileExistsAtPath:lastPath]) {
        startDir = [NSURL fileURLWithPath:lastPath];
    }
    if (!startDir) {
        NSString *moviesPath = [NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES) firstObject];
        if (moviesPath && [[NSFileManager defaultManager] fileExistsAtPath:moviesPath]) {
            startDir = [NSURL fileURLWithPath:moviesPath];
        }
    }
    if (!startDir) {
        startDir = [NSURL fileURLWithPath:NSHomeDirectory()];
    }
    [self navigateToDirectory:startDir];
}

- (void)setupUI {
    NSView *container = self.view;
    CGFloat width = container.bounds.size.width;
    CGFloat height = container.bounds.size.height;

    // --- 1. Top Navigation Bar (y = height - 34, height 34) ---
    NSView *navBar = [[NSView alloc] initWithFrame:NSMakeRect(0, height - 34, width, 34)];
    navBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    navBar.wantsLayer = YES;
    navBar.layer.backgroundColor = [NSColor colorWithWhite:0.94 alpha:1.0].CGColor;

    // Bottom border line for navBar
    NSBox *navLine = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, width, 1)];
    navLine.boxType = NSBoxSeparator;
    navLine.autoresizingMask = NSViewWidthSizable;
    [navBar addSubview:navLine];

    // Up button
    _upButton = [NSButton buttonWithTitle:@"▲ Up" target:self action:@selector(goUp:)];
    _upButton.bezelStyle = NSBezelStyleRounded;
    _upButton.controlSize = NSControlSizeSmall;
    _upButton.frame = NSMakeRect(4, 4, 48, 25);
    _upButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _upButton.toolTip = @"Go to parent folder (Delete or Left Arrow)";
    _upButton.contentTintColor = [NSColor blackColor];
    [navBar addSubview:_upButton];

    // Places popup
    _placesPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(54, 4, 90, 25) pullsDown:YES];
    _placesPopup.controlSize = NSControlSizeSmall;
    _placesPopup.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _placesPopup.contentTintColor = [NSColor blackColor];
    [_placesPopup addItemWithTitle:@"📍 Places ▾"];
    [_placesPopup addItemsWithTitles:@[
        @"Movies",
        @"Downloads",
        @"Desktop",
        @"Documents",
        @"Music",
        @"Home"
    ]];
    [_placesPopup.menu addItem:NSMenuItem.separatorItem];
    [_placesPopup addItemsWithTitles:@[
        @"Volumes & Discs",
        @"Root (/)"
    ]];
    [_placesPopup.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *chooseItem = [_placesPopup.menu addItemWithTitle:@"Choose Any Folder…" action:@selector(chooseCustomFolder:) keyEquivalent:@""];
    chooseItem.target = self;

    _placesPopup.target = self;
    _placesPopup.action = @selector(placeSelected:);
    [navBar addSubview:_placesPopup];

    // Path label (Bold Black Text)
    _pathLabel = [NSTextField labelWithString:@""];
    _pathLabel.frame = NSMakeRect(148, 6, width - 212, 20);
    _pathLabel.autoresizingMask = NSViewWidthSizable;
    _pathLabel.textColor = [NSColor blackColor];
    _pathLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    _pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [navBar addSubview:_pathLabel];

    // Refresh button
    NSButton *refreshBtn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Refresh"] target:self action:@selector(refreshAction:)];
    refreshBtn.bezelStyle = NSBezelStyleInline;
    refreshBtn.bordered = NO;
    refreshBtn.contentTintColor = [NSColor blackColor];
    refreshBtn.toolTip = @"Refresh directory";
    refreshBtn.frame = NSMakeRect(width - 58, 4, 26, 25);
    refreshBtn.autoresizingMask = NSViewMinXMargin;
    [navBar addSubview:refreshBtn];

    // Volumes button
    NSButton *volumesBtn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"opticaldisc" accessibilityDescription:@"Discs & Volumes"] target:self action:@selector(goToVolumes:)];
    volumesBtn.bezelStyle = NSBezelStyleInline;
    volumesBtn.bordered = NO;
    volumesBtn.contentTintColor = [NSColor blackColor];
    volumesBtn.toolTip = @"Mounted volumes and discs";
    volumesBtn.frame = NSMakeRect(width - 30, 4, 26, 25);
    volumesBtn.autoresizingMask = NSViewMinXMargin;
    [navBar addSubview:volumesBtn];

    [container addSubview:navBar];

    // --- 2. Search & Filter Bar (y = height - 64, height 28) ---
    NSView *filterBar = [[NSView alloc] initWithFrame:NSMakeRect(0, height - 64, width, 28)];
    filterBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    filterBar.wantsLayer = YES;
    filterBar.layer.backgroundColor = [NSColor colorWithWhite:0.98 alpha:1.0].CGColor;

    NSBox *filterLine = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, width, 1)];
    filterLine.boxType = NSBoxSeparator;
    filterLine.autoresizingMask = NSViewWidthSizable;
    [filterBar addSubview:filterLine];

    // Search Field
    _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(4, 2, width - 176, 24)];
    _searchField.autoresizingMask = NSViewWidthSizable;
    _searchField.placeholderString = @"Search in folder…";
    _searchField.font = [NSFont systemFontOfSize:11];
    _searchField.textColor = [NSColor blackColor];
    _searchField.delegate = self;
    [filterBar addSubview:_searchField];

    // Filter Popup
    _filterPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(width - 170, 1, 84, 25) pullsDown:NO];
    _filterPopup.autoresizingMask = NSViewMinXMargin;
    _filterPopup.controlSize = NSControlSizeSmall;
    _filterPopup.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    _filterPopup.contentTintColor = [NSColor blackColor];
    [_filterPopup addItemsWithTitles:@[@"All Files", @"Media Only"]];
    _filterPopup.target = self;
    _filterPopup.action = @selector(filterChanged:);
    [filterBar addSubview:_filterPopup];

    // Sort Popup
    _sortPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(width - 84, 1, 80, 25) pullsDown:NO];
    _sortPopup.autoresizingMask = NSViewMinXMargin;
    _sortPopup.controlSize = NSControlSizeSmall;
    _sortPopup.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    _sortPopup.contentTintColor = [NSColor blackColor];
    [_sortPopup addItemsWithTitles:@[@"Name ▾", @"Name ▴", @"Date ▾", @"Date ▴", @"Size ▾", @"Size ▴"]];
    _sortPopup.target = self;
    _sortPopup.action = @selector(sortChanged:);
    [filterBar addSubview:_sortPopup];

    [container addSubview:filterBar];

    // --- 3. Bottom Action Bar (y = 0, height 36) ---
    NSView *bottomBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 36)];
    bottomBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    bottomBar.wantsLayer = YES;
    bottomBar.layer.backgroundColor = [NSColor colorWithWhite:0.95 alpha:1.0].CGColor;

    NSBox *bottomLine = [[NSBox alloc] initWithFrame:NSMakeRect(0, 35, width, 1)];
    bottomLine.boxType = NSBoxSeparator;
    bottomLine.autoresizingMask = NSViewWidthSizable;
    [bottomBar addSubview:bottomLine];

    _playButton = [NSButton buttonWithTitle:@"▶ Play" target:self action:@selector(playSelected:)];
    _playButton.frame = NSMakeRect(4, 5, 68, 26);
    _playButton.controlSize = NSControlSizeSmall;
    _playButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    _playButton.bezelStyle = NSBezelStyleRounded;
    _playButton.toolTip = @"Play selected file or open folder (Return)";
    _playButton.contentTintColor = [NSColor blackColor];
    [bottomBar addSubview:_playButton];

    _queueButton = [NSButton buttonWithTitle:@"+ Queue" target:self action:@selector(queueSelected:)];
    _queueButton.frame = NSMakeRect(76, 5, 72, 26);
    _queueButton.controlSize = NSControlSizeSmall;
    _queueButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _queueButton.bezelStyle = NSBezelStyleRounded;
    _queueButton.toolTip = @"Add selected item to playlist";
    _queueButton.contentTintColor = [NSColor blackColor];
    [bottomBar addSubview:_queueButton];

    _playFolderButton = [NSButton buttonWithTitle:@"📁 Play Folder" target:self action:@selector(playFolder:)];
    _playFolderButton.frame = NSMakeRect(152, 5, 88, 26);
    _playFolderButton.controlSize = NSControlSizeSmall;
    _playFolderButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _playFolderButton.bezelStyle = NSBezelStyleRounded;
    _playFolderButton.toolTip = @"Play all media in this directory";
    _playFolderButton.contentTintColor = [NSColor blackColor];
    [bottomBar addSubview:_playFolderButton];

    _statusLabel = [NSTextField labelWithString:@"0 items"];
    _statusLabel.frame = NSMakeRect(244, 9, width - 250, 18);
    _statusLabel.autoresizingMask = NSViewWidthSizable;
    _statusLabel.alignment = NSTextAlignmentRight;
    _statusLabel.textColor = [NSColor blackColor];
    _statusLabel.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];
    [bottomBar addSubview:_statusLabel];

    [container addSubview:bottomBar];

    // --- 4. Middle: ScrollView with TableView ---
    CGFloat tableY = 36;
    CGFloat tableHeight = MAX(40, height - 64 - tableY);
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, tableY, width, tableHeight)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.drawsBackground = YES;
    _scrollView.backgroundColor = [NSColor whiteColor];

    _tableView = [[VPFileBrowserTableView alloc] initWithFrame:_scrollView.bounds];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = [NSColor whiteColor];
    _tableView.rowHeight = 24;
    _tableView.doubleAction = @selector(tableDoubleClicked:);
    _tableView.target = self;
    _tableView.style = NSTableViewStylePlain;
    _tableView.usesAlternatingRowBackgroundColors = YES;

    // Table Columns with Bold Black Headers
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.title = @"Name";
    nameColumn.minWidth = 140;
    nameColumn.width = width - 150;
    [_tableView addTableColumn:nameColumn];

    NSTableColumn *dateColumn = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    dateColumn.title = @"Modified";
    dateColumn.width = 75;
    dateColumn.minWidth = 55;
    [_tableView addTableColumn:dateColumn];

    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    sizeColumn.title = @"Size";
    sizeColumn.width = 65;
    sizeColumn.minWidth = 45;
    [_tableView addTableColumn:sizeColumn];

    NSDictionary *headerAttrs = @{
        NSForegroundColorAttributeName: [NSColor blackColor],
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightBold]
    };
    for (NSTableColumn *col in @[nameColumn, dateColumn, sizeColumn]) {
        col.headerCell.attributedStringValue = [[NSAttributedString alloc] initWithString:col.title attributes:headerAttrs];
    }

    _scrollView.documentView = _tableView;
    [container addSubview:_scrollView];

    // Empty folder label (shown when directory has 0 items)
    _emptyLabel = [NSTextField wrappingLabelWithString:@"Folder is empty.\nUse '📍 Places' to browse other folders."];
    _emptyLabel.frame = NSMakeRect(20, tableY + tableHeight / 2 - 30, width - 40, 60);
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _emptyLabel.textColor = [NSColor colorWithWhite:0.25 alpha:1.0];
    _emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    _emptyLabel.hidden = YES;
    [container addSubview:_emptyLabel];
}

#pragma mark - Navigation

- (void)navigateToDirectory:(NSURL *)directoryURL {
    if (!directoryURL) return;

    NSURL *resolved = [directoryURL URLByResolvingSymlinksInPath] ?: directoryURL;
    self.currentDirectory = resolved;

    // Save for next launch
    [[NSUserDefaults standardUserDefaults] setObject:resolved.path forKey:@"vplay.filebrowser.lastdir"];

    NSString *displayPath = resolved.path;
    NSString *home = NSHomeDirectory();
    if ([displayPath hasPrefix:home]) {
        displayPath = [@"~" stringByAppendingString:[displayPath substringFromIndex:home.length]];
    }
    self.pathLabel.stringValue = displayPath ?: @"";
    self.pathLabel.toolTip = resolved.path;

    [self.allEntries removeAllObjects];

    // Add ".." Parent Directory entry if not at filesystem root "/"
    if (![resolved.path isEqualToString:@"/"]) {
        VPFileBrowserEntry *parentEntry = [[VPFileBrowserEntry alloc] init];
        parentEntry.url = [resolved URLByDeletingLastPathComponent];
        parentEntry.name = @".. (Parent Folder)";
        parentEntry.isParent = YES;
        parentEntry.isDirectory = YES;
        parentEntry.sizeString = @"";
        parentEntry.dateString = @"";
        [self.allEntries addObject:parentEntry];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtURL:resolved
                          includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLIsPackageKey]
                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                               error:nil];

    static NSDateFormatter *dateFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = @"MMM d, HH:mm";
    });

    for (NSURL *url in contents) {
        NSNumber *isDirVal = nil;
        [url getResourceValue:&isDirVal forKey:NSURLIsDirectoryKey error:nil];
        BOOL isDir = [isDirVal boolValue];

        NSNumber *isPkgVal = nil;
        [url getResourceValue:&isPkgVal forKey:NSURLIsPackageKey error:nil];
        BOOL isPkg = [isPkgVal boolValue];

        VPFileBrowserEntry *entry = [[VPFileBrowserEntry alloc] init];
        entry.url = url;
        entry.name = url.lastPathComponent ?: @"";

        NSString *ext = url.pathExtension.lowercaseString;
        BOOL isDisc = (isDir && [VPDiscSupport kindForURL:url] != VPDiscKindNone) || [VPDiscSupport isDiscImage:url] || [@[@"iso", @"img", @"dmg", @"toast", @"vcd", @"dvdmedia"] containsObject:ext];
        BOOL isMedia = [VPURLHelper isSupportedMediaPath:url.path] || [VPPlaylist isPlaylistFile:url];
        BOOL isAudio = [@[@"mp3", @"m4a", @"aac", @"flac", @"wav", @"ogg", @"opus", @"aiff", @"wma", @"alac"] containsObject:ext];

        entry.isDirectory = isDir && !isPkg;
        entry.isDisc = isDisc;
        entry.isMedia = isMedia;
        entry.isAudio = isAudio;

        NSDate *modDate = nil;
        [url getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:nil];
        entry.dateModified = modDate;
        entry.dateString = modDate ? [dateFormatter stringFromDate:modDate] : @"--";

        if (!entry.isDirectory) {
            NSNumber *fileSize = nil;
            [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            unsigned long long bytes = [fileSize unsignedLongLongValue];
            entry.sizeBytes = bytes;
            entry.sizeString = [self formatSize:bytes];
        } else {
            entry.sizeBytes = 0;
            entry.sizeString = isDisc ? @"Disc" : @"Folder";
        }

        [self.allEntries addObject:entry];
    }

    [self applyFilterAndSort];
}

- (void)refresh {
    [self navigateToDirectory:self.currentDirectory];
}

- (void)refreshAction:(id)sender {
    [self refresh];
}

- (void)applyFilterAndSort {
    [self.filteredEntries removeAllObjects];
    NSString *search = [self.searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;

    NSUInteger mediaCount = 0;
    VPFileBrowserEntry *parentEntry = nil;

    for (VPFileBrowserEntry *entry in self.allEntries) {
        if (entry.isParent) {
            parentEntry = entry;
            continue;
        }
        if (entry.isMedia || entry.isDisc) mediaCount++;
        if (self.mediaOnlyFilter && !entry.isDirectory && !entry.isMedia && !entry.isDisc) continue;
        if (search.length && ![entry.name.lowercaseString containsString:search]) continue;
        [self.filteredEntries addObject:entry];
    }

    NSString *key = self.sortKey;
    BOOL asc = self.sortAscending;
    [self.filteredEntries sortUsingComparator:^NSComparisonResult(VPFileBrowserEntry *a, VPFileBrowserEntry *b) {
        if (a.isDirectory != b.isDirectory) {
            return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        }
        if ([key isEqualToString:@"date"]) {
            NSDate *dateA = a.dateModified ?: [NSDate distantPast];
            NSDate *dateB = b.dateModified ?: [NSDate distantPast];
            NSComparisonResult res = [dateA compare:dateB];
            return asc ? res : -res;
        } else if ([key isEqualToString:@"size"]) {
            if (a.sizeBytes < b.sizeBytes) return asc ? NSOrderedAscending : NSOrderedDescending;
            if (a.sizeBytes > b.sizeBytes) return asc ? NSOrderedDescending : NSOrderedAscending;
            return [a.name localizedCaseInsensitiveCompare:b.name];
        } else {
            NSComparisonResult res = [a.name localizedCaseInsensitiveCompare:b.name];
            return asc ? res : -res;
        }
    }];

    // Put ".." at index 0 if present
    if (parentEntry) {
        [self.filteredEntries insertObject:parentEntry atIndex:0];
    }

    [self.tableView reloadData];
    if (self.filteredEntries.count) {
        [self.tableView scrollRowToVisible:0];
    }

    NSUInteger fileCount = parentEntry ? (self.filteredEntries.count - 1) : self.filteredEntries.count;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu items (%lu media)", (unsigned long)fileCount, (unsigned long)mediaCount];
    self.emptyLabel.hidden = (fileCount > 0);
}

- (NSString *)formatSize:(unsigned long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    if (bytes < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
}

#pragma mark - Actions

- (void)placeSelected:(NSPopUpButton *)sender {
    NSString *title = sender.titleOfSelectedItem;
    if ([title isEqualToString:@"Movies"]) {
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES) firstObject];
        if (p) [self navigateToDirectory:[NSURL fileURLWithPath:p]];
    } else if ([title isEqualToString:@"Downloads"]) {
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
        if (p) [self navigateToDirectory:[NSURL fileURLWithPath:p]];
    } else if ([title isEqualToString:@"Desktop"]) {
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) firstObject];
        if (p) [self navigateToDirectory:[NSURL fileURLWithPath:p]];
    } else if ([title isEqualToString:@"Documents"]) {
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (p) [self navigateToDirectory:[NSURL fileURLWithPath:p]];
    } else if ([title isEqualToString:@"Music"]) {
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES) firstObject];
        if (p) [self navigateToDirectory:[NSURL fileURLWithPath:p]];
    } else if ([title isEqualToString:@"Home"]) {
        [self navigateToDirectory:[NSURL fileURLWithPath:NSHomeDirectory()]];
    } else if ([title isEqualToString:@"Volumes & Discs"]) {
        [self navigateToDirectory:[NSURL fileURLWithPath:@"/Volumes"]];
    } else if ([title isEqualToString:@"Root (/)"]) {
        [self navigateToDirectory:[NSURL fileURLWithPath:@"/"]];
    }
}

- (void)chooseCustomFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Browse Folder";
    panel.message = @"Choose any directory to browse and play media in vplay.";
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
            if (result == NSModalResponseOK && panel.URL) {
                [self navigateToDirectory:panel.URL];
            }
        }];
    } else {
        if ([panel runModal] == NSModalResponseOK && panel.URL) {
            [self navigateToDirectory:panel.URL];
        }
    }
}

- (void)filterChanged:(NSPopUpButton *)sender {
    self.mediaOnlyFilter = sender.indexOfSelectedItem == 1;
    [self applyFilterAndSort];
}

- (void)sortChanged:(NSPopUpButton *)sender {
    NSInteger idx = sender.indexOfSelectedItem;
    if (idx == 0) { self.sortKey = @"name"; self.sortAscending = YES; }
    else if (idx == 1) { self.sortKey = @"name"; self.sortAscending = NO; }
    else if (idx == 2) { self.sortKey = @"date"; self.sortAscending = NO; }
    else if (idx == 3) { self.sortKey = @"date"; self.sortAscending = YES; }
    else if (idx == 4) { self.sortKey = @"size"; self.sortAscending = NO; }
    else if (idx == 5) { self.sortKey = @"size"; self.sortAscending = YES; }
    [self applyFilterAndSort];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    [self applyFilterAndSort];
}

- (void)goToVolumes:(id)sender {
    [self navigateToDirectory:[NSURL fileURLWithPath:@"/Volumes"]];
}

- (void)playFolder:(id)sender {
    if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFolderURL:)]) {
        [self.delegate fileBrowserDidSelectFolderURL:self.currentDirectory];
    }
}

- (IBAction)goUp:(id)sender {
    NSURL *parent = [self.currentDirectory URLByDeletingLastPathComponent];
    if (parent && ![parent isEqual:self.currentDirectory]) {
        [self navigateToDirectory:parent];
    }
}

- (VPFileBrowserEntry *)selectedEntry {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 && self.tableView.clickedRow >= 0) row = self.tableView.clickedRow;
    if (row >= 0 && row < (NSInteger)self.filteredEntries.count) {
        return self.filteredEntries[row];
    }
    return nil;
}

- (void)playSelected:(id)sender {
    VPFileBrowserEntry *entry = [self selectedEntry];
    if (!entry) {
        // Fall back to first media entry or first entry
        for (VPFileBrowserEntry *item in self.filteredEntries) {
            if (!item.isParent && (item.isMedia || item.isDisc)) {
                entry = item;
                break;
            }
        }
    }
    if (!entry) {
        [self playFolder:sender];
        return;
    }

    if (entry.isParent) {
        [self goUp:sender];
    } else if (entry.isDisc) {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFolderURL:)]) {
            [self.delegate fileBrowserDidSelectFolderURL:entry.url];
        } else if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFileURL:)]) {
            [self.delegate fileBrowserDidSelectFileURL:entry.url];
        }
    } else if (entry.isDirectory) {
        // If clicking Play on a directory, queue/play that folder
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFolderURL:)]) {
            [self.delegate fileBrowserDidSelectFolderURL:entry.url];
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFileURL:)]) {
            [self.delegate fileBrowserDidSelectFileURL:entry.url];
        }
    }
}

- (void)queueSelected:(id)sender {
    VPFileBrowserEntry *entry = [self selectedEntry];
    if (!entry || entry.isParent) return;

    if (entry.isDirectory || entry.isDisc) {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFolderURL:)]) {
            [self.delegate fileBrowserDidSelectFolderURL:entry.url];
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidEnqueueFileURL:)]) {
            [self.delegate fileBrowserDidEnqueueFileURL:entry.url];
        } else if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFileURL:)]) {
            [self.delegate fileBrowserDidSelectFileURL:entry.url];
        }
    }
}

- (void)tableDoubleClicked:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0) row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.filteredEntries.count) return;

    VPFileBrowserEntry *entry = self.filteredEntries[row];
    if (entry.isParent) {
        [self goUp:sender];
    } else if (entry.isDisc) {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFolderURL:)]) {
            [self.delegate fileBrowserDidSelectFolderURL:entry.url];
        } else if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFileURL:)]) {
            [self.delegate fileBrowserDidSelectFileURL:entry.url];
        }
    } else if (entry.isDirectory) {
        [self navigateToDirectory:entry.url];
    } else {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFileURL:)]) {
            [self.delegate fileBrowserDidSelectFileURL:entry.url];
        }
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.filteredEntries.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.filteredEntries.count) return nil;
    VPFileBrowserEntry *entry = self.filteredEntries[row];

    NSString *identifier = tableColumn.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];

    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 24)];
        cell.identifier = identifier;

        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.frame = cell.bounds;
        textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        textField.textColor = [NSColor blackColor];
        cell.textField = textField;
        [cell addSubview:textField];
    }

    cell.textField.textColor = [NSColor blackColor];

    if ([identifier isEqualToString:@"name"]) {
        NSString *icon;
        if (entry.isParent) icon = @"⬆  ";
        else if (entry.isDisc) icon = @"💿  ";
        else if (entry.isDirectory) icon = @"📁  ";
        else if (entry.isAudio) icon = @"🎵  ";
        else if (entry.isMedia) icon = @"🎬  ";
        else icon = @"📄  ";

        cell.textField.stringValue = [icon stringByAppendingString:entry.name];
        cell.textField.font = (entry.isParent || entry.isDirectory)
            ? [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
            : [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        cell.textField.alignment = NSTextAlignmentLeft;
    } else if ([identifier isEqualToString:@"date"]) {
        cell.textField.stringValue = entry.dateString ?: @"--";
        cell.textField.alignment = NSTextAlignmentLeft;
    } else if ([identifier isEqualToString:@"size"]) {
        cell.textField.stringValue = entry.sizeString ?: @"--";
        cell.textField.alignment = NSTextAlignmentRight;
    }

    return cell;
}

@end
