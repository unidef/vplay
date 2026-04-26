#import "VPAudioFilterWindowController.h"
#import "VPAudioFilters.h"

@interface VPChainTableView : NSTableView
@property (nonatomic, copy, nullable) void (^deleteHandler)(void);
@end

@implementation VPChainTableView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 51 || event.keyCode == 117) { // Delete or Forward Delete
        if (self.deleteHandler) { self.deleteHandler(); return; }
    }
    [super keyDown:event];
}
@end

@interface VPAudioFilterWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *categoryPopup;
@property (nonatomic, strong) NSTableView *libraryTable;
@property (nonatomic, strong) NSTextField *libraryDetail;
@property (nonatomic, strong) NSTextField *libraryOptions;

@property (nonatomic, strong) VPChainTableView *chainTable;
@property (nonatomic, strong) NSTextField *inspectorTitle;
@property (nonatomic, strong) NSSlider *amountSlider;
@property (nonatomic, strong) NSTextField *amountLabel;
@property (nonatomic, strong) NSTextField *expressionField;
@property (nonatomic, strong) NSButton *updateButton;

@property (nonatomic, strong) NSTextField *customField;
@property (nonatomic, strong) NSTextField *graphLabel;
@property (nonatomic, strong) NSTextField *statusLabel;

@property (nonatomic, strong) NSButton *liveUpdateCheckbox;
@property (nonatomic, strong) NSButton *bypassCheckbox;

@property (nonatomic, strong) NSArray<VPAudioFilterTemplate *> *allTemplates;
@property (nonatomic, strong) NSMutableArray<VPAudioFilterTemplate *> *filteredTemplates;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *stages;
@end

@implementation VPAudioFilterWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 650)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Audio Filters & Equalizer — FFmpeg Audio Chain";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(900, 600);
    window.frameAutosaveName = @"VPAudioFilterWindow";
    if ((self = [super initWithWindow:window])) {
        window.delegate = self;
        _allTemplates = [VPAudioFilters library];
        _filteredTemplates = [_allTemplates mutableCopy];
        _stages = [NSMutableArray array];
        [self buildUI];
        [window center];
        [self reload];
    }
    return self;
}

#pragma mark - UI Building

- (void)buildUI {
    NSView *content = self.window.contentView;
    CGFloat width = [self.window contentRectForFrameRect:self.window.frame].size.width;
    CGFloat height = [self.window contentRectForFrameRect:self.window.frame].size.height;
    if (width < 960) width = 960;
    if (height < 650) height = 650;

    // LEFT PANE: FFmpeg Filter Library (All 141 Audio Filters)
    // -------------------------------------------------------------
    NSTextField *libTitle = [NSTextField labelWithString:@"FFmpeg Audio Filter Library"];
    libTitle.frame = NSMakeRect(20, height - 36, 260, 20);
    libTitle.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    libTitle.autoresizingMask = NSViewMinYMargin;
    [content addSubview:libTitle];

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, height - 68, 240, 24)];
    self.searchField.placeholderString = @"Search filters…";
    self.searchField.delegate = self;
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);
    self.searchField.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.searchField];

    self.categoryPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(268, height - 69, 182, 26) pullsDown:NO];
    for (NSString *cat in [VPAudioFilters categories]) {
        [self.categoryPopup addItemWithTitle:cat];
    }
    self.categoryPopup.target = self;
    self.categoryPopup.action = @selector(categoryChanged:);
    self.categoryPopup.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.categoryPopup];

    // Library Table
    NSScrollView *libScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 230, 430, height - 308)];
    libScroll.hasVerticalScroller = YES;
    libScroll.borderType = NSBezelBorder;
    libScroll.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;

    self.libraryTable = [[NSTableView alloc] initWithFrame:libScroll.bounds];
    NSTableColumn *colName = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    colName.title = @"Filter (Double-click to Add)";
    colName.width = 280;
    colName.resizingMask = NSTableColumnAutoresizingMask;
    [self.libraryTable addTableColumn:colName];

    NSTableColumn *colCat = [[NSTableColumn alloc] initWithIdentifier:@"cat"];
    colCat.title = @"Category";
    colCat.width = 125;
    [self.libraryTable addTableColumn:colCat];

    self.libraryTable.dataSource = self;
    self.libraryTable.delegate = self;
    self.libraryTable.rowHeight = 24;
    self.libraryTable.doubleAction = @selector(addFromLibrary:);
    self.libraryTable.target = self;
    libScroll.documentView = self.libraryTable;
    [content addSubview:libScroll];

    // Library Filter Info Box
    NSBox *libInfoBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 150, 430, 72)];
    libInfoBox.title = @"Filter Info & Syntax";
    libInfoBox.titleFont = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    libInfoBox.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    
    self.libraryDetail = [NSTextField wrappingLabelWithString:@"Select an FFmpeg audio filter above to view its details."];
    self.libraryDetail.frame = NSMakeRect(8, 24, 414, 30);
    self.libraryDetail.font = [NSFont systemFontOfSize:11];
    self.libraryDetail.textColor = NSColor.labelColor;
    [libInfoBox.contentView addSubview:self.libraryDetail];

    self.libraryOptions = [NSTextField wrappingLabelWithString:@""];
    self.libraryOptions.frame = NSMakeRect(8, 6, 414, 16);
    self.libraryOptions.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.libraryOptions.textColor = NSColor.secondaryLabelColor;
    [libInfoBox.contentView addSubview:self.libraryOptions];
    [content addSubview:libInfoBox];

    NSButton *addLibBtn = [NSButton buttonWithTitle:@"+ Add to Chain →" target:self action:@selector(addFromLibrary:)];
    addLibBtn.frame = NSMakeRect(20, 114, 150, 28);
    addLibBtn.bezelStyle = NSBezelStyleRounded;
    addLibBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    addLibBtn.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:addLibBtn];


    // RIGHT PANE: Active Audio Filter Chain
    // -------------------------------------------------------------
    NSTextField *chainTitle = [NSTextField labelWithString:@"Active Filter Chain (Processed in Order)"];
    chainTitle.frame = NSMakeRect(470, height - 36, 400, 20);
    chainTitle.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    chainTitle.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    [content addSubview:chainTitle];

    // Chain Table
    NSScrollView *chainScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(470, 310, 470, height - 356)];
    chainScroll.hasVerticalScroller = YES;
    chainScroll.borderType = NSBezelBorder;
    chainScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinXMargin;

    self.chainTable = [[VPChainTableView alloc] initWithFrame:chainScroll.bounds];
    NSTableColumn *cIndex = [[NSTableColumn alloc] initWithIdentifier:@"idx"];
    cIndex.title = @"#";
    cIndex.width = 30;
    [self.chainTable addTableColumn:cIndex];

    NSTableColumn *cExpr = [[NSTableColumn alloc] initWithIdentifier:@"expr"];
    cExpr.title = @"Active Filter Expression";
    cExpr.width = 410;
    cExpr.resizingMask = NSTableColumnAutoresizingMask;
    [self.chainTable addTableColumn:cExpr];

    self.chainTable.dataSource = self;
    self.chainTable.delegate = self;
    self.chainTable.rowHeight = 24;
    __weak typeof(self) weakSelf = self;
    self.chainTable.deleteHandler = ^{
        [weakSelf removeStage:nil];
    };
    chainScroll.documentView = self.chainTable;
    [content addSubview:chainScroll];

    // Chain Action Buttons
    NSButton *upBtn = [NSButton buttonWithTitle:@"▲ Move Up" target:self action:@selector(moveUp:)];
    upBtn.frame = NSMakeRect(470, 276, 95, 26);
    upBtn.bezelStyle = NSBezelStyleRounded;
    upBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:upBtn];

    NSButton *downBtn = [NSButton buttonWithTitle:@"▼ Move Down" target:self action:@selector(moveDown:)];
    downBtn.frame = NSMakeRect(572, 276, 105, 26);
    downBtn.bezelStyle = NSBezelStyleRounded;
    downBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:downBtn];

    NSButton *remBtn = [NSButton buttonWithTitle:@"Remove Filter" target:self action:@selector(removeStage:)];
    remBtn.frame = NSMakeRect(684, 276, 115, 26);
    remBtn.bezelStyle = NSBezelStyleRounded;
    remBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:remBtn];

    NSButton *clrBtn = [NSButton buttonWithTitle:@"Clear All" target:self action:@selector(clearChain:)];
    clrBtn.frame = NSMakeRect(806, 276, 85, 26);
    clrBtn.bezelStyle = NSBezelStyleRounded;
    clrBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:clrBtn];

    // Filter Settings & Expression Inspector (for updating filters in the list)
    NSBox *inspectorBox = [[NSBox alloc] initWithFrame:NSMakeRect(470, 110, 470, 156)];
    inspectorBox.title = @"Filter Settings & Parameters (Update Selected)";
    inspectorBox.titleFont = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    inspectorBox.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable | NSViewMinXMargin;

    self.inspectorTitle = [NSTextField labelWithString:@"Select a filter in the chain to adjust and update it."];
    self.inspectorTitle.frame = NSMakeRect(10, 108, 450, 18);
    self.inspectorTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [inspectorBox.contentView addSubview:self.inspectorTitle];

    self.amountSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(amountSliderChanged:)];
    self.amountSlider.frame = NSMakeRect(10, 84, 300, 20);
    self.amountSlider.enabled = NO;
    [inspectorBox.contentView addSubview:self.amountSlider];

    self.amountLabel = [NSTextField labelWithString:@""];
    self.amountLabel.frame = NSMakeRect(318, 86, 140, 18);
    self.amountLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [inspectorBox.contentView addSubview:self.amountLabel];

    NSTextField *exprPrompt = [NSTextField labelWithString:@"Filter Expression (edit and update):"];
    exprPrompt.frame = NSMakeRect(10, 56, 240, 16);
    exprPrompt.font = [NSFont systemFontOfSize:11];
    exprPrompt.textColor = NSColor.secondaryLabelColor;
    [inspectorBox.contentView addSubview:exprPrompt];

    self.expressionField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 28, 330, 24)];
    self.expressionField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.expressionField.placeholderString = @"e.g. bass=g=8:f=100 or aecho=0.8:0.9:500:0.3";
    self.expressionField.target = self;
    self.expressionField.action = @selector(updateSelectedStage:);
    [inspectorBox.contentView addSubview:self.expressionField];

    self.updateButton = [NSButton buttonWithTitle:@"Update Filter" target:self action:@selector(updateSelectedStage:)];
    self.updateButton.frame = NSMakeRect(348, 26, 110, 28);
    self.updateButton.bezelStyle = NSBezelStyleRounded;
    self.updateButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [inspectorBox.contentView addSubview:self.updateButton];

    [content addSubview:inspectorBox];

    // Quick Custom Filter Entry
    NSTextField *custPrompt = [NSTextField labelWithString:@"Add Custom FFmpeg Audio Filter:"];
    custPrompt.frame = NSMakeRect(20, 80, 240, 16);
    custPrompt.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    custPrompt.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:custPrompt];

    self.customField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 54, 330, 24)];
    self.customField.placeholderString = @"e.g. pan=stereo|c0=c0-c1|c1=c1-c0 or dynaudnorm";
    self.customField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.customField.target = self;
    self.customField.action = @selector(addCustom:);
    self.customField.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:self.customField];

    NSButton *addCustBtn = [NSButton buttonWithTitle:@"+ Add Custom" target:self action:@selector(addCustom:)];
    addCustBtn.frame = NSMakeRect(356, 52, 100, 28);
    addCustBtn.bezelStyle = NSBezelStyleRounded;
    addCustBtn.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:addCustBtn];


    // BOTTOM BAR: Live Graph, Status, Live Toggle, Bypass, and Apply
    // -------------------------------------------------------------
    self.graphLabel = [NSTextField wrappingLabelWithString:@""];
    self.graphLabel.frame = NSMakeRect(470, 72, 470, 32);
    self.graphLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.graphLabel.textColor = NSColor.secondaryLabelColor;
    self.graphLabel.selectable = YES;
    self.graphLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:self.graphLabel];

    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.frame = NSMakeRect(470, 52, 470, 18);
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = NSColor.labelColor;
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:self.statusLabel];

    // Bottom controls
    self.liveUpdateCheckbox = [NSButton checkboxWithTitle:@"Live Audio Update (Auto-Apply)" target:self action:@selector(liveUpdateToggled:)];
    self.liveUpdateCheckbox.frame = NSMakeRect(20, 14, 230, 24);
    self.liveUpdateCheckbox.state = NSControlStateValueOn;
    self.liveUpdateCheckbox.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.liveUpdateCheckbox];

    self.bypassCheckbox = [NSButton checkboxWithTitle:@"Bypass Filters (A/B Test)" target:self action:@selector(bypassChanged:)];
    self.bypassCheckbox.frame = NSMakeRect(255, 14, 190, 24);
    self.bypassCheckbox.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.bypassCheckbox];

    NSButton *saveBtn = [NSButton buttonWithTitle:@"Save Chain…" target:self action:@selector(saveChain:)];
    saveBtn.frame = NSMakeRect(470, 12, 100, 28);
    saveBtn.bezelStyle = NSBezelStyleRounded;
    saveBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:saveBtn];

    NSButton *loadBtn = [NSButton buttonWithTitle:@"Load Chain…" target:self action:@selector(loadChain:)];
    loadBtn.frame = NSMakeRect(576, 12, 100, 28);
    loadBtn.bezelStyle = NSBezelStyleRounded;
    loadBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:loadBtn];

    NSButton *applyBtn = [NSButton buttonWithTitle:@"Apply to Playing Audio" target:self action:@selector(apply:)];
    applyBtn.frame = NSMakeRect(690, 10, 250, 32);
    applyBtn.bezelStyle = NSBezelStyleRounded;
    applyBtn.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    applyBtn.keyEquivalent = @"\r";
    applyBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:applyBtn];
}

#pragma mark - Model & State

- (void)reload {
    [self.stages removeAllObjects];
    for (NSDictionary *stage in VPAudioFilters.shared.stages) {
        [self.stages addObject:[stage mutableCopy]];
    }
    self.bypassCheckbox.state = VPAudioFilters.shared.enabled ? NSControlStateValueOff : NSControlStateValueOn;
    [self.chainTable reloadData];
    [self refreshGraph];
    [self syncInspector];
    if (self.libraryTable.selectedRow < 0 && self.filteredTemplates.count > 0) {
        [self.libraryTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.libraryTable scrollRowToVisible:0];
    }
}

- (void)refreshGraph {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *stage in self.stages) {
        NSString *text = [VPAudioFilters filterTextForStage:stage];
        if (text.length) [parts addObject:text];
    }
    NSString *graph = [parts componentsJoinedByString:@","];
    if (graph.length) {
        self.graphLabel.stringValue = [@"FFmpeg: -af " stringByAppendingString:graph];
    } else {
        self.graphLabel.stringValue = @"Chain is empty — audio is unaffected.";
    }
}

- (void)filterLibrary {
    NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSString *selCategory = self.categoryPopup.titleOfSelectedItem;
    BOOL allCats = [selCategory isEqualToString:@"All"] || !selCategory.length;

    [self.filteredTemplates removeAllObjects];
    for (VPAudioFilterTemplate *t in self.allTemplates) {
        if (!allCats && ![t.category isEqualToString:selCategory]) continue;
        if (query.length > 0) {
            BOOL matchesName = [t.identifier.lowercaseString containsString:query];
            BOOL matchesTitle = [t.title.lowercaseString containsString:query];
            BOOL matchesDetails = [t.details.lowercaseString containsString:query];
            BOOL matchesOpts = [t.optionsSummary.lowercaseString containsString:query];
            if (!matchesName && !matchesTitle && !matchesDetails && !matchesOpts) continue;
        }
        [self.filteredTemplates addObject:t];
    }
    [self.libraryTable reloadData];
    if (self.filteredTemplates.count > 0) {
        [self.libraryTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.libraryTable scrollRowToVisible:0];
    }
}

- (void)searchChanged:(id)sender {
    [self filterLibrary];
}

- (void)categoryChanged:(id)sender {
    [self filterLibrary];
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.libraryTable) {
        return (NSInteger)self.filteredTemplates.count;
    }
    return (NSInteger)self.stages.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (tableView == self.libraryTable) {
        if (row < 0 || row >= (NSInteger)self.filteredTemplates.count) return nil;
        VPAudioFilterTemplate *t = self.filteredTemplates[row];
        NSTableCellView *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 24)];
            cell.identifier = column.identifier;
            NSTextField *field = [NSTextField labelWithString:@""];
            field.frame = NSMakeRect(4, 2, column.width - 8, 20);
            field.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            cell.textField = field;
            [cell addSubview:field];
        }
        if ([column.identifier isEqualToString:@"name"]) {
            cell.textField.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
            cell.textField.stringValue = [NSString stringWithFormat:@"%@  (%@)", t.identifier, t.title];
            cell.textField.textColor = NSColor.labelColor;
        } else {
            cell.textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
            cell.textField.stringValue = t.category;
            cell.textField.textColor = NSColor.secondaryLabelColor;
        }
        return cell;
    }

    if (tableView == self.chainTable) {
        if (row < 0 || row >= (NSInteger)self.stages.count) return nil;
        NSDictionary *stage = self.stages[row];
        NSTableCellView *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 24)];
            cell.identifier = column.identifier;
            NSTextField *field = [NSTextField labelWithString:@""];
            field.frame = NSMakeRect(4, 2, column.width - 8, 20);
            field.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            cell.textField = field;
            [cell addSubview:field];
        }
        if ([column.identifier isEqualToString:@"idx"]) {
            cell.textField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
            cell.textField.stringValue = [NSString stringWithFormat:@"%ld.", (long)(row + 1)];
            cell.textField.textColor = NSColor.tertiaryLabelColor;
        } else {
            cell.textField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
            cell.textField.stringValue = [VPAudioFilters titleForStage:stage];
            cell.textField.textColor = NSColor.labelColor;
        }
        return cell;
    }
    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.libraryTable) {
        NSInteger row = self.libraryTable.selectedRow;
        if (row >= 0 && row < (NSInteger)self.filteredTemplates.count) {
            VPAudioFilterTemplate *t = self.filteredTemplates[row];
            self.libraryDetail.stringValue = t.details.length ? t.details : t.title;
            self.libraryOptions.stringValue = [NSString stringWithFormat:@"[%@] Default: %@  |  Options: %@", t.category, t.format, t.optionsSummary];
        } else {
            self.libraryDetail.stringValue = @"Select an FFmpeg audio filter above to view its details.";
            self.libraryOptions.stringValue = @"";
        }
        return;
    }

    if (notification.object == self.chainTable) {
        [self syncInspector];
    }
}

#pragma mark - Inspector & Updating

- (void)syncInspector {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) {
        self.inspectorTitle.stringValue = @"Select a filter in the chain to adjust and update it.";
        self.amountSlider.enabled = NO;
        self.amountLabel.stringValue = @"";
        self.expressionField.stringValue = @"";
        self.expressionField.enabled = NO;
        self.updateButton.enabled = NO;
        return;
    }

    NSDictionary *stage = self.stages[row];
    self.expressionField.enabled = YES;
    self.updateButton.enabled = YES;
    self.expressionField.stringValue = [VPAudioFilters filterTextForStage:stage];

    NSString *fid = stage[@"id"];
    VPAudioFilterTemplate *t = fid.length ? [VPAudioFilters templateWithIdentifier:fid] : nil;

    if (t && [t.amountName isKindOfClass:[NSString class]] && t.amountName.length > 0) {
        self.amountSlider.enabled = YES;
        self.amountSlider.minValue = t.minimum;
        self.amountSlider.maxValue = t.maximum;
        double amount = [stage[@"amount"] respondsToSelector:@selector(doubleValue)] ? [stage[@"amount"] doubleValue] : t.defaultAmount;
        self.amountSlider.doubleValue = amount;
        self.amountLabel.stringValue = [NSString stringWithFormat:@"%.2f %@", amount, t.unit ?: @""];
        self.inspectorTitle.stringValue = [NSString stringWithFormat:@"%@ — %@ (%@)", t.title, t.amountName, t.unit ?: @""];
    } else {
        self.amountSlider.enabled = NO;
        self.amountLabel.stringValue = @"";
        self.inspectorTitle.stringValue = t ? t.title : (stage[@"custom"] ?: @"Custom Filter");
    }
}

- (void)amountSliderChanged:(NSSlider *)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) return;
    NSMutableDictionary *stage = self.stages[row];
    stage[@"amount"] = @(sender.doubleValue);
    VPAudioFilterTemplate *t = [VPAudioFilters templateWithIdentifier:stage[@"id"] ?: @""];
    if (t) {
        self.amountLabel.stringValue = [NSString stringWithFormat:@"%.2f %@", sender.doubleValue, t.unit];
        self.expressionField.stringValue = [VPAudioFilters filterTextForStage:stage];
    }
    [self.chainTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:1]];
    [self commitAndApplyForced:NO];
}

- (void)updateSelectedStage:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) return;
    NSString *expr = [self.expressionField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!expr.length) return;
    
    NSMutableDictionary *stage = self.stages[row];
    stage[@"custom"] = expr;
    [stage removeObjectForKey:@"id"];
    [stage removeObjectForKey:@"amount"];
    
    [self.chainTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:1]];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Updated stage %ld: %@", (long)(row + 1), expr];
    [self commitAndApplyForced:NO];
}

#pragma mark - Chain Editing

- (void)addFromLibrary:(id)sender {
    NSInteger row = (sender == self.libraryTable && self.libraryTable.clickedRow >= 0) ? self.libraryTable.clickedRow : self.libraryTable.selectedRow;
    if (row < 0 && self.filteredTemplates.count > 0) {
        row = 0;
    }
    if (row < 0 || row >= (NSInteger)self.filteredTemplates.count) return;
    VPAudioFilterTemplate *t = self.filteredTemplates[row];

    NSMutableDictionary *stage = [NSMutableDictionary dictionary];
    stage[@"id"] = t.identifier;
    if ([t.amountName isKindOfClass:[NSString class]] && t.amountName.length > 0) {
        stage[@"amount"] = @(t.defaultAmount);
    }
    [self.stages addObject:stage];
    [self.chainTable reloadData];
    NSInteger newRow = self.stages.count - 1;
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
    [self.chainTable scrollRowToVisible:newRow];
    [self syncInspector];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Added filter: %@", t.title];
    [self commitAndApplyForced:NO];
}

- (void)addCustom:(id)sender {
    NSString *text = [self.customField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    [self.stages addObject:[@{@"custom": text} mutableCopy]];
    self.customField.stringValue = @"";
    [self.chainTable reloadData];
    NSInteger newRow = self.stages.count - 1;
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
    [self.chainTable scrollRowToVisible:newRow];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Added custom filter: %@", text];
    [self commitAndApplyForced:NO];
}

- (void)moveUp:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row <= 0 || row >= (NSInteger)self.stages.count) return;
    [self.stages exchangeObjectAtIndex:row withObjectAtIndex:row - 1];
    [self.chainTable reloadData];
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1] byExtendingSelection:NO];
    [self commitAndApplyForced:NO];
}

- (void)moveDown:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row + 1 >= (NSInteger)self.stages.count) return;
    [self.stages exchangeObjectAtIndex:row withObjectAtIndex:row + 1];
    [self.chainTable reloadData];
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
    [self commitAndApplyForced:NO];
}

- (void)removeStage:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) return;
    [self.stages removeObjectAtIndex:row];
    [self.chainTable reloadData];
    NSInteger nextRow = MIN(row, (NSInteger)self.stages.count - 1);
    if (nextRow >= 0) {
        [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:nextRow] byExtendingSelection:NO];
    }
    [self syncInspector];
    self.statusLabel.stringValue = @"Filter removed.";
    [self commitAndApplyForced:NO];
}

- (void)clearChain:(id)sender {
    if (!self.stages.count) return;
    [self.stages removeAllObjects];
    [self.chainTable reloadData];
    [self syncInspector];
    self.statusLabel.stringValue = @"All filters cleared.";
    [self commitAndApplyForced:NO];
}

#pragma mark - Apply to Live Audio

- (void)commitAndApplyForced:(BOOL)forced {
    VPAudioFilters.shared.stages = [self.stages copy];
    VPAudioFilters.shared.enabled = (self.bypassCheckbox.state != NSControlStateValueOn);
    [VPAudioFilters.shared changed];
    [self refreshGraph];

    if (forced || self.liveUpdateCheckbox.state == NSControlStateValueOn) {
        [self scheduleLiveApply];
    }
}

- (void)scheduleLiveApply {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(executeLiveApply) object:nil];
    [self performSelector:@selector(executeLiveApply) withObject:nil afterDelay:0.12];
}

- (void)executeLiveApply {
    if (self.applyHandler) {
        self.applyHandler();
    }
    NSString *graph = VPAudioFilters.shared.graph;
    if (VPAudioFilters.shared.isActive) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Applied to live audio: -af \"%@\" (%lu filter%@)", graph, (unsigned long)self.stages.count, self.stages.count == 1 ? @"" : @"s"];
    } else {
        self.statusLabel.stringValue = (self.bypassCheckbox.state == NSControlStateValueOn) ?
            @"Filters bypassed on live audio (A/B testing mode)." :
            @"Live audio filter chain is empty.";
    }
}

- (void)apply:(id)sender {
    [self commitAndApplyForced:YES];
}

- (void)liveUpdateToggled:(id)sender {
    if (self.liveUpdateCheckbox.state == NSControlStateValueOn) {
        [self commitAndApplyForced:YES];
    }
}

- (void)bypassChanged:(id)sender {
    [self commitAndApplyForced:YES];
}

#pragma mark - Save & Load

- (void)saveChain:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"audio-filters.json";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"audioFilters": self.stages}
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:nil];
        NSError *error = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            self.statusLabel.stringValue = error.localizedDescription;
        } else {
            self.statusLabel.stringValue = [@"Saved filter chain to " stringByAppendingString:panel.URL.lastPathComponent];
        }
    }];
}

- (void)loadChain:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        id json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:panel.URL] options:0 error:nil];
        NSArray *array = [json isKindOfClass:NSDictionary.class] ? json[@"audioFilters"] : json;
        if (![array isKindOfClass:NSArray.class]) {
            self.statusLabel.stringValue = @"Selected file does not contain a valid audio filter chain.";
            return;
        }
        [self.stages removeAllObjects];
        for (NSDictionary *stage in array) {
            if ([stage isKindOfClass:NSDictionary.class]) {
                [self.stages addObject:[stage mutableCopy]];
            }
        }
        [self.chainTable reloadData];
        [self refreshGraph];
        [self syncInspector];
        self.statusLabel.stringValue = [@"Loaded filter chain from " stringByAppendingString:panel.URL.lastPathComponent];
        [self commitAndApplyForced:NO];
    }];
}

@end
