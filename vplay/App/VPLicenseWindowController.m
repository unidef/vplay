//
//  VPLicenseWindowController.m
//  vplay
//
//  Displays full open source licensing information, FFmpeg GPL/LGPL attribution,
//  and source code distribution compliance details for App Store review and end-users.
//

#import "VPLicenseWindowController.h"
#include <libavutil/avutil.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

@interface VPLicenseWindowController () <NSTextViewDelegate>

@property (nonatomic, strong) NSSegmentedControl *segmentedControl;
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) NSButton *revealSourceButton;
@property (nonatomic, strong) NSButton *clipboardButton;
@property (nonatomic, strong) NSButton *closeButton;

@end

@implementation VPLicenseWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 840, 620)
                                                   styleMask:NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Licenses & Open Source Acknowledgements — Mac Video Player";
    window.minSize = NSMakeSize(700, 500);
    window.releasedWhenClosed = NO;
    
    if ((self = [super initWithWindow:window])) {
        [self buildUI];
        [window center];
    }
    return self;
}

- (void)buildUI {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;
    
    // Header View
    NSView *headerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 540, 840, 80)];
    headerView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [contentView addSubview:headerView];
    
    // App Icon / Symbol
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 16, 48, 48)];
    NSImage *appIcon = [NSImage imageNamed:NSImageNameApplicationIcon];
    if (!appIcon) {
        if (@available(macOS 11.0, *)) {
            appIcon = [NSImage imageWithSystemSymbolName:@"play.circle.fill" accessibilityDescription:@"App Icon"];
        }
    }
    iconView.image = appIcon;
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [headerView addSubview:iconView];
    
    // Title
    _titleLabel = [NSTextField labelWithString:@"Mac Video Player"];
    _titleLabel.frame = NSMakeRect(80, 42, 500, 24);
    _titleLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    _titleLabel.textColor = NSColor.labelColor;
    [headerView addSubview:_titleLabel];
    
    // Subtitle
    _subtitleLabel = [NSTextField labelWithString:@"GNU GPLv3 Open Source Software • Incorporating FFmpeg Multimedia Framework (LGPL/GPL)"];
    _subtitleLabel.frame = NSMakeRect(80, 20, 650, 18);
    _subtitleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    _subtitleLabel.textColor = NSColor.secondaryLabelColor;
    [headerView addSubview:_subtitleLabel];
    
    // Segmented Control
    NSArray<NSString *> *tabs = @[
        @"Overview & Compliance",
        @"FFmpeg Runtime & Build",
        @"GNU GPL v3.0",
        @"GNU LGPL v2.1",
        @"FFmpeg Notice"
    ];
    _segmentedControl = [NSSegmentedControl segmentedControlWithLabels:tabs
                                                          trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                target:self
                                                                action:@selector(segmentChanged:)];
    _segmentedControl.frame = NSMakeRect(20, 505, 800, 28);
    _segmentedControl.selectedSegment = 0;
    _segmentedControl.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [contentView addSubview:_segmentedControl];
    
    // Scroll View and Text View
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 55, 800, 440)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.borderType = NSBezelBorder;
    _scrollView.drawsBackground = YES;
    
    _textView = [[NSTextView alloc] initWithFrame:_scrollView.contentView.bounds];
    _textView.minSize = NSMakeSize(0, _scrollView.contentView.bounds.size.height);
    _textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _textView.verticallyResizable = YES;
    _textView.horizontallyResizable = NO;
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.textContainer.widthTracksTextView = YES;
    _textView.textContainer.containerSize = NSMakeSize(_scrollView.contentView.bounds.size.width, FLT_MAX);
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.backgroundColor = NSColor.textBackgroundColor;
    _textView.textContainerInset = NSMakeSize(12, 12);
    
    _scrollView.documentView = _textView;
    [contentView addSubview:_scrollView];
    
    // Bottom Bar
    _revealSourceButton = [NSButton buttonWithTitle:@"Reveal Bundled FFmpeg Source…"
                                             target:self
                                             action:@selector(revealSourceArchive:)];
    _revealSourceButton.frame = NSMakeRect(20, 14, 250, 28);
    _revealSourceButton.bezelStyle = NSBezelStyleRounded;
    _revealSourceButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _revealSourceButton.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    _revealSourceButton.toolTip = @"Opens the Legal folder containing ffmpeg-9.0.2.tar.xz and build-ffmpeg.sh in Finder";
    [contentView addSubview:_revealSourceButton];
    
    _clipboardButton = [NSButton buttonWithTitle:@"Copy Attribution to Clipboard"
                                     target:self
                                     action:@selector(copyLicenseInfo:)];
    _clipboardButton.frame = NSMakeRect(280, 14, 220, 28);
    _clipboardButton.bezelStyle = NSBezelStyleRounded;
    _clipboardButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    _clipboardButton.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [contentView addSubview:_clipboardButton];
    
    _closeButton = [NSButton buttonWithTitle:@"Close"
                                      target:self
                                      action:@selector(closeWindow:)];
    _closeButton.frame = NSMakeRect(720, 14, 100, 28);
    _closeButton.bezelStyle = NSBezelStyleRounded;
    _closeButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    _closeButton.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    _closeButton.keyEquivalent = @"\r";
    [contentView addSubview:_closeButton];
    
    [self updateContentForSegment:0];
}

- (void)segmentChanged:(NSSegmentedControl *)sender {
    [self updateContentForSegment:sender.selectedSegment];
}

- (void)updateContentForSegment:(NSInteger)segment {
    NSAttributedString *content = nil;
    switch (segment) {
        case 0:
            content = [self overviewAttributedString];
            break;
        case 1:
            content = [self ffmpegRuntimeAttributedString];
            break;
        case 2:
            content = [self gplAttributedString];
            break;
        case 3:
            content = [self lgplAttributedString];
            break;
        case 4:
            content = [self ffmpegNoticeAttributedString];
            break;
        default:
            content = [self overviewAttributedString];
            break;
    }
    
    [self.textView.textStorage setAttributedString:content];
    [self.textView scrollPoint:NSMakePoint(0, 0)];
}

#pragma mark - Content Builders

- (NSAttributedString *)overviewAttributedString {
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] init];
    
    NSDictionary *h1 = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSDictionary *h2 = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSDictionary *body = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    NSDictionary *mono = @{
        NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    
    void (^append)(NSString *, NSDictionary *) = ^(NSString *text, NSDictionary *attrs) {
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    };
    
    append(@"Mac Video Player — Open Source Licensing & App Store Compliance\n\n", h1);
    
    append(@"1. Application License (GNU GPLv3)\n", h2);
    append(@"Mac Video Player is free, open-source software licensed under the terms of the GNU General Public License Version 3 (GNU GPLv3), or (at your option) any later version, as published by the Free Software Foundation.\n\n"
           @"Copyright © 2026 Mac Video Player contributors.\n"
           @"Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is not allowed. As free software, you have the freedom to run, inspect, modify, and redistribute this software.\n\n", body);
    
    append(@"2. FFmpeg Multimedia Framework & Derivative Libraries\n", h2);
    append(@"Mac Video Player incorporates and dynamically links to the FFmpeg multimedia project (version 9.0.2), Copyright © 2000-2026 the FFmpeg developers. FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later (LGPLv2.1+) / GNU General Public License version 2 or later (GPLv2+).\n\n"
           @"The following FFmpeg derivative libraries are utilized by Mac Video Player:\n"
           @"• libavcodec (v63): Highly optimized audio, video, and subtitle decoders, including hardware acceleration via Apple VideoToolbox (H.264, HEVC, ProRes, VP9, AV1, AAC, FLAC, AC3, etc.).\n"
           @"• libavformat (v63): Demuxers and muxers for container formats (MP4, MKV, WebM, AVI, TS, M3U8/HLS, FLV) and network streaming protocols.\n"
           @"• libavfilter (v12): Complex media filtering framework powering real-time equalization, dynamic audio normalization, volume adjustment, deinterlacing, and custom filter graphs.\n"
           @"• libavutil (v61): Core multimedia data structures, mathematical utilities, pixel formats, and sample layouts.\n"
           @"• libswscale (v10): High-performance color space transformation (YUV420p, YUV422p, NV12, P010 to RGB/RGBA) and image scaling.\n"
           @"• libswresample (v7): Audio resampling, channel matrix manipulation, downmixing, and audio format conversion.\n\n", body);
    
    append(@"3. App Store Compliance & Section 6 Source Code Distribution\n", h2);
    append(@"In compliance with Section 6 of the GNU General Public License (GPLv3) and Section 6 of the GNU Lesser General Public License (LGPLv2.1):\n"
           @"• Source Code Availability: The complete, corresponding source code for Mac Video Player and FFmpeg is freely accessible.\n"
           @"• Bundled FFmpeg Source Archive: The exact, unmodified FFmpeg 9.0.2 source code archive (ffmpeg-9.0.2.tar.xz) is bundled directly inside this application bundle under Contents/Resources/Legal/.\n"
           @"• Universal Build Script: The build script (build-ffmpeg.sh) used to compile the bundled libraries is included alongside the archive.\n"
           @"• Right to Re-link and Modify: Users are legally entitled to modify and replace the FFmpeg shared libraries (.dylib) for their own use, and reverse engineer Mac Video Player as needed to debug modifications, as permitted by the LGPL and GPL.\n"
           @"• SHA-256 Checksum: 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e\n\n", body);
    
    append(@"4. Disclaimer of Warranty\n", h2);
    append(@"THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM \"AS IS\" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.\n\n", body);
    
    append(@"To view the complete text of each license, select the corresponding tab above.\n", mono);
    
    return mas;
}

- (NSAttributedString *)ffmpegRuntimeAttributedString {
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] init];
    
    NSDictionary *h1 = @{
        NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSDictionary *h2 = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSDictionary *body = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    NSDictionary *mono = @{
        NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    
    void (^append)(NSString *, NSDictionary *) = ^(NSString *text, NSDictionary *attrs) {
        [mas appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    };
    
    append(@"Live FFmpeg Runtime & Compilation Details\n\n", h1);
    
    const char *ff_ver = av_version_info();
    const char *ff_lic = avutil_license();
    const char *ff_cfg = avutil_configuration();
    
    unsigned u_ver = avutil_version();
    unsigned c_ver = avcodec_version();
    unsigned f_ver = avformat_version();
    unsigned fil_ver = avfilter_version();
    unsigned sws_ver = swscale_version();
    unsigned swr_ver = swresample_version();
    
    append(@"Runtime Verification:\n", h2);
    append([NSString stringWithFormat:@"• FFmpeg Release: %s\n", ff_ver], body);
    append([NSString stringWithFormat:@"• Core License: %s\n", ff_lic], body);
    append([NSString stringWithFormat:@"• libavutil: %u.%u.%u (License: %s)\n", AV_VERSION_MAJOR(u_ver), AV_VERSION_MINOR(u_ver), AV_VERSION_MICRO(u_ver), avutil_license()], body);
    append([NSString stringWithFormat:@"• libavcodec: %u.%u.%u (License: %s)\n", AV_VERSION_MAJOR(c_ver), AV_VERSION_MINOR(c_ver), AV_VERSION_MICRO(c_ver), avcodec_license()], body);
    append([NSString stringWithFormat:@"• libavformat: %u.%u.%u (License: %s)\n", AV_VERSION_MAJOR(f_ver), AV_VERSION_MINOR(f_ver), AV_VERSION_MICRO(f_ver), avformat_license()], body);
    append([NSString stringWithFormat:@"• libavfilter: %u.%u.%u (License: %s)\n", AV_VERSION_MAJOR(fil_ver), AV_VERSION_MINOR(fil_ver), AV_VERSION_MICRO(fil_ver), avfilter_license()], body);
    append([NSString stringWithFormat:@"• libswscale: %u.%u.%u\n", AV_VERSION_MAJOR(sws_ver), AV_VERSION_MINOR(sws_ver), AV_VERSION_MICRO(sws_ver)], body);
    append([NSString stringWithFormat:@"• libswresample: %u.%u.%u\n\n", AV_VERSION_MAJOR(swr_ver), AV_VERSION_MINOR(swr_ver), AV_VERSION_MICRO(swr_ver)], body);
    
    append(@"Linked Libraries on Disk:\n", h2);
    NSString *fwPath = [NSBundle.mainBundle.privateFrameworksPath stringByResolvingSymlinksInPath];
    append([NSString stringWithFormat:@"Location: %@\n", fwPath ?: @"Contents/Frameworks"], mono);
    append(@"  - libavutil.61.dylib\n"
           @"  - libswresample.7.dylib\n"
           @"  - libavcodec.63.dylib\n"
           @"  - libavformat.63.dylib\n"
           @"  - libswscale.10.dylib\n"
           @"  - libavfilter.12.dylib\n\n", mono);
    
    append(@"FFmpeg Build Configuration Flags:\n", h2);
    append([NSString stringWithFormat:@"%s\n\n", ff_cfg], mono);
    
    return mas;
}

- (NSAttributedString *)gplAttributedString {
    NSString *path = [NSBundle.mainBundle pathForResource:@"LICENSE.GPLv3" ofType:@"txt"];
    if (!path) {
        path = [NSBundle.mainBundle pathForResource:@"LICENSE" ofType:@""];
    }
    if (!path) {
        NSString *devPath = @"/Users/jon/Developer/vplay/LICENSE";
        if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) path = devPath;
    }
    NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!text.length) {
        text = @"GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n\n"
               @"Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>\n"
               @"Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is not allowed.\n\n"
               @"[Full GNU GPL v3 text bundled in application]";
    }
    
    NSDictionary *mono = @{
        NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    return [[NSAttributedString alloc] initWithString:text attributes:mono];
}

- (NSAttributedString *)lgplAttributedString {
    NSString *path = [NSBundle.mainBundle pathForResource:@"COPYING.LGPLv2.1" ofType:@"txt"];
    if (!path) {
        path = [NSBundle.mainBundle pathForResource:@"COPYING.LGPLv2.1" ofType:@"" inDirectory:@"Legal"];
    }
    if (!path) {
        path = [NSBundle.mainBundle pathForResource:@"COPYING.LGPLv2.1" ofType:@"" inDirectory:@"FFmpeg Legal"];
    }
    if (!path) {
        NSString *devPath = @"/Users/jon/Developer/vplay/Vendor/FFmpeg/Legal/COPYING.LGPLv2.1";
        if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) path = devPath;
    }
    NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!text.length) {
        text = @"GNU LESSER GENERAL PUBLIC LICENSE\nVersion 2.1, February 1999\n\n"
               @"Copyright (C) 1991, 1999 Free Software Foundation, Inc.\n"
               @"51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA\n"
               @"Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is not allowed.\n\n"
               @"[Full GNU LGPL v2.1 text bundled in application under Legal/COPYING.LGPLv2.1]";
    }
    
    NSDictionary *mono = @{
        NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    return [[NSAttributedString alloc] initWithString:text attributes:mono];
}

- (NSAttributedString *)ffmpegNoticeAttributedString {
    NSString *noticePath = [NSBundle.mainBundle pathForResource:@"NOTICE" ofType:@"txt" inDirectory:@"Legal"];
    if (!noticePath) {
        noticePath = [NSBundle.mainBundle pathForResource:@"NOTICE" ofType:@"txt" inDirectory:@"FFmpeg Legal"];
    }
    if (!noticePath) {
        NSString *devPath = @"/Users/jon/Developer/vplay/Vendor/FFmpeg/Legal/NOTICE.txt";
        if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) noticePath = devPath;
    }
    NSString *noticeText = noticePath ? [NSString stringWithContentsOfFile:noticePath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!noticeText.length) {
        noticeText = @"vplay includes FFmpeg 9.0.2, Copyright (c) 2000-2026 the FFmpeg developers.\n"
                     @"https://ffmpeg.org/\n\n"
                     @"This software uses FFmpeg code licensed under the GNU Lesser General Public License version 2.1 or later (LGPL).\n";
    }
    
    NSString *licPath = [NSBundle.mainBundle pathForResource:@"LICENSE" ofType:@"md" inDirectory:@"Legal"];
    if (!licPath) {
        licPath = [NSBundle.mainBundle pathForResource:@"LICENSE" ofType:@"md" inDirectory:@"FFmpeg Legal"];
    }
    if (!licPath) {
        NSString *devPath = @"/Users/jon/Developer/vplay/Vendor/FFmpeg/Legal/LICENSE.md";
        if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) licPath = devPath;
    }
    NSString *licText = licPath ? [NSString stringWithContentsOfFile:licPath encoding:NSUTF8StringEncoding error:nil] : @"";
    
    NSMutableString *combined = [NSMutableString string];
    if (noticeText.length) {
        [combined appendString:@"================================================================================\n"];
        [combined appendString:@"FFMPEG NOTICE & REBUILDING INSTRUCTIONS\n"];
        [combined appendString:@"================================================================================\n\n"];
        [combined appendString:noticeText];
        [combined appendString:@"\n\n"];
    }
    if (licText.length) {
        [combined appendString:@"================================================================================\n"];
        [combined appendString:@"FFMPEG COMPONENT LICENSING DETAILS\n"];
        [combined appendString:@"================================================================================\n\n"];
        [combined appendString:licText];
    }
    
    NSDictionary *mono = @{
        NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.textColor
    };
    return [[NSAttributedString alloc] initWithString:combined attributes:mono];
}

#pragma mark - Actions

- (IBAction)revealSourceArchive:(id)sender {
    NSString *archivePath = [NSBundle.mainBundle pathForResource:@"ffmpeg-9.0.2" ofType:@"tar.xz" inDirectory:@"Legal"];
    if (!archivePath) {
        archivePath = [NSBundle.mainBundle pathForResource:@"ffmpeg-9.0.2" ofType:@"tar.xz" inDirectory:@"FFmpeg Legal"];
    }
    if (archivePath && [[NSFileManager defaultManager] fileExistsAtPath:archivePath]) {
        [[NSWorkspace sharedWorkspace] selectFile:archivePath inFileViewerRootedAtPath:[archivePath stringByDeletingLastPathComponent]];
    } else {
        NSString *legalDir = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Legal"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:legalDir]) {
            legalDir = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"FFmpeg Legal"];
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:legalDir]) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:legalDir]];
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Source Archive";
            alert.informativeText = @"The source archive is located in the application bundle under Contents/Resources/Legal/ffmpeg-9.0.2.tar.xz.";
            [alert runModal];
        }
    }
}

- (IBAction)copyLicenseInfo:(id)sender {
    NSString *text = self.textView.string;
    if (text.length) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:text forType:NSPasteboardTypeString];
    }
}

- (IBAction)closeWindow:(id)sender {
    [self.window performClose:sender];
}

@end
