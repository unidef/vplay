#import "VPPostProcessing.h"
#import "VPEffectPipeline.h"

NSNotificationName const VPPostProcessingDidChangeNotification = @"VPPostProcessingDidChangeNotification";

@interface VPPostProcessing ()
@property (atomic, strong, nullable) CIColorKernel *shaderKernel;
@property (atomic) NSUInteger revision;
@end

@implementation VPPostProcessing

+ (instancetype)shared {
    static VPPostProcessing *shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [VPPostProcessing new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _filterChain = @[]; _shaderSource = @"";
        _level = 1.0;
        [self resetAdjustments];
        _enabled = NO;
    }
    return self;
}

- (void)resetAdjustments {
    self.level = 1.0;
    self.brightness = 0; self.contrast = 1; self.saturation = 1; self.hue = 0; self.gamma = 1; self.exposure = 0;
    self.warmth = 0; self.sharpness = 0; self.noiseReduction = 0; self.blur = 0; self.vignette = 0; self.invert = NO;
}

- (BOOL)adjustmentsAreNeutral {
    return self.level <= 0.001 || (self.brightness == 0 && self.contrast == 1 && self.saturation == 1 && self.hue == 0 && self.gamma == 1 &&
           self.exposure == 0 && self.warmth == 0 && self.sharpness == 0 && self.noiseReduction == 0 && self.blur == 0 &&
           self.vignette == 0 && !self.invert);
}

- (BOOL)isActive {
    if (self.level <= 0.001) return NO;
    return self.shaderKernel != nil || self.filterChain.count > 0 || (self.enabled && ![self adjustmentsAreNeutral]);
}

- (void)changed {
    self.revision += 1;
    if (NSThread.isMainThread) [NSNotificationCenter.defaultCenter postNotificationName:VPPostProcessingDidChangeNotification object:self];
    else dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:VPPostProcessingDidChangeNotification object:self]; });
}

- (BOOL)installShaderSource:(NSString *)source error:(NSError **)error {
    NSString *trimmed = [source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) { self.shaderSource = @""; self.shaderKernel = nil; [self changed]; return YES; }
    CIColorKernel *kernel = [VPEffectPipeline compileKernelSource:source error:error];
    if (!kernel) return NO;
    self.shaderSource = source; self.shaderKernel = kernel; [self changed];
    return YES;
}

#pragma mark - Rendering

static CIImage *Filter(CIImage *image, NSString *name, NSDictionary *parameters, CGRect extent) {
    CIImage *result = [[image imageByClampingToExtent] imageByApplyingFilter:name withInputParameters:parameters];
    return [result imageByCroppingToRect:extent] ?: image;
}

- (CIImage *)processImage:(CIImage *)source {
    if (!source || self.level <= 0.001) return source;
    CGRect extent = source.extent;
    CIImage *image = source;
    CIColorKernel *kernel = self.shaderKernel;
    if (kernel) image = [kernel applyWithExtent:extent arguments:@[image]] ?: image;
    for (NSString *spec in self.filterChain) image = [VPEffectPipeline image:image withEffectSpec:spec];
    image = [self adjustImage:image];
    if (self.level < 0.999 && image) {
        CIImage *blended = Filter(source, @"CIDissolveTransition", @{kCIInputTargetImageKey: image, kCIInputTimeKey: @(self.level)}, extent);
        return blended ?: image;
    }
    return image;
}

- (CIImage *)adjustImage:(CIImage *)source {
    if (!source || !self.enabled || self.level <= 0.001 || [self adjustmentsAreNeutral]) return source;
    CGRect extent = source.extent;
    CIImage *image = source;

    if (self.exposure != 0) image = Filter(image, @"CIExposureAdjust", @{kCIInputEVKey:@(self.exposure)}, extent);
    if (self.brightness != 0 || self.contrast != 1 || self.saturation != 1)
        image = Filter(image, @"CIColorControls", @{kCIInputBrightnessKey:@(self.brightness), kCIInputContrastKey:@(self.contrast), kCIInputSaturationKey:@(self.saturation)}, extent);
    if (self.gamma != 1) image = Filter(image, @"CIGammaAdjust", @{@"inputPower":@(self.gamma)}, extent);
    if (self.hue != 0) image = Filter(image, @"CIHueAdjust", @{kCIInputAngleKey:@(self.hue * M_PI / 180)}, extent);
    if (self.warmth != 0) {
        // Lowering the target white point makes the picture warmer.
        image = Filter(image, @"CITemperatureAndTint", @{@"inputNeutral":[CIVector vectorWithX:6500 Y:0], @"inputTargetNeutral":[CIVector vectorWithX:6500 - self.warmth * 2500 Y:0]}, extent);
    }
    if (self.noiseReduction > 0) image = Filter(image, @"CINoiseReduction", @{@"inputNoiseLevel":@(self.noiseReduction * 0.05), @"inputSharpness":@0.4}, extent);
    if (self.sharpness > 0) image = Filter(image, @"CISharpenLuminance", @{kCIInputSharpnessKey:@(self.sharpness)}, extent);
    if (self.blur > 0) image = Filter(image, @"CIGaussianBlur", @{kCIInputRadiusKey:@(self.blur)}, extent);
    if (self.vignette > 0) image = Filter(image, @"CIVignette", @{kCIInputIntensityKey:@(self.vignette), kCIInputRadiusKey:@(MAX(extent.size.width, extent.size.height) / 800.0 * 2)}, extent);
    if (self.invert) image = Filter(image, @"CIColorInvert", @{}, extent);
    return image;
}

#pragma mark - Post-Processing Levels

+ (NSArray<NSString *> *)levelNames {
    return @[@"Off (0%)", @"Low (25%)", @"Medium (50%)", @"High (75%)", @"Maximum (100%)"];
}

+ (double)factorForLevelNamed:(NSString *)name {
    if (!name.length) return 1.0;
    if ([name containsString:@"0%"] || [name localizedCaseInsensitiveContainsString:@"off"]) return 0.0;
    if ([name containsString:@"25%"] || [name localizedCaseInsensitiveContainsString:@"low"]) return 0.25;
    if ([name containsString:@"50%"] || [name localizedCaseInsensitiveContainsString:@"medium"]) return 0.50;
    if ([name containsString:@"75%"] || [name localizedCaseInsensitiveContainsString:@"high"]) return 0.75;
    return 1.0;
}

- (void)setLevelNamed:(NSString *)name {
    self.level = [VPPostProcessing factorForLevelNamed:name];
    if (self.level > 0.001 && !self.enabled) self.enabled = YES;
    [self changed];
}

- (NSString *)currentLevelName {
    if (self.level <= 0.001) return @"Off (0%)";
    if (fabs(self.level - 0.25) < 0.12) return @"Low (25%)";
    if (fabs(self.level - 0.50) < 0.12) return @"Medium (50%)";
    if (fabs(self.level - 0.75) < 0.12) return @"High (75%)";
    return @"Maximum (100%)";
}

#pragma mark - Presets

+ (NSDictionary<NSString *, NSDictionary *> *)presets {
    return @{
        @"Cinema":        @{@"contrast":@1.15, @"saturation":@0.9, @"warmth":@0.15, @"vignette":@0.5, @"gamma":@1.05},
        @"Vivid":         @{@"contrast":@1.2, @"saturation":@1.5, @"sharpness":@0.4},
        @"Noir":          @{@"contrast":@1.4, @"saturation":@0, @"vignette":@0.8, @"brightness":@-0.05},
        @"Warm Sunset":   @{@"warmth":@0.6, @"saturation":@1.2, @"exposure":@0.1},
        @"Cool Night":    @{@"warmth":@-0.5, @"exposure":@-0.2, @"contrast":@1.1, @"saturation":@0.9},
        @"Clean & Sharp": @{@"sharpness":@0.9, @"noiseReduction":@0.4, @"contrast":@1.05},
        @"Soft Dream":    @{@"blur":@2, @"exposure":@0.2, @"saturation":@1.1, @"vignette":@0.4},
    };
}
+ (NSArray<NSString *> *)presetNames { return [[self presets].allKeys sortedArrayUsingSelector:@selector(compare:)]; }

- (void)applyPresetNamed:(NSString *)name {
    NSDictionary *preset = [VPPostProcessing presets][name];
    if (!preset) return;
    [self resetAdjustments];
    for (NSString *key in preset) [self setValue:preset[key] forKey:key];
    self.enabled = YES;
    [self changed];
}

#pragma mark - Persistence

+ (NSArray<NSString *> *)numericKeys {
    return @[@"brightness", @"contrast", @"saturation", @"hue", @"gamma", @"exposure", @"warmth", @"sharpness", @"noiseReduction", @"blur", @"vignette"];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (NSString *key in [VPPostProcessing numericKeys]) dict[key] = [self valueForKey:key];
    dict[@"level"] = @(self.level);
    dict[@"enabled"] = @(self.enabled); dict[@"invert"] = @(self.invert);
    if (self.filterChain.count) dict[@"filterChain"] = self.filterChain;
    if (self.shaderSource.length) dict[@"shaderSource"] = self.shaderSource;
    return dict;
}

- (void)applyDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return;
    [self resetAdjustments];
    for (NSString *key in [VPPostProcessing numericKeys]) if ([dictionary[key] isKindOfClass:NSNumber.class]) [self setValue:dictionary[key] forKey:key];
    if (dictionary[@"level"] && [dictionary[@"level"] isKindOfClass:NSNumber.class]) self.level = [dictionary[@"level"] doubleValue];
    self.enabled = [dictionary[@"enabled"] boolValue]; self.invert = [dictionary[@"invert"] boolValue];
    NSArray *chain = [dictionary[@"filterChain"] isKindOfClass:NSArray.class] ? dictionary[@"filterChain"] : @[];
    self.filterChain = chain;
    [self installShaderSource:[dictionary[@"shaderSource"] isKindOfClass:NSString.class] ? dictionary[@"shaderSource"] : @"" error:nil];
    [self changed];
}
@end
