#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A tiny loopback-only HTTP file server. AVPlayer only plays HLS over HTTP, and vplay uses HLS to start
/// playing converted media (discs, unusual codecs) while FFmpeg is still working on it.
@interface VPLocalServer : NSObject
+ (instancetype)shared;
/// Serves `directory` and returns the http://127.0.0.1 URL of `fileName` inside it, or nil if the server could not start.
- (nullable NSURL *)publishDirectory:(NSURL *)directory fileName:(NSString *)fileName;
- (void)unpublishDirectory:(NSURL *)directory;
@end

NS_ASSUME_NONNULL_END
