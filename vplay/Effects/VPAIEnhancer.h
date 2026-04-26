//
//  VPAIEnhancer.h
//  vplay
//

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const VPAIEnhancerDidChangeNotification;

@interface VPAIEnhancer : NSObject

+ (instancetype)shared;

#pragma mark - Video AI Enhancement Properties

@property (atomic) BOOL videoAIEnabled;
@property (atomic, copy) NSString *activeVideoPreset; // @"none", @"vivid_crisp", @"super_res_4k", @"cinema_hdr", @"denoise_clean", @"anime_crisp", @"studio_master"

// AI Upscaling
@property (atomic) double upscaleFactor; // 1.0 (off), 1.5, 2.0, 3.0, 4.0

// AI Clarity & Sharpness
@property (atomic) double clarityBoost;        // 0.0 ... 1.0 (CIUnsharpMask adaptive)
@property (atomic) double luminanceSharpness;  // 0.0 ... 1.0 (CISharpenLuminance)
@property (atomic) double adaptiveDenoise;     // 0.0 ... 1.0 (CINoiseReduction)
@property (atomic) double microContrast;       // 0.0 ... 1.0 (Local contrast & detail)

// AI Color & Vividness
@property (atomic) double vividVibrance;       // 0.0 ... 1.0 (Apple CIVibrance - skin-tone preserving)
@property (atomic) BOOL hdrDynamicTone;        // CIHighlightShadowAdjust dynamic range
@property (atomic) BOOL cinemaColorGrade;      // Cinema S-curve & warm highlight balance

// Apple Vision AI Features
@property (atomic) BOOL visionSaliencyFocus;   // Apple Vision VNGenerateAttentionBasedSaliencyImageRequest

@property (atomic, readonly) BOOL isVideoAIActive;
@property (atomic, readonly) NSUInteger revision;

#pragma mark - Audio AI & Surround Properties

@property (atomic) BOOL audioAIEnabled;
@property (atomic, copy) NSString *activeAudioPreset; // @"none", @"clear_dialogue", @"spatial_3d", @"surround_51", @"surround_71", @"studio_master", @"night_mode", @"loudnorm", @"bass_punch"
@property (atomic, copy) NSString *surroundMethod;    // @"none", @"apple_spatial", @"apple_51", @"apple_71", @"ffmpeg_51", @"ffmpeg_71", @"stereo_wide", @"subwoofer_21"
@property (atomic, copy) NSString *outputCodec;       // @"pcm", @"ac3", @"eac3", @"dts", @"aac", @"alac", @"flac", @"opus", @"mp3"
@property (atomic, copy) NSString *targetLayout;      // @"auto", @"mono", @"stereo", @"2.1", @"4.0", @"4.1", @"5.0", @"5.1", @"7.1"
@property (atomic, copy) NSString *targetSampleRate;  // @"auto", @"44100", @"48000", @"88200", @"96000", @"176400", @"192000", @"384000", @"max"

@property (atomic) BOOL dialogueBoost;
@property (atomic) BOOL harmonicCrystalizer;
@property (atomic) BOOL loudnessNormalize;
@property (atomic) BOOL nightMode;
@property (atomic) BOOL bassImpact;
@property (atomic) BOOL trebleSparkle;

@property (atomic, readonly) BOOL isAudioAIActive;

#pragma mark - Operations

- (void)changed;

// Process frame through Apple AI video filters
- (CIImage *)processImage:(CIImage *)input;

// Construct full FFmpeg / Apple AI audio filter graph string
- (NSString *)audioFilterGraphString;

// Presets
- (void)applyVideoPreset:(NSString *)presetName;
- (void)applyAudioPreset:(NSString *)presetName;

- (void)resetVideoAI;
- (void)resetAudioAI;

// Codec display title
+ (NSString *)displayNameForCodec:(NSString *)codec;
+ (NSString *)displayNameForLayout:(NSString *)layout;
+ (NSString *)displayNameForSurroundMethod:(NSString *)method;

@end

NS_ASSUME_NONNULL_END
