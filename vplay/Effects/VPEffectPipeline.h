//
//  VPEffectPipeline.h
//  vplay
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/// Maps an incoming video frame to the frame to display.
typedef CIImage * _Nullable (^VPImageProcessor)(CIImage *input);

@interface VPEffectPipeline : NSObject

/// Installs a Core Image composition on the item when anything (configured stages, the shader/filter editor,
/// post-processing or upscaling) needs one; otherwise leaves the item untouched so video stays on the fast path.
+ (BOOL)configureItem:(AVPlayerItem *)item options:(NSDictionary *)options error:(NSError **)error;
/// Builds the frame processor for `options` (configured stages, then live post-processing, then upscaling).
+ (nullable VPImageProcessor)processorForOptions:(NSDictionary *)options error:(NSError **)error;

/// YES when the configured stages or upscaling alone (not the live post-processing) need frame processing.
+ (BOOL)optionsRequireProcessing:(NSDictionary *)options;

/// Names usable in effect specs. A spec is "name" or "name:amount", for example "sepia:0.6".
+ (NSArray<NSString *> *)availableEffects;
+ (BOOL)applyEffect:(NSString *)spec error:(NSError **)error;
/// The default amount and slider range for an effect, or nil when it has no amount.
+ (nullable NSDictionary<NSString *, NSNumber *> *)amountInfoForEffect:(NSString *)name;
+ (CIImage *)image:(CIImage *)image withEffectSpec:(NSString *)spec;
+ (nullable CIColorKernel *)compileKernelSource:(NSString *)source error:(NSError **)error;

/// Comprehensive presets for video quality combining resolution upscaling, post-processing, deinterlacing, and IVTC.
+ (NSArray<NSString *> *)videoQualityPresetNames;
+ (nullable NSDictionary<NSString *, id> *)optionsForVideoQualityPresetNamed:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
