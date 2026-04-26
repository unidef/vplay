//
//  VPAppDelegate.h
//  vplay
//

#import <AppKit/AppKit.h>

@class VPWindowController;
@class VPConfigManager;

@interface VPAppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong, readonly) VPWindowController *windowController;
@property (nonatomic, strong, readonly) VPConfigManager *configManager;

@property (nonatomic, copy) NSDictionary *startupOptions;
/// A single input (kept for older call sites); `startupInputs` takes precedence.
@property (nonatomic, copy) NSString *startupInput;
/// Files, folders, playlists, disc folders or URLs to queue at launch.
@property (nonatomic, copy) NSArray<NSString *> *startupInputs;
@property (nonatomic) BOOL startupShuffle;
@property (nonatomic) BOOL showBuilderOnLaunch;

/// Display the Licenses & Open Source Acknowledgements window.
- (IBAction)showLicenseWindow:(id)sender;


@end
