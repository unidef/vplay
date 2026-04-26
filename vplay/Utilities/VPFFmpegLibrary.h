#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/// One in-process conversion. Each instance owns its codecs, filters and cancellation state.
@interface VPFFmpegJob : NSObject
@property (atomic, readonly, getter=isRunning) BOOL running;
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (BOOL)runInput:(NSURL *)input output:(NSURL *)output options:(NSDictionary *)options error:(NSError **)error;
- (void)startInput:(NSURL *)input output:(NSURL *)output options:(NSDictionary *)options
       completion:(void (^)(NSError * _Nullable error))completion;
- (void)cancel;
@end

@interface VPFFmpegLibrary : NSObject
+ (nullable NSDictionary *)probeURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)extractSubtitles:(NSURL *)input index:(NSInteger)index output:(NSURL *)output error:(NSError **)error;
+ (BOOL)supportsStreamingConversion;
+ (nullable CIImage *)frameAtTime:(double)seconds fromURL:(NSURL *)url error:(NSError **)error;
/// Supported single-input conversion arguments. Unknown options fail explicitly.
+ (BOOL)parseArguments:(NSArray<NSString *> *)arguments input:(NSURL * _Nullable * _Nonnull)input
               output:(NSURL * _Nullable * _Nonnull)output options:(NSDictionary * _Nullable * _Nonnull)options error:(NSError **)error;
@end
@interface VPFFmpegLibrary (AudioDemo)
+ (BOOL)renderAudioDemoWithGraph:(NSString *)filter output:(NSURL *)output error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
