#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface VPFFmpegOptions : NSObject
+ (BOOL)requiresPreparation:(NSDictionary *)options;
+ (nullable NSDictionary<NSString *, NSString *> *)filterGraphsForOptions:(NSDictionary *)options error:(NSError **)error;
+ (BOOL)supportsStreamingConversion;
@end
NS_ASSUME_NONNULL_END
