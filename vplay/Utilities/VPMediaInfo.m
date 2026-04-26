//
//  VPMediaInfo.m
//  vplay
//

#import "VPMediaInfo.h"
#import "VPURLHelper.h"
#import <AVFoundation/AVFoundation.h>

@implementation VPMediaInfo

+ (nullable NSDictionary *)infoForPathOrURL:(NSString *)pathOrURL {
    NSURL *url = [VPURLHelper urlFromString:pathOrURL];
    if (!url) return nil;

    AVAsset *asset = [AVAsset assetWithURL:url];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"duration"] = @(CMTimeGetSeconds(asset.duration));

    NSMutableArray *videoTracks = [NSMutableArray array];
    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeVideo]) {
        [videoTracks addObject:@{
            @"width": @(track.naturalSize.width),
            @"height": @(track.naturalSize.height),
            @"frameRate": @(track.nominalFrameRate)
        }];
    }
    if (videoTracks.count) info[@"video"] = videoTracks;

    NSMutableArray *audioTracks = [NSMutableArray array];
    for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeAudio]) {
        NSMutableDictionary *trackInfo = [NSMutableDictionary dictionary];
        trackInfo[@"sampleRate"] = @(track.nominalFrameRate);
        for (id desc in track.formatDescriptions) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMFormatDescriptionRef)desc);
            if (asbd) {
                trackInfo[@"sampleRate"] = @(asbd->mSampleRate);
                trackInfo[@"channels"] = @(asbd->mChannelsPerFrame);
                break;
            }
        }
        [audioTracks addObject:trackInfo];
    }
    if (audioTracks.count) info[@"audio"] = audioTracks;

    return info;
}

@end
