#import "VPConfigManager.h"

@interface VPConfigManager ()
@end

@implementation VPConfigManager

+ (NSString *)defaultKeymapSpec {
    return @"space=pause,right=seek:5,left=seek:-5,up=vol:+0.05,down=vol:-0.05,f=fullscreen,m=mute";
}

+ (NSString *)defaultConfigPath {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[appSupport stringByAppendingPathComponent:@"vplay"] stringByAppendingPathComponent:@"config.json"];
}

+ (instancetype)managerWithDefaultConfig {
    VPConfigManager *mgr = [VPConfigManager new];
    [mgr loadDefaultConfig:nil];
    return mgr;
}

- (instancetype)init {
    if ((self = [super init])) {
        _defaultVolume = 1.0f;
        _defaultRate = 1.0f;
        _playbackOptions = @{};
    }
    return self;
}

- (BOOL)loadFromPath:(NSString *)path error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:60 userInfo:@{NSLocalizedDescriptionKey:@"Config file not found."}];
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return NO;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!dict) return NO;
    return [self applyDictionary:dict error:error];
}

- (BOOL)loadDefaultConfig:(NSError **)error {
    NSString *path = [VPConfigManager defaultConfigPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [self loadFromPath:path error:error];
    }
    NSDictionary *dict = @{@"volume":@1.0, @"rate":@1.0, @"loop":@NO, @"mute":@NO, @"audioLayout":@"auto", @"audioSampleRate":@"auto", @"scaler":@"metal", @"fieldOrder":@"auto", @"deinterlace":@NO, @"inverseTelecine":@NO, @"upscale":@1, @"showFPS":@NO, @"visualizer":@NO, @"shuffle":@NO, @"showMetadata":@YES, @"repeat":@"off", @"visualizerStyle":@"bars", @"playbackBackend":@"auto", @"videoQualityPreset":@"Auto / Native (1:1 Direct)"};
    return [self applyDictionary:dict error:error];
}

- (BOOL)applyDictionary:(NSDictionary *)dict error:(NSError **)error {
    if (![dict isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:61 userInfo:@{NSLocalizedDescriptionKey:@"Invalid configuration: dictionary expected."}];
        return NO;
    }
    NSMutableDictionary *normalized = [dict mutableCopy];
    if (normalized[@"reverseTelecine"] && !normalized[@"inverseTelecine"]) {
        normalized[@"inverseTelecine"] = normalized[@"reverseTelecine"];
    }
    if (normalized[@"reverseTelecline"] && !normalized[@"inverseTelecine"]) {
        normalized[@"inverseTelecine"] = normalized[@"reverseTelecline"];
    }
    if (normalized[@"qualityPreset"] && !normalized[@"videoQualityPreset"]) {
        normalized[@"videoQualityPreset"] = normalized[@"qualityPreset"];
    }
    dict = normalized;

    NSArray *strings = @[@"backgroundImage", @"audioDevice", @"effect", @"keymap", @"lastBrowsedDirectory", @"shader", @"vf", @"af", @"audioLayout", @"audioSampleRate", @"scaler", @"fieldOrder", @"input", @"skin", @"playbackBackend", @"visualizerStyle", @"repeat", @"subtitle", @"videoQualityPreset", @"qualityPreset", @"postProcessingLevel"];
    BOOL valid = YES;
    for (NSString *key in strings) if (dict[key] && ![dict[key] isKindOfClass:NSString.class] && !(dict[key] == (id)kCFBooleanFalse || dict[key] == (id)kCFBooleanTrue)) {
        if ([key isEqualToString:@"postProcessingLevel"] && [dict[key] isKindOfClass:NSNumber.class]) continue;
        valid = NO;
    }
    for (NSString *key in @[@"volume", @"rate", @"loop", @"mute", @"ffmpeg", @"deinterlace", @"inverseTelecine", @"reverseTelecine", @"reverseTelecline", @"upscale", @"showFPS", @"visualizer", @"shuffle", @"showMetadata", @"intro", @"showControls"]) if (dict[key] && ![dict[key] isKindOfClass:NSNumber.class]) valid = NO;
    for (NSString *key in @[@"ffplayArguments", @"ffmpegArguments", @"playlist", @"hiddenHUDItems"]) {
        if (dict[key]) {
            if (![dict[key] isKindOfClass:NSArray.class]) valid = NO;
            else for (id arg in dict[key]) if (![arg isKindOfClass:NSString.class]) valid = NO;
        }
    }
    if ([dict[@"volume"] isKindOfClass:NSNumber.class] && ([dict[@"volume"] doubleValue] < 0 || [dict[@"volume"] doubleValue] > 1)) valid = NO;
    if ([dict[@"rate"] isKindOfClass:NSNumber.class] && [dict[@"rate"] doubleValue] <= 0) valid = NO;
    if (dict[@"audioLayout"] && ![@[@"auto", @"mono", @"stereo", @"2.0", @"2.1", @"4.0", @"4.1", @"5.0", @"5.1", @"7.1"] containsObject:dict[@"audioLayout"]]) valid = NO;
    if (dict[@"scaler"] && ![@[@"metal", @"lanczos"] containsObject:dict[@"scaler"]]) valid = NO;
    if (dict[@"fieldOrder"] && ![@[@"auto", @"tff", @"bff"] containsObject:dict[@"fieldOrder"]]) valid = NO;
    if ([dict[@"upscale"] isKindOfClass:NSNumber.class]) {
        double factor = [dict[@"upscale"] doubleValue];
        if (!isfinite(factor) || factor < 1 || factor > 4) valid = NO;
    }
    if ([dict[@"audioSampleRate"] isKindOfClass:NSString.class]) {
        NSString *rate = dict[@"audioSampleRate"];
        if (![@[@"auto", @"max"] containsObject:rate]) {
            NSScanner *scanner = [NSScanner scannerWithString:rate];
            scanner.charactersToBeSkipped = nil;
            long long hz = 0;
            if (![scanner scanLongLong:&hz] || !scanner.isAtEnd || hz <= 0 || hz > INT_MAX) valid = NO;
        }
    }
    if (valid && [dict[@"deinterlace"] boolValue] && [dict[@"inverseTelecine"] boolValue]) valid = NO;
    if (dict[@"repeat"] && ![@[@"off", @"all", @"one"] containsObject:dict[@"repeat"]]) valid = NO;
    if (dict[@"visualizerStyle"] && ![@[@"bars", @"mirror", @"ring", @"terrain3d", @"orbit3d"] containsObject:dict[@"visualizerStyle"]]) valid = NO;
    if (dict[@"audioFilters"] && ![dict[@"audioFilters"] isKindOfClass:NSArray.class]) valid = NO;
    if (dict[@"postProcessing"] && ![dict[@"postProcessing"] isKindOfClass:NSDictionary.class]) valid = NO;
    if (dict[@"playbackBackend"] && ![@[@"auto", @"native", @"prepared", @"ffplay"] containsObject:dict[@"playbackBackend"]]) valid = NO;
    if (dict[@"effectChain"]) {
        if (![dict[@"effectChain"] isKindOfClass:NSArray.class]) valid = NO;
        else for (id stage in dict[@"effectChain"]) {
            if (![stage isKindOfClass:NSDictionary.class] ||
                ![@[@"video", @"audio", @"effect", @"shader"] containsObject:stage[@"type"]] ||
                ![stage[@"value"] isKindOfClass:NSString.class] || ![stage[@"value"] length]) { valid = NO; break; }
        }
    }
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:61 userInfo:@{NSLocalizedDescriptionKey:@"Invalid configuration: check types, sample rate (auto/max/Hz string), upscale (1–4), scaler (metal/lanczos), and field order (auto/tff/bff). Choose either deinterlace or inverseTelecine."}];
        return NO;
    }
    self.backgroundImagePath = nil;
    self.audioDeviceUID = nil;
    self.effectSpec = nil;
    self.keymapSpec = nil;
    self.lastBrowsedDirectory = nil;
    self.defaultVolume = 1;
    self.defaultRate = 1;
    self.playbackOptions = [dict copy];
    if (dict[@"backgroundImage"]) self.backgroundImagePath = dict[@"backgroundImage"];
    if (dict[@"audioDevice"]) self.audioDeviceUID = dict[@"audioDevice"];
    if (dict[@"volume"]) self.defaultVolume = [dict[@"volume"] floatValue];
    if (dict[@"rate"]) self.defaultRate = [dict[@"rate"] floatValue];
    if (dict[@"effect"]) self.effectSpec = dict[@"effect"];
    if (dict[@"keymap"]) self.keymapSpec = dict[@"keymap"];
    if (dict[@"lastBrowsedDirectory"]) self.lastBrowsedDirectory = dict[@"lastBrowsedDirectory"];

    return YES;
}

- (BOOL)saveToPath:(NSString *)path error:(NSError **)error {
    // Ensure directory exists
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSDictionary *dict = [self toDictionary];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

- (BOOL)saveDefaults:(NSError **)error {
    return [self saveToPath:[VPConfigManager defaultConfigPath] error:error];
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [self.playbackOptions mutableCopy];
    if (self.backgroundImagePath) dict[@"backgroundImage"] = self.backgroundImagePath;
    if (self.audioDeviceUID) dict[@"audioDevice"] = self.audioDeviceUID;
    dict[@"volume"] = @(self.defaultVolume);
    dict[@"rate"] = @(self.defaultRate);
    if (self.effectSpec) dict[@"effect"] = self.effectSpec;
    if (self.keymapSpec) dict[@"keymap"] = self.keymapSpec;
    if (self.lastBrowsedDirectory) dict[@"lastBrowsedDirectory"] = self.lastBrowsedDirectory;
    return dict;
}
@end
