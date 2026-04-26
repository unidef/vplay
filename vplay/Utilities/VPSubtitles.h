#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A set of timed text cues parsed from SRT, WebVTT or ASS/SSA data.
@interface VPSubtitleTrack : NSObject
@property (nonatomic, readonly) NSUInteger cueCount;
/// Loads a subtitle file (.srt, .vtt, .ass, .ssa, .sub text variants).
+ (nullable instancetype)trackWithContentsOfURL:(NSURL *)url error:(NSError **)error;
/// Uses FFmpeg to convert one embedded text subtitle stream of `media` into cues. Completes on the main queue.
+ (void)extractFromMedia:(NSURL *)media subtitleIndex:(NSInteger)index completion:(void (^)(VPSubtitleTrack * _Nullable track, NSError * _Nullable error))completion;
/// The text visible at `seconds`, or nil.
- (nullable NSString *)textAtTime:(double)seconds;

/// Returns a cached track if already loaded/extracted in memory.
+ (nullable instancetype)cachedTrackForMedia:(NSURL *)media subtitleIndex:(NSInteger)index;
/// Prefetches a subtitle track into memory cache in the background.
+ (void)prefetchTrackForMedia:(NSURL *)media subtitleIndex:(NSInteger)index;
/// Clears the subtitle track cache.
+ (void)clearCache;
@end

NS_ASSUME_NONNULL_END
