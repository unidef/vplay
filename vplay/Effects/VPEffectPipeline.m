#define CI_SILENCE_GL_DEPRECATION 1
#import "VPEffectPipeline.h"
#import "VPPostProcessing.h"
#import "VPAIEnhancer.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

/// name -> {filter, key (or ""), default, min, max}
static NSDictionary<NSString *, NSArray *> *EffectTable(void) {
    static NSDictionary *table; static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"grayscale": @[@"CIColorControls",       @"inputSaturation", @0,   @0,   @1],
            @"sepia":     @[@"CISepiaTone",           @"inputIntensity",  @1,   @0,   @1],
            @"invert":    @[@"CIColorInvert",         @"",                @0,   @0,   @0],
            @"blur":      @[@"CIGaussianBlur",        @"inputRadius",     @5,   @0,   @40],
            @"vignette":  @[@"CIVignette",            @"inputIntensity",  @1,   @0,   @2],
            @"sharpen":   @[@"CISharpenLuminance",    @"inputSharpness",  @0.5, @0,   @2],
            @"pixelate":  @[@"CIPixellate",           @"inputScale",      @8,   @1,   @60],
            @"edges":     @[@"CIEdges",               @"inputIntensity",  @1,   @0,   @10],
            @"noir":      @[@"CIPhotoEffectNoir",     @"",                @0,   @0,   @0],
            @"chrome":    @[@"CIPhotoEffectChrome",   @"",                @0,   @0,   @0],
            @"fade":      @[@"CIPhotoEffectFade",     @"",                @0,   @0,   @0],
            @"instant":   @[@"CIPhotoEffectInstant",  @"",                @0,   @0,   @0],
            @"mono":      @[@"CIPhotoEffectMono",     @"",                @0,   @0,   @0],
            @"process":   @[@"CIPhotoEffectProcess",  @"",                @0,   @0,   @0],
            @"tonal":     @[@"CIPhotoEffectTonal",    @"",                @0,   @0,   @0],
            @"transfer":  @[@"CIPhotoEffectTransfer", @"",                @0,   @0,   @0],
            @"posterize": @[@"CIColorPosterize",      @"inputLevels",     @6,   @2,   @30],
            @"bloom":     @[@"CIBloom",               @"inputIntensity",  @0.7, @0,   @2],
            @"comic":     @[@"CIComicEffect",         @"",                @0,   @0,   @0],
            @"thermal":   @[@"CIThermal",             @"",                @0,   @0,   @0],
            @"xray":      @[@"CIXRay",                @"",                @0,   @0,   @0],
            @"zoomblur":  @[@"CIZoomBlur",            @"inputAmount",     @10,  @0,   @60],
            @"halftone":  @[@"CICMYKHalftone",        @"inputWidth",      @6,   @2,   @30],
        };
    });
    return table;
}

@implementation VPEffectPipeline

+ (NSArray<NSString *> *)availableEffects {
    NSMutableArray *names = [[EffectTable().allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    [names insertObject:@"none" atIndex:0];
    return names;
}

+ (BOOL)applyEffect:(NSString *)spec error:(NSError **)error {
    NSString *name = [spec componentsSeparatedByString:@":"].firstObject;
    BOOL valid = [[self availableEffects] containsObject:name];
    if (!valid && error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:20 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Unknown effect “%@”. Run 'vplay effect-list' for the available names.", name]}];
    return valid;
}

+ (NSDictionary<NSString *, NSNumber *> *)amountInfoForEffect:(NSString *)name {
    NSArray *row = EffectTable()[name];
    if (!row || ![row[1] length]) return nil;
    return @{@"default":row[2], @"min":row[3], @"max":row[4]};
}

+ (CIImage *)image:(CIImage *)image withEffectSpec:(NSString *)spec {
    NSArray *parts = [spec componentsSeparatedByString:@":"];
    NSArray *row = EffectTable()[parts.firstObject];
    if (!row) return image;
    NSDictionary *parameters = [row[1] length] ? @{row[1]: parts.count > 1 ? @([parts[1] doubleValue]) : row[2]} : @{};
    CGRect extent = image.extent;
    CIImage *result = [[image imageByClampingToExtent] imageByApplyingFilter:row[0] withInputParameters:parameters];
    return [result imageByCroppingToRect:extent] ?: image;
}

+ (CIColorKernel *)compileKernelSource:(NSString *)source error:(NSError **)error {
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CIColorKernel *kernel = [CIColorKernel kernelWithString:source];
#pragma clang diagnostic pop
    if (!kernel && error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:21 userInfo:@{NSLocalizedDescriptionKey:@"The Core Image color kernel did not compile. It must define “kernel vec4 name(__sample pixel)” and return a vec4."}];
    return kernel;
}

+ (VPImageProcessor)processorForOptions:(NSDictionary *)options error:(NSError **)error {
    NSMutableArray *stages = [NSMutableArray arrayWithArray:options[@"nativeStages"] ?: @[]];
    if ([options[@"effect"] length] && ![options[@"effect"] isEqual:@"none"]) [stages insertObject:@{@"type":@"effect", @"value":options[@"effect"]} atIndex:0];
    if ([options[@"shader"] length]) [stages addObject:@{@"type":@"shader", @"value":options[@"shader"]}];
    NSMutableArray *operations = [NSMutableArray array];
    for (NSDictionary *stage in stages) {
        if ([stage[@"type"] isEqual:@"effect"]) {
            if (![self applyEffect:stage[@"value"] error:error]) return nil;
            [operations addObject:stage[@"value"]];
        } else {
            NSString *source = [NSString stringWithContentsOfFile:[stage[@"value"] stringByExpandingTildeInPath] encoding:NSUTF8StringEncoding error:error];
            if (!source) return nil;
            CIColorKernel *kernel = [self compileKernelSource:source error:nil];
            if (!kernel) {
                if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:21 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Invalid Core Image color kernel: %@", stage[@"value"]]}];
                return nil;
            }
            [operations addObject:kernel];
        }
    }
    double scale = [options[@"upscale"] ?: @1 doubleValue];
    return ^CIImage *(CIImage *input) {
        CGRect extent = input.extent;
        CIImage *output = input;
        for (id operation in operations) {
            if ([operation isKindOfClass:CIColorKernel.class]) output = [operation applyWithExtent:extent arguments:@[output]];
            else output = [self image:output withEffectSpec:operation];
            if (!output) return nil;
        }
        output = [VPPostProcessing.shared processImage:output];
        output = [VPAIEnhancer.shared processImage:output];
        if (output && scale > 1.01 && VPAIEnhancer.shared.upscaleFactor <= 1.01) {
            CGRect curExtent = output.extent;
            CIImage *normalized = [output imageByApplyingTransform:CGAffineTransformMakeTranslation(-curExtent.origin.x, -curExtent.origin.y)];
            CIImage *scaled = [normalized imageByApplyingFilter:@"CILanczosScaleTransform" withInputParameters:@{kCIInputScaleKey:@(scale), kCIInputAspectRatioKey:@1}];
            return [scaled imageByCroppingToRect:CGRectMake(0, 0, ceil(curExtent.size.width * scale), ceil(curExtent.size.height * scale))];
        }
        return output ? [output imageByCroppingToRect:output.extent] : nil;
    };
}

+ (BOOL)optionsRequireProcessing:(NSDictionary *)options {
    BOOL hasStages = [options[@"nativeStages"] count] || ([options[@"effect"] length] && ![options[@"effect"] isEqual:@"none"]) || [options[@"shader"] length];
    return hasStages || [options[@"upscale"] ?: @1 doubleValue] > 1.01 || VPAIEnhancer.shared.isVideoAIActive;
}

+ (BOOL)configureItem:(AVPlayerItem *)item options:(NSDictionary *)options error:(NSError **)error {
    VPImageProcessor processor = [self processorForOptions:options error:error];
    if (!processor) return NO;
    double scale = [options[@"upscale"] ?: @1 doubleValue];
    if (VPAIEnhancer.shared.upscaleFactor > 1.01) {
        scale = MAX(scale, VPAIEnhancer.shared.upscaleFactor);
    }
    BOOL hasStages = [options[@"nativeStages"] count] || ([options[@"effect"] length] && ![options[@"effect"] isEqual:@"none"]) || [options[@"shader"] length];
    if (!hasStages && scale <= 1.01 && !VPPostProcessing.shared.isActive && !VPAIEnhancer.shared.isVideoAIActive) { item.videoComposition = nil; return YES; }
    CIContext *context = nil;
    if (scale > 1.01) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:23 userInfo:@{NSLocalizedDescriptionKey:@"Metal is unavailable. Select scaler=lanczos for FFplay CPU scaling."}];
            return NO;
        }
        context = [CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates:@NO}];
    }
    if (![item.asset tracksWithMediaType:AVMediaTypeVideo].count) {
        // Audio-only media simply has no picture to process.
        if (hasStages || scale > 1.01) {
            if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:24 userInfo:@{NSLocalizedDescriptionKey:@"Video effects and upscaling require a readable video track."}];
            return NO;
        }
        return YES;
    }
    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoCompositionWithAsset:item.asset applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *request) {
        CIImage *output = processor(request.sourceImage);
        if (output) [request finishWithImage:output context:context];
        else [request finishWithError:[NSError errorWithDomain:@"VPlayErrorDomain" code:22 userInfo:@{NSLocalizedDescriptionKey:@"Shader evaluation failed."}]];
    }];
    CGSize size = CGSizeMake(ceil(composition.renderSize.width * scale), ceil(composition.renderSize.height * scale));
    if (scale > 1.01 && (size.width > 8192 || size.height > 8192)) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:25 userInfo:@{NSLocalizedDescriptionKey:@"Upscaled frames exceed the 8192-pixel dimension limit. Choose a smaller factor."}];
        return NO;
    }
    composition.renderSize = size;
    item.videoComposition = composition;
    return YES;
}

#pragma mark - Video Quality Presets

+ (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)videoQualityPresetTable {
    static NSDictionary *table; static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"Auto / Native (1:1 Direct)": @{
                @"upscale": @1.0,
                @"scaler": @"metal",
                @"deinterlace": @NO,
                @"inverseTelecine": @NO,
                @"level": @0.0,
                @"enabled": @NO
            },
            @"Performance (Battery Saver)": @{
                @"upscale": @1.0,
                @"scaler": @"metal",
                @"deinterlace": @NO,
                @"inverseTelecine": @NO,
                @"audioSampleRate": @"48000",
                @"level": @0.0,
                @"enabled": @NO
            },
            @"Balanced (Enhanced Clarity)": @{
                @"upscale": @1.0,
                @"scaler": @"metal",
                @"deinterlace": @NO,
                @"inverseTelecine": @NO,
                @"contrast": @1.06,
                @"sharpness": @0.25,
                @"saturation": @1.04,
                @"level": @0.75,
                @"enabled": @YES
            },
            @"High Definition (1080p Detail)": @{
                @"upscale": @1.5,
                @"scaler": @"metal",
                @"deinterlace": @NO,
                @"inverseTelecine": @NO,
                @"contrast": @1.08,
                @"sharpness": @0.50,
                @"saturation": @1.05,
                @"noiseReduction": @0.15,
                @"level": @1.0,
                @"enabled": @YES
            },
            @"Ultra HD 4K (Upscaling & Clarity)": @{
                @"upscale": @2.0,
                @"scaler": @"metal",
                @"deinterlace": @NO,
                @"inverseTelecine": @NO,
                @"contrast": @1.10,
                @"sharpness": @0.65,
                @"noiseReduction": @0.30,
                @"saturation": @1.06,
                @"level": @1.0,
                @"enabled": @YES
            },
            @"Cinema Film (IVTC 24fps & Film Look)": @{
                @"upscale": @1.0,
                @"scaler": @"metal",
                @"inverseTelecine": @YES,
                @"deinterlace": @NO,
                @"contrast": @1.15,
                @"warmth": @0.15,
                @"vignette": @0.30,
                @"gamma": @1.05,
                @"saturation": @0.92,
                @"level": @1.0,
                @"enabled": @YES
            },
            @"Broadcast / Sports (Deinterlaced 60fps)": @{
                @"upscale": @1.0,
                @"scaler": @"metal",
                @"deinterlace": @YES,
                @"inverseTelecine": @NO,
                @"contrast": @1.05,
                @"sharpness": @0.35,
                @"saturation": @1.05,
                @"level": @1.0,
                @"enabled": @YES
            },
            @"Retro CRT Vintage": @{
                @"upscale": @1.0,
                @"scaler": @"metal",
                @"deinterlace": @NO,
                @"inverseTelecine": @NO,
                @"contrast": @1.25,
                @"saturation": @0.85,
                @"warmth": @0.20,
                @"vignette": @0.60,
                @"level": @1.0,
                @"enabled": @YES
            }
        };
    });
    return table;
}

+ (NSArray<NSString *> *)videoQualityPresetNames {
    return @[
        @"Auto / Native (1:1 Direct)",
        @"Performance (Battery Saver)",
        @"Balanced (Enhanced Clarity)",
        @"High Definition (1080p Detail)",
        @"Ultra HD 4K (Upscaling & Clarity)",
        @"Cinema Film (IVTC 24fps & Film Look)",
        @"Broadcast / Sports (Deinterlaced 60fps)",
        @"Retro CRT Vintage"
    ];
}

+ (NSDictionary<NSString *, id> *)optionsForVideoQualityPresetNamed:(NSString *)name {
    return [self videoQualityPresetTable][name];
}

@end
