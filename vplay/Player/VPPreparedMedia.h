#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts media AVFoundation cannot play (other codecs and containers, DVD / Blu-ray streams, FFmpeg filter
/// chains) into something it can. Video starts playing within a couple of seconds as an HLS stream that FFmpeg
/// keeps producing; audio-only media and machines without VideoToolbox encoders use a whole-file conversion.
///
/// Recognised options besides the usual processing options:
///   startOffset (seconds)   begin conversion at this position
///   videoStream / audioStream (0-based index within its kind)
///   burnSubtitleStream      index of an image-based subtitle stream to draw onto the picture
///   audioOnly (BOOL)        force whole-file audio conversion
@interface VPPreparedMedia : NSObject
@property (nonatomic, readonly, nullable) NSURL *outputURL;
/// YES when the output is an HLS stream (AVFoundation video compositions cannot be attached to those).
@property (nonatomic, readonly) BOOL streaming;
/// Reports conversion errors after streaming playback has already begun, on the main queue.
@property (nonatomic, copy, nullable) void (^failureHandler)(NSError *error);
- (void)prepareURL:(NSURL *)url options:(NSDictionary *)options completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
