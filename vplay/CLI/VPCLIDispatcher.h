//
//  VPCLIDispatcher.h
//  vplay
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPCLIDispatcher : NSObject

/// YES if `name` is a vplay subcommand (anything else on the command line is treated as media to play).
+ (BOOL)isCommand:(NSString *)name;

/// Parse argv and dispatch the appropriate command. Returns exit code.
+ (int)dispatchWithArgc:(int)argc argv:(const char * _Nonnull const * _Nonnull)argv;

@end

NS_ASSUME_NONNULL_END
