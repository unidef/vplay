#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Measures how many distinct video frames per second the player actually delivers.
@interface VPFrameRateMeter : NSObject
/// Called about twice a second with the measured rate.
@property (nonatomic, copy, nullable) void (^onUpdate)(double framesPerSecond);
- (void)startWithItem:(AVPlayerItem *)item;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
