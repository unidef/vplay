//
//  VPExportManager.h
//  vplay
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPExportManager : NSObject

+ (BOOL)screenshot:(NSString *)outputPath atTime:(nullable NSNumber *)time error:(NSError **)error;
+ (BOOL)exportTo:(NSString *)outputPath options:(NSDictionary *)options error:(NSError **)error;
+ (BOOL)trimInput:(NSString *)inputPath output:(NSString *)outputPath
             from:(NSNumber *)from to:(NSNumber *)to error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
