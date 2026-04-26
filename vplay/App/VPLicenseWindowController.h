//
//  VPLicenseWindowController.h
//  vplay
//
//  Displays full open source licensing information, FFmpeg GPL/LGPL attribution,
//  and source code distribution compliance details for App Store review and end-users.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPLicenseWindowController : NSWindowController

/// Reveal the bundled FFmpeg source archive (ffmpeg-9.0.2.tar.xz) in Finder.
- (IBAction)revealSourceArchive:(nullable id)sender;

/// Copy all licensing attribution text to the macOS general pasteboard.
- (IBAction)copyLicenseInfo:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
