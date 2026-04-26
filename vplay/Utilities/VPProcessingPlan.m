#import "VPProcessingPlan.h"
@implementation VPProcessingPlan
+ (NSDictionary *)resolvedOptions:(NSDictionary *)options error:(NSError **)error {
    NSMutableDictionary *result = [options mutableCopy];
    NSMutableArray *video = [NSMutableArray array];
    NSMutableArray *audio = [NSMutableArray array];
    NSMutableArray *native = [NSMutableArray arrayWithArray:options[@"nativeStages"] ?: @[]];
    if ([options[@"vf"] length]) [video addObject:options[@"vf"]];
    if ([options[@"af"] length]) [audio addObject:options[@"af"]];
    if ([options[@"effect"] length] && ![options[@"effect"] isEqual:@"none"]) [native addObject:@{@"type":@"effect", @"value":options[@"effect"]}];
    if ([options[@"shader"] length]) [native addObject:@{@"type":@"shader", @"value":options[@"shader"]}];
    BOOL sawNativeVideo = NO;
    for (NSDictionary *stage in options[@"effectChain"] ?: @[]) {
        NSString *type = stage[@"type"], *value = stage[@"value"];
        if ([type isEqual:@"video"]) {
            if (sawNativeVideo) {
                if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:80 userInfo:@{NSLocalizedDescriptionKey:@"Place FFmpeg video stages before native effects and shaders. Audio stages form an independent chain."}];
                return nil;
            }
            [video addObject:value];
        } else if ([type isEqual:@"audio"]) [audio addObject:value];
        else { sawNativeVideo = YES; [native addObject:stage]; }
    }
    result[@"vf"] = [video componentsJoinedByString:@","];
    result[@"af"] = [audio componentsJoinedByString:@","];
    result[@"nativeStages"] = native;
    [result removeObjectForKey:@"effectChain"];
    result[@"effect"] = @"none";
    result[@"shader"] = @"";
    return result;
}
@end
