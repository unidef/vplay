#import "VPShaderEditorWindowController.h"
#import "VPPostProcessing.h"
#import "VPEffectPipeline.h"
#import <CoreVideo/CoreVideo.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface VPShaderEditorWindowController () <NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSTextView *source;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSPopUpButton *templates;
@property (nonatomic, strong) NSTableView *chainTable;
@property (nonatomic, strong) NSPopUpButton *effectPopup;
@property (nonatomic, strong) NSSlider *amountSlider;
@property (nonatomic, strong) NSTextField *amountLabel;
@property (nonatomic, strong) NSImageView *preview;
@property (nonatomic, strong) NSPopUpButton *sourceChoice;
@property (nonatomic, strong) NSButton *includeAdjustments;
@property (nonatomic, strong) NSMutableArray<NSString *> *chain;
@property (nonatomic, strong) CIColorKernel *workingKernel;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong) CIImage *testPattern;
@property (nonatomic, strong) CIImage *liveFrame;
@property (nonatomic, strong) AVPlayerItem *outputItem;
@property (nonatomic, strong) AVPlayerItemVideoOutput *output;
@property (nonatomic, strong) NSTimer *liveTimer;
@property (nonatomic, strong) NSTimer *debounce;
@property (nonatomic) BOOL previewDirty;
@end

static NSArray<NSArray<NSString *> *> *Templates(void) {
    return @[
        @[@"Invert", @"kernel vec4 effect(__sample pixel) {\n    return vec4(pixel.a - pixel.rgb, pixel.a);\n}\n"],
        @[@"Grayscale", @"kernel vec4 effect(__sample pixel) {\n    float y = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));\n    return vec4(vec3(y), pixel.a);\n}\n"],
        @[@"Sepia", @"kernel vec4 effect(__sample pixel) {\n    float r = dot(pixel.rgb, vec3(0.393, 0.769, 0.189));\n    float g = dot(pixel.rgb, vec3(0.349, 0.686, 0.168));\n    float b = dot(pixel.rgb, vec3(0.272, 0.534, 0.131));\n    return vec4(clamp(vec3(r, g, b), 0.0, 1.0), pixel.a);\n}\n"],
        @[@"Posterize", @"kernel vec4 effect(__sample pixel) {\n    vec3 c = floor(pixel.rgb * 5.0 + 0.5) / 5.0;\n    return vec4(c, pixel.a);\n}\n"],
        @[@"Black & white threshold", @"kernel vec4 effect(__sample pixel) {\n    float y = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));\n    return vec4(vec3(step(0.5 * pixel.a, y)), pixel.a);\n}\n"],
        @[@"Teal & orange grade", @"kernel vec4 effect(__sample pixel) {\n    float y = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));\n    vec3 shadow = vec3(0.0, 0.35, 0.45);\n    vec3 light = vec3(1.0, 0.65, 0.35);\n    vec3 graded = mix(shadow, light, y) * 0.5 + pixel.rgb * 0.5;\n    return vec4(graded * pixel.a, pixel.a);\n}\n"],
        @[@"Scanlines", @"kernel vec4 effect(__sample pixel) {\n    float line = mod(destCoord().y, 4.0) < 2.0 ? 1.0 : 0.7;\n    return vec4(pixel.rgb * line, pixel.a);\n}\n"],
    ];
}

@implementation VPShaderEditorWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 700) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Shader & Filter Editor";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(900, 600);
    window.frameAutosaveName = @"VPShaderEditorWindow";
    if ((self = [super initWithWindow:window])) {
        _chain = [NSMutableArray array];
        window.delegate = self;
        _context = [CIContext contextWithOptions:nil];
        [self buildUI];
        [window center];
        [self reloadFromLiveState];
    }
    return self;
}

- (void)dealloc { [self.liveTimer invalidate]; [self detachOutput]; }

#pragma mark - UI

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame; field.font = bold ? [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:12];
    [self.window.contentView addSubview:field];
    return field;
}

- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame mask:(NSAutoresizingMaskOptions)mask {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame; button.autoresizingMask = mask; button.controlSize = NSControlSizeSmall; button.font = [NSFont systemFontOfSize:12];
    [self.window.contentView addSubview:button];
    return button;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    CGFloat H = 700, leftW = 520;

    [self label:@"SHADER — Core Image color kernel" frame:NSMakeRect(20, H - 34, 300, 18) bold:YES].autoresizingMask = NSViewMinYMargin;
    self.templates = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(leftW - 190, H - 40, 190, 26) pullsDown:NO];
    [self.templates addItemWithTitle:@"Insert template…"];
    for (NSArray *t in Templates()) [self.templates addItemWithTitle:t[0]];
    self.templates.target = self; self.templates.action = @selector(templateChosen:); self.templates.autoresizingMask = NSViewMinYMargin;
    self.templates.controlSize = NSControlSizeSmall; [content addSubview:self.templates];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 330, leftW - 20, H - 330 - 50)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder; scroll.autoresizingMask = NSViewHeightSizable | NSViewMinYMargin;
    self.source = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.source.richText = NO; self.source.automaticQuoteSubstitutionEnabled = NO; self.source.automaticDashSubstitutionEnabled = NO; self.source.automaticTextReplacementEnabled = NO;
    self.source.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.source.autoresizingMask = NSViewWidthSizable; self.source.delegate = self;
    self.source.allowsUndo = YES;
    scroll.documentView = self.source; [content addSubview:scroll];

    self.status = [NSTextField wrappingLabelWithString:@""];
    self.status.frame = NSMakeRect(20, 296, leftW - 20, 28); self.status.font = [NSFont systemFontOfSize:11]; self.status.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.status];

    [self label:@"FILTER CHAIN — applied after the shader, in order" frame:NSMakeRect(20, 270, 420, 18) bold:YES].autoresizingMask = NSViewMaxYMargin;
    NSScrollView *chainScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 120, leftW - 20, 142)];
    chainScroll.hasVerticalScroller = YES; chainScroll.borderType = NSBezelBorder; chainScroll.autoresizingMask = NSViewMaxYMargin;
    self.chainTable = [[NSTableView alloc] initWithFrame:chainScroll.bounds];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"spec"]; column.title = @"Filter (name:amount)"; column.width = 480;
    [self.chainTable addTableColumn:column];
    self.chainTable.dataSource = self; self.chainTable.delegate = self; self.chainTable.rowHeight = 22;
    chainScroll.documentView = self.chainTable; [content addSubview:chainScroll];

    self.effectPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 86, 150, 26) pullsDown:NO];
    for (NSString *name in [VPEffectPipeline availableEffects]) if (![name isEqual:@"none"]) [self.effectPopup addItemWithTitle:name];
    self.effectPopup.target = self; self.effectPopup.action = @selector(effectControlChanged:); self.effectPopup.autoresizingMask = NSViewMaxYMargin;
    self.effectPopup.controlSize = NSControlSizeSmall; [content addSubview:self.effectPopup];
    self.amountSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(effectControlChanged:)];
    self.amountSlider.frame = NSMakeRect(180, 90, 230, 20); self.amountSlider.autoresizingMask = NSViewMaxYMargin; [content addSubview:self.amountSlider];
    self.amountLabel = [self label:@"" frame:NSMakeRect(416, 90, 60, 18) bold:NO]; self.amountLabel.autoresizingMask = NSViewMaxYMargin;
    [self button:@"Add" action:@selector(addFilter:) frame:NSMakeRect(20, 54, 60, 26) mask:NSViewMaxYMargin];
    [self button:@"Remove" action:@selector(removeFilter:) frame:NSMakeRect(86, 54, 70, 26) mask:NSViewMaxYMargin];
    [self button:@"Up" action:@selector(moveFilterUp:) frame:NSMakeRect(162, 54, 46, 26) mask:NSViewMaxYMargin];
    [self button:@"Down" action:@selector(moveFilterDown:) frame:NSMakeRect(214, 54, 56, 26) mask:NSViewMaxYMargin];
    [self syncAmountSlider];

    // Right side: preview.
    CGFloat px = leftW + 30, pw = 1100 - px - 20;
    [self label:@"PREVIEW" frame:NSMakeRect(px, H - 34, 100, 18) bold:YES].autoresizingMask = NSViewMinYMargin;
    self.sourceChoice = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(px + pw - 220, H - 40, 220, 26) pullsDown:NO];
    [self.sourceChoice addItemsWithTitles:@[@"Playing video (live frame)", @"Test pattern"]];
    self.sourceChoice.target = self; self.sourceChoice.action = @selector(sourceChanged:); self.sourceChoice.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.sourceChoice.controlSize = NSControlSizeSmall; [content addSubview:self.sourceChoice];
    self.preview = [[NSImageView alloc] initWithFrame:NSMakeRect(px, 150, pw, H - 150 - 50)];
    self.preview.imageScaling = NSImageScaleProportionallyUpOrDown; self.preview.wantsLayer = YES;
    self.preview.layer.backgroundColor = NSColor.blackColor.CGColor; self.preview.layer.cornerRadius = 6;
    self.preview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.preview.accessibilityLabel = @"Effect preview";
    [content addSubview:self.preview];
    self.includeAdjustments = [NSButton checkboxWithTitle:@"Include post-processing sliders in preview" target:self action:@selector(sourceChanged:)];
    self.includeAdjustments.frame = NSMakeRect(px, 118, pw, 22); self.includeAdjustments.autoresizingMask = NSViewMaxYMargin; [content addSubview:self.includeAdjustments];
    NSTextField *help = [NSTextField wrappingLabelWithString:@"Write a color kernel and the preview updates as you type. Filters below the shader are chained in order. Apply to Player to see it on the playing video; Save Preset stores both for the configuration builder."];
    help.frame = NSMakeRect(px, 56, pw, 56); help.font = [NSFont systemFontOfSize:11]; help.textColor = NSColor.secondaryLabelColor; help.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:help];

    CGFloat bx = px;
    [self button:@"Apply to Player" action:@selector(applyToPlayer:) frame:NSMakeRect(bx, 16, 120, 30) mask:NSViewMaxYMargin].keyEquivalent = @"\r";
    [self button:@"Revert" action:@selector(revert:) frame:NSMakeRect(bx + 128, 16, 70, 30) mask:NSViewMaxYMargin];
    [self button:@"Clear Effect" action:@selector(clearEffect:) frame:NSMakeRect(bx + 204, 16, 94, 30) mask:NSViewMaxYMargin];
    [self button:@"Load…" action:@selector(loadPreset:) frame:NSMakeRect(bx + 306, 16, 64, 30) mask:NSViewMaxYMargin];
    [self button:@"Save Preset…" action:@selector(savePreset:) frame:NSMakeRect(bx + 376, 16, 100, 30) mask:NSViewMaxYMargin];
    [self button:@"Save Shader…" action:@selector(saveShader:) frame:NSMakeRect(bx + 482, 16, 100, 30) mask:NSViewMaxYMargin];
}

#pragma mark - State

- (void)reloadFromLiveState {
    VPPostProcessing *pp = VPPostProcessing.shared;
    self.source.string = pp.shaderSource.length ? pp.shaderSource : [Templates().firstObject lastObject];
    [self.chain setArray:pp.filterChain ?: @[]];
    [self.chainTable reloadData];
    [self recompile];
    [self liveTick];
    [self refreshPreview];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self liveTick];
    [self startLiveTimer];
    [self refreshPreview];
}

- (void)windowWillClose:(NSNotification *)notification { [self.liveTimer invalidate]; self.liveTimer = nil; [self detachOutput]; }

#pragma mark - Compile and preview

- (void)textDidChange:(NSNotification *)notification {
    [self.debounce invalidate];
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) { [self recompile]; [self refreshPreview]; }];
}

- (void)recompile {
    NSString *text = [self.source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) { self.workingKernel = nil; [self setStatus:@"No shader: only the filter chain is used." good:YES]; return; }
    NSError *error = nil;
    self.workingKernel = [VPEffectPipeline compileKernelSource:self.source.string error:&error];
    [self setStatus:self.workingKernel ? @"Shader compiled." : error.localizedDescription good:self.workingKernel != nil];
}

- (void)setStatus:(NSString *)text good:(BOOL)good {
    self.status.stringValue = text;
    self.status.textColor = good ? NSColor.systemGreenColor : NSColor.systemRedColor;
}

- (CIImage *)generateTestPattern {
    if (_testPattern) return _testPattern;
    CGSize size = CGSizeMake(960, 540);
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSGradient *sky = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.10 green:0.20 blue:0.45 alpha:1] endingColor:[NSColor colorWithSRGBRed:0.95 green:0.60 blue:0.35 alpha:1]];
        [sky drawInRect:rect angle:90];
        NSArray *bars = @[NSColor.whiteColor, NSColor.yellowColor, NSColor.cyanColor, NSColor.greenColor, NSColor.magentaColor, NSColor.redColor, NSColor.blueColor, NSColor.blackColor];
        for (NSUInteger i = 0; i < bars.count; i++) { [bars[i] setFill]; NSRectFill(NSMakeRect(i * rect.size.width / bars.count, 0, rect.size.width / bars.count, 110)); }
        NSGradient *ramp = [[NSGradient alloc] initWithStartingColor:NSColor.blackColor endingColor:NSColor.whiteColor];
        [ramp drawInRect:NSMakeRect(0, 110, rect.size.width, 36) angle:0];
        [[NSColor colorWithWhite:1 alpha:0.9] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(640, 260, 200, 200)] fill];
        [[NSColor colorWithSRGBRed:0.1 green:0.1 blue:0.15 alpha:1] setFill];
        NSBezierPath *hills = [NSBezierPath bezierPath];
        [hills moveToPoint:NSMakePoint(0, 146)]; [hills curveToPoint:NSMakePoint(520, 200) controlPoint1:NSMakePoint(120, 330) controlPoint2:NSMakePoint(380, 120)];
        [hills curveToPoint:NSMakePoint(960, 146) controlPoint1:NSMakePoint(700, 290) controlPoint2:NSMakePoint(860, 180)]; [hills closePath]; [hills fill];
        NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:64 weight:NSFontWeightHeavy], NSForegroundColorAttributeName:NSColor.whiteColor};
        [@"Mac Video Player" drawAtPoint:NSMakePoint(36, 300) withAttributes:attrs];
        return YES;
    }];
    CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
    _testPattern = [CIImage imageWithCGImage:cg];
    return _testPattern;
}

- (void)sourceChanged:(id)sender { [self startLiveTimer]; [self refreshPreview]; }

- (void)refreshPreview {
    self.previewDirty = YES;
    [self renderPreviewIfNeeded];
}

- (void)renderPreviewIfNeeded {
    if (!self.previewDirty) return;
    self.previewDirty = NO;
    BOOL useLive = self.sourceChoice.indexOfSelectedItem == 0;
    CIImage *source = useLive && self.liveFrame ? self.liveFrame : [self generateTestPattern];
    CGRect extent = source.extent;
    CGFloat scale = MIN(1, 720.0 / extent.size.width);
    CIImage *image = scale < 1 ? [source imageByApplyingFilter:@"CILanczosScaleTransform" withInputParameters:@{kCIInputScaleKey:@(scale), kCIInputAspectRatioKey:@1}] : source;
    CGRect box = image.extent;
    if (self.workingKernel) image = [self.workingKernel applyWithExtent:box arguments:@[image]] ?: image;
    for (NSString *spec in self.chain) image = [VPEffectPipeline image:image withEffectSpec:spec];
    if (self.includeAdjustments.state == NSControlStateValueOn) image = [VPPostProcessing.shared adjustImage:image];
    CGImageRef cg = [self.context createCGImage:image fromRect:box];
    if (!cg) return;
    self.preview.image = [[NSImage alloc] initWithCGImage:cg size:box.size];
    CGImageRelease(cg);
}

#pragma mark - Live frames

- (void)detachOutput {
    if (self.output) [self.outputItem removeOutput:self.output];
    self.output = nil; self.outputItem = nil;
}

- (void)startLiveTimer {
    [self.liveTimer invalidate]; self.liveTimer = nil;
    if (self.sourceChoice.indexOfSelectedItem != 0) return;
    __weak typeof(self) weakSelf = self;
    self.liveTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15 repeats:YES block:^(NSTimer *timer) { [weakSelf liveTick]; }];
}

- (void)liveTick {
    CIImage *provided = self.imageProvider ? self.imageProvider() : nil;
    if (provided) {
        self.liveFrame = provided;
        self.previewDirty = YES;
    } else {
        AVPlayerItem *item = self.itemProvider ? self.itemProvider() : nil;
        if (item != self.outputItem) {
            [self detachOutput];
            if (item) {
                self.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
                [item addOutput:self.output]; self.outputItem = item;
            } else self.liveFrame = nil;
            self.previewDirty = YES;
        }
        if (self.output) {
            CMTime t = [self.output itemTimeForHostTime:CACurrentMediaTime()];
            if ([self.output hasNewPixelBufferForItemTime:t]) {
                CVPixelBufferRef buffer = [self.output copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
                if (buffer) { self.liveFrame = [CIImage imageWithCVPixelBuffer:buffer]; CVPixelBufferRelease(buffer); self.previewDirty = YES; }
            }
        }
    }
    [self renderPreviewIfNeeded];
}

#pragma mark - Templates and chain

- (void)templateChosen:(NSPopUpButton *)sender {
    NSInteger index = sender.indexOfSelectedItem - 1;
    if (index >= 0) { self.source.string = Templates()[index][1]; [self recompile]; [self refreshPreview]; }
    [sender selectItemAtIndex:0];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.chain.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row { return self.chain[row]; }
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSString *spec = [value description];
    if ([VPEffectPipeline applyEffect:spec error:nil]) { self.chain[row] = spec; [self refreshPreview]; }
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0) return;
    NSArray *parts = [self.chain[row] componentsSeparatedByString:@":"];
    [self.effectPopup selectItemWithTitle:parts.firstObject];
    [self syncAmountSlider];
    if (parts.count > 1) self.amountSlider.doubleValue = [parts[1] doubleValue];
    [self updateAmountLabel];
}

- (void)syncAmountSlider {
    NSDictionary *info = [VPEffectPipeline amountInfoForEffect:self.effectPopup.titleOfSelectedItem];
    self.amountSlider.enabled = info != nil;
    if (info) { self.amountSlider.minValue = [info[@"min"] doubleValue]; self.amountSlider.maxValue = [info[@"max"] doubleValue]; self.amountSlider.doubleValue = [info[@"default"] doubleValue]; }
    [self updateAmountLabel];
}
- (void)updateAmountLabel { self.amountLabel.stringValue = self.amountSlider.enabled ? [NSString stringWithFormat:@"%.2f", self.amountSlider.doubleValue] : @"—"; }

- (NSString *)currentSpec {
    NSString *name = self.effectPopup.titleOfSelectedItem;
    return self.amountSlider.enabled ? [NSString stringWithFormat:@"%@:%.3g", name, self.amountSlider.doubleValue] : name;
}

- (void)effectControlChanged:(id)sender {
    if (sender == self.effectPopup) [self syncAmountSlider]; else [self updateAmountLabel];
    NSInteger row = self.chainTable.selectedRow;
    if (row >= 0) { self.chain[row] = [self currentSpec]; [self.chainTable reloadData]; [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; }
    [self refreshPreview];
}
- (void)addFilter:(id)sender {
    [self.chain addObject:[self currentSpec]];
    [self.chainTable reloadData];
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:self.chain.count - 1] byExtendingSelection:NO];
    [self refreshPreview];
}
- (void)removeFilter:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0) return;
    [self.chain removeObjectAtIndex:row]; [self.chainTable reloadData]; [self refreshPreview];
}
- (void)moveFilter:(NSInteger)direction {
    NSInteger row = self.chainTable.selectedRow, next = row + direction;
    if (row < 0 || next < 0 || next >= (NSInteger)self.chain.count) return;
    [self.chain exchangeObjectAtIndex:row withObjectAtIndex:next]; [self.chainTable reloadData];
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
    [self refreshPreview];
}
- (void)moveFilterUp:(id)sender { [self moveFilter:-1]; }
- (void)moveFilterDown:(id)sender { [self moveFilter:1]; }

#pragma mark - Apply, files

- (void)applyToPlayer:(id)sender {
    NSError *error = nil;
    if (![VPPostProcessing.shared installShaderSource:self.source.string error:&error]) { [self setStatus:error.localizedDescription good:NO]; return; }
    VPPostProcessing.shared.filterChain = [self.chain copy];
    [VPPostProcessing.shared changed];
    [self setStatus:@"Applied to the player." good:YES];
    if (self.didApply) self.didApply();
}
- (void)revert:(id)sender { [self reloadFromLiveState]; }
- (void)clearEffect:(id)sender {
    [VPPostProcessing.shared installShaderSource:@"" error:nil];
    VPPostProcessing.shared.filterChain = @[];
    [VPPostProcessing.shared changed];
    [self.chain removeAllObjects]; [self.chainTable reloadData];
    self.source.string = @""; [self recompile]; [self refreshPreview];
    if (self.didApply) self.didApply();
}

- (void)savePreset:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"effect-preset.json";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSDictionary *preset = @{@"shaderSource":self.source.string ?: @"", @"filterChain":self.chain};
        NSData *data = [NSJSONSerialization dataWithJSONObject:preset options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        NSError *error = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) [self setStatus:error.localizedDescription good:NO];
        else [self setStatus:[@"Saved " stringByAppendingString:panel.URL.lastPathComponent] good:YES];
    }];
}
- (void)saveShader:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"effect.cikernel";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.source.string writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) [self setStatus:error.localizedDescription good:NO];
        else [self setStatus:[NSString stringWithFormat:@"Saved %@. Use it with: vplay play FILE --shader %@", panel.URL.lastPathComponent, panel.URL.path] good:YES];
    }];
}
- (void)loadPreset:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSData *data = [NSData dataWithContentsOfURL:panel.URL];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:NSDictionary.class]) {
            self.source.string = [json[@"shaderSource"] isKindOfClass:NSString.class] ? json[@"shaderSource"] : @"";
            [self.chain setArray:[json[@"filterChain"] isKindOfClass:NSArray.class] ? json[@"filterChain"] : @[]];
        } else {
            NSString *text = [NSString stringWithContentsOfURL:panel.URL encoding:NSUTF8StringEncoding error:nil];
            if (!text) { [self setStatus:@"That file could not be read." good:NO]; return; }
            self.source.string = text;
        }
        [self.chainTable reloadData]; [self recompile]; [self refreshPreview];
    }];
}
@end
