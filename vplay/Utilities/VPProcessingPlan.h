#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface VPProcessingPlan : NSObject
+ (nullable NSDictionary *)resolvedOptions:(NSDictionary *)options error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
