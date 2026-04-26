//
//  VPURLHelper.h
//  vplay
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPURLHelper : NSObject

/// Resolves a path-or-URL string to an NSURL. Returns nil for invalid input.
+ (nullable NSURL *)urlFromString:(NSString *)pathOrURL;

/// Supported media file extensions
+ (NSSet<NSString *> *)supportedMediaExtensions;

/// Check if a file path has a supported media extension
+ (BOOL)isSupportedMediaPath:(NSString *)path;

/// Check if a URL represents a live network stream (http, https, rtsp, rtmp, etc.)
+ (BOOL)isStreamingURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END
