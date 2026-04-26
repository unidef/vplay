#import "VPPostProcessingWindowController.h"
#import "VPPostProcessing.h"

@interface VPPostProcessingWindowController ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSSlider *> *sliders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *values;
@property (nonatomic, strong) NSButton *enabledBox;
@property (nonatomic, strong) NSButton *invertBox;
@property (nonatomic, strong) NSPopUpButton *presets;
@property (nonatomic, strong) NSPopUpButton *levelPopup;
@property (nonatomic, strong) NSSlider *levelSlider;
@property (nonatomic, strong) NSTextField *levelValueLabel;
@end

@implementation VPPostProcessingWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 470, 630) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Post-Processing";
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) {
        _sliders = [NSMutableDictionary dictionary]; _values = [NSMutableDictionary dictionary];
        [self buildUI];
        [window center];
        [self refresh];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(externalChange:) name:VPPostProcessingDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)buildUI {
    NSView *content = self.window.contentView;
    CGFloat top = 630;
    NSTextField *intro = [NSTextField wrappingLabelWithString:@"Adjust the picture while it plays. Changes apply instantly, including to DVD and Blu-ray video."];
    intro.frame = NSMakeRect(20, top - 56, 430, 40); intro.textColor = NSColor.secondaryLabelColor; intro.font = [NSFont systemFontOfSize:12];
    [content addSubview:intro];

    self.enabledBox = [NSButton checkboxWithTitle:@"Enable post-processing" target:self action:@selector(toggled:)];
    self.enabledBox.frame = NSMakeRect(20, top - 84, 200, 22); [content addSubview:self.enabledBox];
    self.invertBox = [NSButton checkboxWithTitle:@"Invert colors" target:self action:@selector(toggled:)];
    self.invertBox.frame = NSMakeRect(250, top - 84, 160, 22); [content addSubview:self.invertBox];

    NSTextField *look = [NSTextField labelWithString:@"Look:"];
    look.frame = NSMakeRect(20, top - 116, 40, 20); [content addSubview:look];
    self.presets = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, top - 120, 200, 26) pullsDown:NO];
    [self.presets addItemWithTitle:@"Choose a look…"];
    [self.presets addItemsWithTitles:[VPPostProcessing presetNames]];
    self.presets.target = self; self.presets.action = @selector(presetChosen:);
    [content addSubview:self.presets];
    NSButton *reset = [NSButton buttonWithTitle:@"Reset All" target:self action:@selector(resetAll:)];
    reset.frame = NSMakeRect(280, top - 120, 90, 26); [content addSubview:reset];

    // Master Post-Processing Level
    NSTextField *levelLabel = [NSTextField labelWithString:@"Level:"];
    levelLabel.frame = NSMakeRect(20, top - 148, 40, 20); [content addSubview:levelLabel];
    self.levelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, top - 152, 130, 26) pullsDown:NO];
    [self.levelPopup addItemsWithTitles:[VPPostProcessing levelNames]];
    self.levelPopup.target = self; self.levelPopup.action = @selector(levelChosen:);
    [content addSubview:self.levelPopup];

    self.levelSlider = [NSSlider sliderWithValue:1.0 minValue:0.0 maxValue:1.0 target:self action:@selector(levelSliderMoved:)];
    self.levelSlider.frame = NSMakeRect(200, top - 150, 180, 20);
    [content addSubview:self.levelSlider];

    self.levelValueLabel = [NSTextField labelWithString:@"100%"];
    self.levelValueLabel.frame = NSMakeRect(384, top - 150, 64, 20);
    self.levelValueLabel.alignment = NSTextAlignmentRight;
    self.levelValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [content addSubview:self.levelValueLabel];

    // key, title, min, max, default
    NSArray *rows = @[
        @[@"brightness", @"Brightness", @-1, @1, @0], @[@"contrast", @"Contrast", @0, @2, @1], @[@"saturation", @"Saturation", @0, @3, @1],
        @[@"hue", @"Hue (degrees)", @-180, @180, @0], @[@"gamma", @"Gamma", @0.3, @3, @1], @[@"exposure", @"Exposure (stops)", @-2, @2, @0],
        @[@"warmth", @"Warmth", @-1, @1, @0], @[@"sharpness", @"Sharpness", @0, @2, @0], @[@"noiseReduction", @"Noise reduction", @0, @1, @0],
        @[@"blur", @"Blur", @0, @20, @0], @[@"vignette", @"Vignette", @0, @2, @0]];
    CGFloat y = top - 188;
    for (NSArray *row in rows) {
        NSTextField *label = [NSTextField labelWithString:row[1]];
        label.frame = NSMakeRect(20, y, 120, 20); [content addSubview:label];
        NSSlider *slider = [NSSlider sliderWithValue:[row[4] doubleValue] minValue:[row[2] doubleValue] maxValue:[row[3] doubleValue] target:self action:@selector(sliderMoved:)];
        slider.frame = NSMakeRect(144, y, 230, 20); slider.identifier = row[0]; slider.accessibilityLabel = row[1];
        [content addSubview:slider];
        NSTextField *value = [NSTextField labelWithString:@""];
        value.frame = NSMakeRect(384, y, 64, 20); value.alignment = NSTextAlignmentRight; value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        [content addSubview:value];
        self.sliders[row[0]] = slider; self.values[row[0]] = value;
        y -= 30;
    }
    NSButton *editor = [NSButton buttonWithTitle:@"Shader & Filter Editor…" target:self action:@selector(openEditor:)];
    editor.frame = NSMakeRect(20, 20, 190, 30); [content addSubview:editor];
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self.window action:@selector(performClose:)];
    done.frame = NSMakeRect(370, 20, 80, 30); done.keyEquivalent = @"\r"; [content addSubview:done];
}

- (void)refresh {
    VPPostProcessing *pp = VPPostProcessing.shared;
    self.enabledBox.state = pp.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.invertBox.state = pp.invert ? NSControlStateValueOn : NSControlStateValueOff;
    self.levelSlider.doubleValue = pp.level;
    self.levelValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", pp.level * 100];
    [self.levelPopup selectItemWithTitle:[pp currentLevelName]];
    for (NSString *key in self.sliders) {
        double value = [[pp valueForKey:key] doubleValue];
        self.sliders[key].doubleValue = value;
        self.values[key].stringValue = [NSString stringWithFormat:@"%.2f", value];
    }
}

- (void)externalChange:(NSNotification *)note { [self refresh]; }

- (void)levelSliderMoved:(NSSlider *)slider {
    VPPostProcessing *pp = VPPostProcessing.shared;
    pp.level = slider.doubleValue;
    self.levelValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", slider.doubleValue * 100];
    [self.levelPopup selectItemWithTitle:[pp currentLevelName]];
    if (!pp.enabled && slider.doubleValue > 0.001) { pp.enabled = YES; self.enabledBox.state = NSControlStateValueOn; }
    [pp changed];
}

- (void)levelChosen:(NSPopUpButton *)sender {
    VPPostProcessing *pp = VPPostProcessing.shared;
    [pp setLevelNamed:sender.titleOfSelectedItem];
    self.levelSlider.doubleValue = pp.level;
    self.levelValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", pp.level * 100];
    [self refresh];
}

- (void)sliderMoved:(NSSlider *)slider {
    VPPostProcessing *pp = VPPostProcessing.shared;
    [pp setValue:@(slider.doubleValue) forKey:slider.identifier];
    self.values[slider.identifier].stringValue = [NSString stringWithFormat:@"%.2f", slider.doubleValue];
    if (!pp.enabled) { pp.enabled = YES; self.enabledBox.state = NSControlStateValueOn; }   // moving a slider means "I want to see this"
    [pp changed];
}
- (void)toggled:(id)sender {
    VPPostProcessing.shared.enabled = self.enabledBox.state == NSControlStateValueOn;
    VPPostProcessing.shared.invert = self.invertBox.state == NSControlStateValueOn;
    if (self.invertBox.state == NSControlStateValueOn && !VPPostProcessing.shared.enabled) { VPPostProcessing.shared.enabled = YES; self.enabledBox.state = NSControlStateValueOn; }
    [VPPostProcessing.shared changed];
}
- (void)presetChosen:(NSPopUpButton *)sender {
    if (sender.indexOfSelectedItem == 0) return;
    [VPPostProcessing.shared applyPresetNamed:sender.titleOfSelectedItem];
    [self refresh];
    [sender selectItemAtIndex:0];
}
- (void)resetAll:(id)sender {
    [VPPostProcessing.shared resetAdjustments];
    VPPostProcessing.shared.enabled = NO;
    [VPPostProcessing.shared changed];
    [self refresh];
}
- (void)openEditor:(id)sender { if (self.openShaderEditor) self.openShaderEditor(); }
@end
