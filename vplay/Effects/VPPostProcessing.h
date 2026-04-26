#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const VPPostProcessingDidChangeNotification;

/// Live picture adjustments, a custom Core Image shader and a user-built filter chain.
/// The values are read on the video rendering thread, so changes show up on the next frame.
@interface VPPostProcessing : NSObject
+ (instancetype)shared;

@property (atomic) BOOL enabled;               // master switch for the adjustments below
@property (atomic) double level;                 // master post-processing intensity: 0.0 (off) … 1.0 (full strength)
@property (atomic) double brightness;          // -1 … 1   (0)
@property (atomic) double contrast;            //  0 … 2   (1)
@property (atomic) double saturation;          //  0 … 3   (1)
@property (atomic) double hue;                 // -180 … 180 degrees (0)
@property (atomic) double gamma;               //  0.3 … 3 (1)
@property (atomic) double exposure;            // -2 … 2 stops (0)
@property (atomic) double warmth;              // -1 … 1   (0)
@property (atomic) double sharpness;           //  0 … 2   (0)
@property (atomic) double noiseReduction;      //  0 … 1   (0)
@property (atomic) double blur;                //  0 … 20  (0)
@property (atomic) double vignette;            //  0 … 2   (0)
@property (atomic) BOOL invert;

/// Effect specs such as "sepia:0.6", applied in order before the adjustments. Edited in the shader/filter editor.
@property (atomic, copy) NSArray<NSString *> *filterChain;
/// Source of a Core Image color kernel applied first. Empty means none.
@property (atomic, copy) NSString *shaderSource;
@property (atomic, readonly, nullable) CIColorKernel *shaderKernel;
/// Compiles `source` and installs it as the live shader. Passing an empty string removes the shader.
- (BOOL)installShaderSource:(NSString *)source error:(NSError **)error;

/// YES when anything would change the picture.
@property (nonatomic, readonly) BOOL isActive;
/// Incremented on every change so renderers can redraw a paused frame.
@property (atomic, readonly) NSUInteger revision;
/// Call after changing properties; notifies the player so it can refresh.
- (void)changed;

/// Shader, then filter chain, then adjustments.
- (CIImage *)processImage:(CIImage *)image;
/// Only the adjustment sliders (used by the shader editor's preview, which supplies its own shader and chain).
- (CIImage *)adjustImage:(CIImage *)image;

+ (NSArray<NSString *> *)levelNames;
+ (double)factorForLevelNamed:(NSString *)name;
- (void)setLevelNamed:(NSString *)name;
- (NSString *)currentLevelName;

+ (NSArray<NSString *> *)presetNames;
- (void)applyPresetNamed:(NSString *)name;
- (void)resetAdjustments;

- (NSDictionary *)dictionaryRepresentation;
- (void)applyDictionary:(nullable NSDictionary *)dictionary;
@end

NS_ASSUME_NONNULL_END
