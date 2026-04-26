#import "VPAudioOutputWindowController.h"
#import "VPAudioDeviceManager.h"

@interface VPAudioOutputWindowController ()
@property (nonatomic, strong) NSPopUpButton *devices;
@property (nonatomic, strong) NSPopUpButton *rates;
@property (nonatomic, strong) NSPopUpButton *layouts;
@property (nonatomic, strong) NSTextField *info;
@property (nonatomic, copy) NSArray<NSDictionary *> *outputDevices;
@end

@implementation VPAudioOutputWindowController

static NSArray<NSArray *> *RateChoices(void) {
    return @[@[@"Auto — leave the device as it is", @"auto"], @[@"44.1 kHz  (CD)", @"44100"], @[@"48 kHz  (video)", @"48000"], @[@"88.2 kHz", @"88200"], @[@"96 kHz", @"96000"],
             @[@"176.4 kHz", @"176400"], @[@"192 kHz", @"192000"], @[@"352.8 kHz", @"352800"], @[@"384 kHz", @"384000"], @[@"Maximum the device supports", @"max"]];
}
static NSArray<NSArray *> *LayoutChoices(void) {
    return @[@[@"Auto — as recorded", @"auto"], @[@"Mono (1.0)", @"mono"], @[@"Stereo (2.0)", @"stereo"], @[@"2.1  (stereo + subwoofer)", @"2.1"], @[@"4.0  (quad)", @"4.0"],
             @[@"4.1  (quad + subwoofer)", @"4.1"], @[@"5.0  (surround, no subwoofer)", @"5.0"], @[@"5.1  (surround + subwoofer)", @"5.1"], @[@"7.1  (full surround)", @"7.1"]];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 430) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Audio Output";
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) { [self buildUI]; [window center]; }
    return self;
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame; field.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [self.window.contentView addSubview:field];
    return field;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    NSTextField *intro = [NSTextField wrappingLabelWithString:@"Upsample the sound to a higher sample rate and choose how many speakers vplay should feed. Changes apply to the next sound and, for channel layouts, restart the playing media at the same position."];
    intro.frame = NSMakeRect(20, 366, 520, 50); intro.textColor = NSColor.secondaryLabelColor; intro.font = [NSFont systemFontOfSize:12];
    [content addSubview:intro];

    [self label:@"Output device" frame:NSMakeRect(20, 334, 160, 20)];
    self.devices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 328, 350, 28) pullsDown:NO];
    self.devices.target = self; self.devices.action = @selector(deviceChanged:);
    [content addSubview:self.devices];

    [self label:@"Sample rate" frame:NSMakeRect(20, 290, 160, 20)];
    self.rates = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 284, 350, 28) pullsDown:NO];
    for (NSArray *choice in RateChoices()) [self.rates addItemWithTitle:choice[0]];
    [content addSubview:self.rates];

    [self label:@"Speakers (channels)" frame:NSMakeRect(20, 246, 160, 20)];
    self.layouts = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 240, 350, 28) pullsDown:NO];
    for (NSArray *choice in LayoutChoices()) [self.layouts addItemWithTitle:choice[0]];
    [content addSubview:self.layouts];

    self.info = [NSTextField wrappingLabelWithString:@""];
    self.info.frame = NSMakeRect(20, 84, 520, 140); self.info.font = [NSFont systemFontOfSize:12]; self.info.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.info];

    NSButton *revert = [NSButton buttonWithTitle:@"Revert" target:self action:@selector(revert:)];
    revert.frame = NSMakeRect(20, 20, 90, 32); [content addSubview:revert];
    NSButton *apply = [NSButton buttonWithTitle:@"Apply" target:self action:@selector(apply:)];
    apply.frame = NSMakeRect(440, 20, 100, 32); apply.keyEquivalent = @"\r"; [content addSubview:apply];
}

- (void)reload {
    NSMutableArray *outputs = [NSMutableArray array];
    for (NSDictionary *device in [VPAudioDeviceManager listDevices]) if ([device[@"type"] isEqual:@"output"]) [outputs addObject:device];
    self.outputDevices = outputs;
    [self.devices removeAllItems];
    [self.devices addItemWithTitle:@"System default output"];
    for (NSDictionary *device in outputs) [self.devices addItemWithTitle:device[@"name"]];
    NSDictionary *current = self.currentSettings ? self.currentSettings() : @{};
    NSString *uid = current[@"audioDevice"];
    for (NSUInteger i = 0; i < outputs.count; i++) if ([outputs[i][@"uid"] isEqual:uid]) [self.devices selectItemAtIndex:i + 1];
    for (NSUInteger i = 0; i < RateChoices().count; i++) if ([RateChoices()[i][1] isEqual:current[@"audioSampleRate"] ?: @"auto"]) [self.rates selectItemAtIndex:i];
    NSString *layout = current[@"audioLayout"] ?: @"auto";
    if ([layout isEqual:@"2.0"]) layout = @"stereo";
    for (NSUInteger i = 0; i < LayoutChoices().count; i++) if ([LayoutChoices()[i][1] isEqual:layout]) [self.layouts selectItemAtIndex:i];
    [self refreshDeviceInfo];
}

- (NSString *)selectedDeviceUID {
    NSInteger index = self.devices.indexOfSelectedItem;
    return index > 0 ? self.outputDevices[index - 1][@"uid"] : nil;
}

- (void)refreshDeviceInfo {
    NSString *uid = [self selectedDeviceUID];
    NSArray<NSNumber *> *supported = [VPAudioDeviceManager supportedSampleRatesForDeviceUID:uid];
    double maximum = [VPAudioDeviceManager maximumSampleRateForDeviceUID:uid];
    for (NSUInteger i = 0; i < RateChoices().count; i++) {
        NSString *value = RateChoices()[i][1];
        BOOL ok = [value isEqual:@"auto"] || [value isEqual:@"max"] || [supported containsObject:@(value.integerValue)];
        NSMenuItem *item = [self.rates itemAtIndex:i];
        item.enabled = ok;
        item.title = ok ? RateChoices()[i][0] : [RateChoices()[i][0] stringByAppendingString:@" — not supported by this device"];
    }
    NSMutableString *text = [NSMutableString string];
    if (maximum > 0) [text appendFormat:@"This device runs at up to %.1f kHz. ", maximum / 1000];
    [text appendString:@"Higher sample rates are produced by resampling: they do not add detail that is missing from the recording, but they can avoid extra conversion inside the device and keep a consistent output format.\n\n"];
    [text appendString:@"Channel layouts: choosing more speakers than the recording has synthesizes them (center, subwoofer and surround channels are derived from the stereo mix, as an upmix). Choosing fewer speakers mixes the extra channels down. Layouts other than Auto make vplay convert the media with FFmpeg, so playback may restart briefly."];
    self.info.stringValue = text;
}

- (void)deviceChanged:(id)sender { [self refreshDeviceInfo]; }

- (void)apply:(id)sender {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    settings[@"audioSampleRate"] = RateChoices()[self.rates.indexOfSelectedItem][1];
    settings[@"audioLayout"] = LayoutChoices()[self.layouts.indexOfSelectedItem][1];
    NSString *uid = [self selectedDeviceUID];
    settings[@"audioDevice"] = uid ?: @"";
    if (self.applyHandler) self.applyHandler(settings);
}

- (void)revert:(id)sender { [self reload]; }
@end
