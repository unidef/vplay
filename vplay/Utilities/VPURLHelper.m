//
//  VPURLHelper.m
//  vplay
//

#import "VPURLHelper.h"

@implementation VPURLHelper

+ (nullable NSURL *)urlFromString:(NSString *)pathOrURL {
    if (!pathOrURL.length) return nil;
    // Anything with a scheme (http, https, rtsp, rtmp, udp, file, ...) is passed through as a URL.
    if ([pathOrURL containsString:@"://"]) {
        NSURL *url = [NSURL URLWithString:pathOrURL];
        return url ?: [NSURL URLWithString:[pathOrURL stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    }
    // Expand tilde
    NSString *expanded = [pathOrURL stringByExpandingTildeInPath];
    return [NSURL fileURLWithPath:expanded];
}

+ (NSSet<NSString *> *)supportedMediaExtensions {
    static NSSet *exts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exts = [NSSet setWithArray:@[
            // Video
            @"mp4", @"m4v", @"mov", @"qt", @"avi", @"mkv", @"mk3d", @"webm", @"wmv", @"asf", @"flv", @"f4v", @"ts", @"mts", @"m2ts", @"m2t",
            @"mpg", @"mpeg", @"mpe", @"m1v", @"m2v", @"vob", @"dat", @"ogv", @"ogm", @"3gp", @"3g2", @"rm", @"rmvb", @"divx", @"xvid",
            @"mxf", @"mod", @"tod", @"dv", @"amv", @"nsv", @"wtv", @"dvr-ms", @"evo", @"y4m", @"mjpeg", @"h264", @"h265", @"hevc", @"ivf", @"vp9", @"av1", @"obu",
            @"m3u8", @"mpd", @"pls", @"m3u", @"sdp", @"iso",
            // Audio
            @"mp3", @"mp2", @"m4a", @"m4b", @"m4r", @"aac", @"ac3", @"eac3", @"ec3", @"dts", @"dtshd", @"wav", @"w64", @"flac", @"aiff", @"aif", @"aifc",
            @"ogg", @"oga", @"opus", @"spx", @"wma", @"ape", @"wv", @"mka", @"mpc", @"amr", @"au", @"snd", @"caf", @"tta", @"tak", @"ra", @"gsm", @"mid", @"midi", @"alac", @"mlp", @"thd", @"dsf", @"dff"
        ]];
    });
    return exts;
}

+ (BOOL)isSupportedMediaPath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    return [[self supportedMediaExtensions] containsObject:ext];
}

+ (BOOL)isStreamingURL:(nullable NSURL *)url {
    if (!url || url.isFileURL) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    return [@[@"http", @"https", @"rtsp", @"rtsps", @"rtmp", @"rtmps", @"udp", @"tcp", @"srt", @"rtp", @"mms", @"icecast"] containsObject:scheme];
}

@end
