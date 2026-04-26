//
//  VPExportManager.m
//  vplay
//

#import "VPExportManager.h"

@implementation VPExportManager

+ (BOOL)screenshot:(NSString *)outputPath atTime:(nullable NSNumber *)time error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:30
                                 userInfo:@{NSLocalizedDescriptionKey: @"Screenshot not yet implemented."}];
    }
    return NO;
}

+ (BOOL)exportTo:(NSString *)outputPath options:(NSDictionary *)options error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:40
                                 userInfo:@{NSLocalizedDescriptionKey: @"Export not yet implemented."}];
    }
    return NO;
}

+ (BOOL)trimInput:(NSString *)inputPath output:(NSString *)outputPath
             from:(NSNumber *)from to:(NSNumber *)to error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:50
                                 userInfo:@{NSLocalizedDescriptionKey: @"Trim not yet implemented."}];
    }
    return NO;
}

@end
