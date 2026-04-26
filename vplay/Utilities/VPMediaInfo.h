//
//  VPMediaInfo.h
//  vplay
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPMediaInfo : NSObject

/// Returns info dictionary for a media file (duration, video tracks, audio tracks)
+ (nullable NSDictionary *)infoForPathOrURL:(NSString *)pathOrURL;

@end

NS_ASSUME_NONNULL_END
