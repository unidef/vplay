#import "VPFFmpegOptions.h"
#import "VPFFmpegLibrary.h"
#import "VPAudioDeviceManager.h"
#import "VPAudioFilters.h"
#import "VPAIEnhancer.h"
@implementation VPFFmpegOptions
+ (BOOL)requiresPreparation:(NSDictionary *)options {
    return [options[@"ffmpeg"] boolValue] || [options[@"vf"] length] || [options[@"af"] length] ||
        VPAudioFilters.shared.isActive || VPAIEnhancer.shared.isAudioAIActive ||
        [options[@"ffplayArguments"] count] || ([options[@"audioLayout"] length] && ![options[@"audioLayout"] isEqual:@"auto"]) ||
        [options[@"deinterlace"] boolValue] || [options[@"inverseTelecine"] boolValue] ||
        ([options[@"upscale"] doubleValue] > 1 && [options[@"scaler"] isEqual:@"lanczos"]);
}
+ (NSDictionary<NSString *, NSString *> *)filterGraphsForOptions:(NSDictionary *)options error:(NSError **)error {
    if ([options[@"nativeStages"] count] || [options[@"shader"] length] || ([options[@"effect"] length] && ![options[@"effect"] isEqual:@"none"])) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:71 userInfo:@{NSLocalizedDescriptionKey:@"Core Image effects and shaders run after library conversion."}];
        return nil;
    }
    if ([options[@"upscale"] doubleValue] > 1 && ![options[@"scaler"] isEqual:@"lanczos"]) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:74 userInfo:@{NSLocalizedDescriptionKey:@"Metal upscaling runs in the video renderer. Use scaler=lanczos for conversion scaling."}];
        return nil;
    }
    NSNumber *sampleRate = [VPAudioDeviceManager sampleRateForOptions:options error:error];
    if (!sampleRate) return nil;
    NSMutableArray *video = [NSMutableArray array];
    NSString *order = options[@"fieldOrder"] ?: @"auto";
    if ([options[@"inverseTelecine"] boolValue]) {
        [video addObject:[NSString stringWithFormat:@"fieldmatch=order=%@:combmatch=full,bwdif=mode=send_frame:parity=%@:deint=interlaced,decimate", order, order]];
    } else if ([options[@"deinterlace"] boolValue]) {
        [video addObject:[NSString stringWithFormat:@"bwdif=mode=send_field:parity=%@:deint=all", order]];
    }
    if ([options[@"vf"] length]) [video addObject:options[@"vf"]];
    double factor = [options[@"upscale"] ?: @1 doubleValue];
    if (factor > 1) [video addObject:[NSString stringWithFormat:@"scale=w=trunc(iw*%.4f/2)*2:h=trunc(ih*%.4f/2)*2:flags=lanczos", factor, factor]];
    NSMutableArray *audio = [NSMutableArray array];
    if ([options[@"af"] length]) [audio addObject:options[@"af"]];
    else if (VPAudioFilters.shared.isActive && VPAudioFilters.shared.graph.length) [audio addObject:VPAudioFilters.shared.graph];
    if (VPAIEnhancer.shared.isAudioAIActive && VPAIEnhancer.shared.audioFilterGraphString.length) {
        [audio addObject:VPAIEnhancer.shared.audioFilterGraphString];
    }
    NSString *layout = options[@"audioLayout"] ?: (VPAIEnhancer.shared.targetLayout ?: @"auto");
    if ([layout isEqual:@"2.0"]) layout = @"stereo";
    if (![layout isEqual:@"auto"] && ![VPAIEnhancer.shared.surroundMethod hasPrefix:@"apple"] && ![VPAIEnhancer.shared.surroundMethod hasPrefix:@"ffmpeg"] && ![VPAIEnhancer.shared.surroundMethod isEqualToString:@"subwoofer_21"]) {
        // Layouts with more speakers than the source are synthesized from stereo; anything else is a plain re-map / downmix.
        NSDictionary *channelCounts = @{@"mono":@1, @"stereo":@2, @"2.1":@3, @"4.0":@4, @"4.1":@5, @"5.0":@5, @"5.1":@6, @"7.1":@8};
        NSInteger targetChannels = [channelCounts[layout] integerValue];
        NSInteger sourceChannels = [options[@"sourceChannels"] integerValue] ?: 2;
        if (targetChannels == 3 && sourceChannels <= 2) {
            [audio addObject:@"aformat=channel_layouts=stereo,pan=2.1|c0=c0|c1=c1|c2=0.5*c0+0.5*c1"];
        } else if (targetChannels > 2 && sourceChannels <= 2) {
            [audio addObject:[NSString stringWithFormat:@"aformat=channel_layouts=stereo,surround=chl_in=stereo:chl_out=%@", layout]];
        } else if (targetChannels > 0) {
            [audio addObject:[NSString stringWithFormat:@"aformat=channel_layouts=%@", layout]];
        }
    }
    if (sampleRate.intValue > 0) [audio addObject:[NSString stringWithFormat:@"aresample=%d:resampler=swr:filter_size=64", sampleRate.intValue]];
    return @{@"videoFilter":[video componentsJoinedByString:@","], @"audioFilter":[audio componentsJoinedByString:@","]};
}
+ (BOOL)supportsStreamingConversion { return [VPFFmpegLibrary supportsStreamingConversion]; }
@end
