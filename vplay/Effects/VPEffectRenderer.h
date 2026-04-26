#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import "VPEffectPipeline.h"

NS_ASSUME_NONNULL_BEGIN

/// Draws processed video frames into a layer for media AVFoundation cannot composite (HLS streams made from
/// discs and unusual formats). Frames come from the player item, pass through the processor, and are shown
/// on `layer`, which the video view stacks above the plain player layer while effects are active.
@interface VPEffectRenderer : NSObject
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, copy, nullable) VPImageProcessor processor;
@property (nonatomic, readonly) BOOL running;
- (void)startWithItem:(AVPlayerItem *)item;
- (void)stop;
/// Directly render a video frame (e.g. from VPFFmpegPlayer) using Metal.
- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer;
/// Redraws the last frame, for example after a slider moved while paused.
- (void)setNeedsRedraw;
/// The processed frame currently on screen, or nil when the renderer is idle.
- (nullable CIImage *)currentImage;
/// The source video frame (unprocessed) currently on screen, or nil when idle.
- (nullable CIImage *)currentSourceImage;
@end

NS_ASSUME_NONNULL_END
