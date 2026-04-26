#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Taps the audio of a playing item and turns it into a live spectrum (a fast Fourier transform folded into bands).
/// Taps work for media AVFoundation plays directly; streamed (converted) media shows an idle animation instead.
@interface VPAudioAnalyzer : NSObject
@property (nonatomic, readonly) NSUInteger bandCount;
/// YES while real audio samples arrived within the last half second.
@property (nonatomic, readonly) BOOL hasSignal;
- (void)attachToItem:(AVPlayerItem *)item;
- (void)detach;
/// Copies the current band levels (0…1) into `levels`, which must hold `bandCount` floats.
- (void)copyLevels:(float *)levels;
@end

typedef NS_ENUM(NSInteger, VPVisualizerStyle) {
    VPVisualizerStyleBars, VPVisualizerStyleMirror, VPVisualizerStyleRing,
    VPVisualizerStyleTerrain3D,   // a field of columns, with older sound receding into the distance
    VPVisualizerStyleOrbit3D,     // a glowing core ringed by pulsing columns
    VPVisualizerStyleCount
};

/// Names used in configuration files and the command line.
FOUNDATION_EXPORT NSArray<NSString *> *VPVisualizerStyleNames(void);

@interface VPVisualizerView : NSView
@property (nonatomic, strong, nullable) VPAudioAnalyzer *analyzer;
@property (nonatomic) VPVisualizerStyle style;
@property (nonatomic, copy) NSColor *accentColor;
/// Starts or stops the 60 Hz drawing timer; the view stops drawing while hidden.
@property (nonatomic) BOOL animating;
@end

NS_ASSUME_NONNULL_END
