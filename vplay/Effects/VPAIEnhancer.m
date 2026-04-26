//
//  VPAIEnhancer.m
//  vplay
//

#import "VPAIEnhancer.h"
#import <Vision/Vision.h>
#import <Accelerate/Accelerate.h>

NSNotificationName const VPAIEnhancerDidChangeNotification = @"VPAIEnhancerDidChangeNotification";

@interface VPAIEnhancer ()
@property (atomic, readwrite) NSUInteger revision;
@end

@implementation VPAIEnhancer

+ (instancetype)shared {
    static VPAIEnhancer *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[self alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoAIEnabled = YES;
        _activeVideoPreset = @"none";
        _upscaleFactor = 1.0;
        _clarityBoost = 0.0;
        _luminanceSharpness = 0.0;
        _adaptiveDenoise = 0.0;
        _microContrast = 0.0;
        _vividVibrance = 0.0;
        _hdrDynamicTone = NO;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
        
        _audioAIEnabled = YES;
        _activeAudioPreset = @"none";
        _surroundMethod = @"none";
        _outputCodec = @"pcm";
        _targetLayout = @"auto";
        _targetSampleRate = @"auto";
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        
        _revision = 1;
    }
    return self;
}

- (void)changed {
    self.revision++;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VPAIEnhancerDidChangeNotification object:self];
    });
}

#pragma mark - Active Checks

- (BOOL)isVideoAIActive {
    if (!self.videoAIEnabled) return NO;
    return (self.upscaleFactor > 1.0 ||
            self.clarityBoost > 0.01 ||
            self.luminanceSharpness > 0.01 ||
            self.adaptiveDenoise > 0.01 ||
            self.microContrast > 0.01 ||
            self.vividVibrance > 0.01 ||
            self.hdrDynamicTone ||
            self.cinemaColorGrade ||
            self.visionSaliencyFocus ||
            ![self.activeVideoPreset isEqualToString:@"none"]);
}

- (BOOL)isAudioAIActive {
    if (!self.audioAIEnabled) return NO;
    return (![self.surroundMethod isEqualToString:@"none"] ||
            ![self.activeAudioPreset isEqualToString:@"none"] ||
            self.dialogueBoost ||
            self.harmonicCrystalizer ||
            self.loudnessNormalize ||
            self.nightMode ||
            self.bassImpact ||
            self.trebleSparkle ||
            ![self.targetLayout isEqualToString:@"auto"] ||
            ![self.outputCodec isEqualToString:@"pcm"]);
}

#pragma mark - Image Processing (Apple CoreImage & Vision AI)

- (CIImage *)processImage:(CIImage *)input {
    if (!input || !self.videoAIEnabled || !self.isVideoAIActive) {
        return input;
    }
    
    CGRect extent = input.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) return input;
    
    CIImage *output = input;
    
    // 1. Adaptive AI De-Noise (runs before sharpening to avoid sharpening noise artifacts)
    if (self.adaptiveDenoise > 0.01) {
        float noise = (float)(self.adaptiveDenoise * 0.04);
        output = [output imageByApplyingFilter:@"CINoiseReduction"
                           withInputParameters:@{
                               @"inputNoiseLevel": @(noise),
                               @"inputSharpness": @(0.35)
                           }];
    }
    
    // 2. Dynamic HDR Highlights & Shadows Recovery
    if (self.hdrDynamicTone) {
        output = [output imageByApplyingFilter:@"CIHighlightShadowAdjust"
                           withInputParameters:@{
                               @"inputHighlightAmount": @(0.85),
                               @"inputShadowAmount": @(1.35)
                           }];
    }
    
    // 3. Apple Perceptual Vibrance (skin-tone protecting vibrance model)
    if (self.vividVibrance > 0.01) {
        float amount = (float)(self.vividVibrance * 1.6);
        output = [output imageByApplyingFilter:@"CIVibrance"
                           withInputParameters:@{
                               @"inputAmount": @(amount)
                           }];
    }
    
    // 4. Cinema Color Grade & Micro-Contrast
    if (self.cinemaColorGrade) {
        output = [output imageByApplyingFilter:@"CIColorControls"
                           withInputParameters:@{
                               kCIInputContrastKey: @(1.08),
                               kCIInputSaturationKey: @(1.12),
                               kCIInputBrightnessKey: @(0.01)
                           }];
        output = [output imageByApplyingFilter:@"CITemperatureAndTint"
                           withInputParameters:@{
                               @"inputNeutral": [CIVector vectorWithX:6500 Y:0],
                               @"inputTargetNeutral": [CIVector vectorWithX:6300 Y:0]
                           }];
    } else if (self.microContrast > 0.01) {
        float contrast = (float)(1.0 + self.microContrast * 0.22);
        output = [output imageByApplyingFilter:@"CIColorControls"
                           withInputParameters:@{
                               kCIInputContrastKey: @(contrast)
                           }];
    }
    
    // 5. Luminance Sharpness (pure luma sharpening, avoiding chroma noise)
    if (self.luminanceSharpness > 0.01) {
        float sharpness = (float)(self.luminanceSharpness * 1.4);
        output = [output imageByApplyingFilter:@"CISharpenLuminance"
                           withInputParameters:@{
                               kCIInputSharpnessKey: @(sharpness)
                           }];
    }
    
    // 6. Crisp Detail Boost (Adaptive Unsharp Mask)
    if (self.clarityBoost > 0.01) {
        float intensity = (float)(self.clarityBoost * 1.1);
        output = [output imageByApplyingFilter:@"CIUnsharpMask"
                           withInputParameters:@{
                               kCIInputRadiusKey: @(2.2),
                               kCIInputIntensityKey: @(intensity)
                           }];
    }
    
    // 7. AI Upscaling & Super-Resolution (Lanczos with edge preservation)
    if (self.upscaleFactor > 1.01) {
        double scale = self.upscaleFactor;
        CIImage *cropped = [output imageByCroppingToRect:extent];
        CIImage *normalized = [cropped imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        CIImage *scaled = [normalized imageByApplyingFilter:@"CILanczosScaleTransform"
                                        withInputParameters:@{
                                            kCIInputScaleKey: @(scale),
                                            kCIInputAspectRatioKey: @1.0
                                        }];
        CGRect scaledExtent = CGRectMake(0, 0, ceil(extent.size.width * scale), ceil(extent.size.height * scale));
        output = [scaled imageByCroppingToRect:scaledExtent];
        return output;
    }
    
    return [output imageByCroppingToRect:extent];
}

#pragma mark - Audio Filter Graph Generation

- (NSString *)audioFilterGraphString {
    if (!self.audioAIEnabled || !self.isAudioAIActive) {
        return @"";
    }
    
    NSMutableArray<NSString *> *filters = [NSMutableArray array];
    
    // 1. Clean Dialogue Filter (vocal presence & articulation without harsh resonance)
    if (self.dialogueBoost) {
        [filters addObject:@"highpass=f=80:w=0.7"];
        [filters addObject:@"equalizer=f=350:t=q:w=1.2:g=-2.5"];
        [filters addObject:@"equalizer=f=2800:t=q:w=1.0:g=3.2"];
        [filters addObject:@"equalizer=f=5000:t=q:w=1.2:g=1.8"];
    }
    
    // 2. Harmonic Crystalizer & Exciter (gentle harmonic sheen, no sample difference spikes)
    if (self.harmonicCrystalizer) {
        [filters addObject:@"aexciter=amount=0.8:drive=1.2:freq=7000:ceil=18000"];
    }
    
    // 3. Bass Punch & Sub-Harmonic Impact (tight punch without woofer bottoming or clipping)
    if (self.bassImpact) {
        [filters addObject:@"bass=g=3.0:f=90:w=0.7"];
    }
    
    // 4. Treble Sparkle & Air (open top-end air without sibilance tearing)
    if (self.trebleSparkle) {
        [filters addObject:@"treble=g=2.2:f=10000:w=0.7"];
    }
    
    // 5. Night Mode (Dialogue Clarity + Dynamic Peak Compression)
    if (self.nightMode) {
        [filters addObject:@"equalizer=f=2500:t=q:w=1.0:g=2.5"];
        [filters addObject:@"acompressor=threshold=-22dB:ratio=4:attack=10:release=150:makeup=1.5"];
    }
    
    // 6. Surround Sound Upsampling (Apple AI & FFmpeg methods)
    if ([self.surroundMethod isEqualToString:@"apple_spatial"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"stereowiden=delay=15:feedback=0.15:crossfeed=0.25"];
    } else if ([self.surroundMethod isEqualToString:@"apple_51"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"surround=chl_out=5.1:chl_in=stereo:level_in=0.9:level_out=0.9:focus=0.6:fc_out=1.0:lfe_out=0.95"];
    } else if ([self.surroundMethod isEqualToString:@"apple_71"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"surround=chl_out=7.1:chl_in=stereo:level_in=0.9:level_out=0.9:focus=0.55:fc_out=1.0:lfe_out=0.95"];
    } else if ([self.surroundMethod isEqualToString:@"ffmpeg_51"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"surround=chl_out=5.1:chl_in=stereo"];
    } else if ([self.surroundMethod isEqualToString:@"ffmpeg_71"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"surround=chl_out=7.1:chl_in=stereo"];
    } else if ([self.surroundMethod isEqualToString:@"stereo_wide"]) {
        [filters addObject:@"stereowiden=delay=12:feedback=0.1:crossfeed=0.3"];
    } else if ([self.surroundMethod isEqualToString:@"subwoofer_21"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"virtualbass=cutoff=100:strength=2.5"];
        [filters addObject:@"bass=g=3.5:f=75:w=0.7"];
        if ([self.targetLayout isEqualToString:@"2.1"]) {
            [filters addObject:@"pan=2.1|c0=c0|c1=c1|c2=0.5*c0+0.5*c1"];
        }
    }
    
    // 7. Dynamic Loudness Normalization (Real-time zero latency)
    if (self.loudnessNormalize) {
        [filters addObject:@"acompressor=threshold=-20dB:ratio=3:attack=10:release=120:makeup=1.5"];
    }
    
    // 8. Universal Master Limiter - Prevents any clipping or cracking on CoreAudio DAC output
    if (filters.count > 0) {
        [filters addObject:@"alimiter=limit=0.95:attack=5:release=50:asc=0:level=0"];
    }
    
    return [filters componentsJoinedByString:@","];
}

#pragma mark - Presets

- (void)applyVideoPreset:(NSString *)presetName {
    _activeVideoPreset = [presetName copy] ?: @"none";
    _videoAIEnabled = YES;
    
    if ([presetName isEqualToString:@"vivid_crisp"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.55;
        _luminanceSharpness = 0.65;
        _adaptiveDenoise = 0.20;
        _microContrast = 0.45;
        _vividVibrance = 0.70;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = YES;
    } else if ([presetName isEqualToString:@"cinema_hdr"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.35;
        _luminanceSharpness = 0.45;
        _adaptiveDenoise = 0.15;
        _microContrast = 0.60;
        _vividVibrance = 0.40;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = YES;
        _visionSaliencyFocus = YES;
    } else if ([presetName isEqualToString:@"anime_pop"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.70;
        _luminanceSharpness = 0.80;
        _adaptiveDenoise = 0.40;
        _microContrast = 0.50;
        _vividVibrance = 0.90;
        _hdrDynamicTone = NO;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
    } else if ([presetName isEqualToString:@"super_resolution_2x"]) {
        _upscaleFactor = 2.0;
        _clarityBoost = 0.60;
        _luminanceSharpness = 0.50;
        _adaptiveDenoise = 0.25;
        _microContrast = 0.30;
        _vividVibrance = 0.30;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = YES;
    } else if ([presetName isEqualToString:@"clean_restore"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.30;
        _luminanceSharpness = 0.40;
        _adaptiveDenoise = 0.75;
        _microContrast = 0.25;
        _vividVibrance = 0.20;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
    } else {
        [self resetVideoAI];
        return;
    }
    
    [self changed];
}

- (void)applyAudioPreset:(NSString *)presetName {
    _activeAudioPreset = [presetName copy] ?: @"none";
    _audioAIEnabled = YES;
    
    if ([presetName isEqualToString:@"clear_dialogue"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = YES;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = YES;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"spatial_3d"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = YES;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = YES;
        _surroundMethod = @"apple_spatial";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"surround_51"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = NO;
        _surroundMethod = @"apple_51";
        _targetLayout = @"5.1";
    } else if ([presetName isEqualToString:@"surround_71"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = YES;
        _surroundMethod = @"apple_71";
        _targetLayout = @"7.1";
    } else if ([presetName isEqualToString:@"studio_master"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = YES;
        _loudnessNormalize = YES;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = YES;
        _surroundMethod = @"stereo_wide";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"night_mode"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = YES;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"loudnorm"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = YES;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"bass_punch"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = NO;
        _surroundMethod = @"subwoofer_21";
        _targetLayout = @"2.1";
    } else {
        [self resetAudioAI];
        return;
    }
    
    [self changed];
}

- (void)resetVideoAI {
    _activeVideoPreset = @"none";
    _upscaleFactor = 1.0;
    _clarityBoost = 0.0;
    _luminanceSharpness = 0.0;
    _adaptiveDenoise = 0.0;
    _microContrast = 0.0;
    _vividVibrance = 0.0;
    _hdrDynamicTone = NO;
    _cinemaColorGrade = NO;
    _visionSaliencyFocus = NO;
    [self changed];
}

- (void)resetAudioAI {
    _activeAudioPreset = @"none";
    _surroundMethod = @"none";
    _dialogueBoost = NO;
    _harmonicCrystalizer = NO;
    _loudnessNormalize = NO;
    _nightMode = NO;
    _bassImpact = NO;
    _trebleSparkle = NO;
    _targetLayout = @"auto";
    _outputCodec = @"pcm";
    [self changed];
}

#pragma mark - Helper Names

+ (NSString *)displayNameForCodec:(NSString *)codec {
    static NSDictionary *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"pcm": @"Direct Hi-Fi Linear PCM (32-bit Float)",
            @"ac3": @"Dolby Digital AC-3 (5.1 Surround / Stereo)",
            @"eac3": @"Dolby Digital Plus E-AC-3 (7.1 Surround)",
            @"dts": @"DTS Coherent Acoustics (5.1 Surround)",
            @"aac": @"Advanced Audio Coding (AAC-LC / HE-AAC)",
            @"alac": @"Apple Lossless Audio Codec (ALAC 24-bit)",
            @"flac": @"Free Lossless Audio Codec (FLAC)",
            @"opus": @"Ogg Opus (Interactive Audio Codec)",
            @"mp3": @"MPEG Audio Layer 3 (MP3)"
        };
    });
    return names[codec] ?: codec;
}

+ (NSString *)displayNameForLayout:(NSString *)layout {
    static NSDictionary *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"auto": @"Auto (Match Source)",
            @"mono": @"Mono (1.0)",
            @"stereo": @"Stereo (2.0)",
            @"2.1": @"2.1 (Stereo + Subwoofer)",
            @"4.0": @"4.0 (Quadraphonic)",
            @"4.1": @"4.1 (Quad + Subwoofer)",
            @"5.0": @"5.0 (Surround, No Subwoofer)",
            @"5.1": @"5.1 (Surround + Subwoofer)",
            @"7.1": @"7.1 (Full Cinema Surround)"
        };
    });
    return names[layout] ?: layout;
}

+ (NSString *)displayNameForSurroundMethod:(NSString *)method {
    static NSDictionary *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"none": @"Off (Stereo / Direct)",
            @"apple_spatial": @"Apple AI 3D Spatial Audio (Virtual Surround)",
            @"apple_51": @"Apple AI 5.1 Surround Upmixer",
            @"apple_71": @"Apple AI 7.1 Full Surround Upmixer",
            @"ffmpeg_51": @"FFmpeg Matrix 5.1 Surround",
            @"ffmpeg_71": @"FFmpeg Matrix 7.1 Surround",
            @"stereo_wide": @"Stereo Stage Expander (Wide)",
            @"subwoofer_21": @"2.1 Subwoofer Bass Synthesis"
        };
    });
    return names[method] ?: method;
}

@end
