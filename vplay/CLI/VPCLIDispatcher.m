//
//  VPCLIDispatcher.m
//  vplay
//

#import "VPCLIDispatcher.h"
#import "VPPlaybackEngine.h"
#import "VPAudioDeviceManager.h"
#import "VPEffectPipeline.h"
#import "VPExportManager.h"
#import "VPMediaInfo.h"
#import "VPConfigManager.h"
#import "VPURLHelper.h"
#import "VPFFmpegLibrary.h"
#import <AVKit/AVKit.h>
#import "VPAppDelegate.h"
#import "VPPlaylist.h"
#import "VPDiscSupport.h"
#import "VPMediaProbe.h"

static void print_usage(void) {
    printf("Mac Video Player — a media player for macOS\n"
           "\nGETTING STARTED\n"
           "  vplay                              Open the player (black stage, logo and menu panel)\n"
           "  vplay movie.mkv                    Play a file     (also: vplay play movie.mkv)\n"
           "  vplay a.mp3 b.flac ~/Music --shuffle   Queue files and folders, shuffled\n"
           "  vplay disc /Volumes/MY_DVD         Play a DVD, Blu-ray, VCD or SVCD (folder, volume or .iso)\n"
           "  vplay configure                    Open the configuration builder\n"
           "\nCOMMANDS\n"
           "  play INPUT... [OPTIONS]            Play files, folders, playlists, discs or URLs\n"
           "  gui [INPUT...] [--config-load F]   Same as play, with a JSON configuration\n"
           "  configure [JSON] [--input FILE]    Cocoa configuration builder: chain FFmpeg, shader and audio effects\n"
           "  disc [PATH]                        Play a disc (default: the first disc mounted)\n"
           "  disc-list                          List mounted discs and their type\n"
           "  playlist create OUT.m3u INPUT... [--shuffle]   Write an M3U playlist\n"
           "  playlist show INPUT... [--shuffle]             Print what a playlist would contain\n"
           "  tracks INPUT                       List video, audio and subtitle tracks\n"
           "  info INPUT                         Print media metadata as JSON\n"
           "  ffmpeg ARGS...                     Built-in single-input conversion\n"
           "  device-list  device-set UID        List / choose the audio output device\n"
           "  effect-list                        List the built-in video effects\n"
           "  config-save FILE                   Save the current configuration as JSON\n"
           "  help                               This text\n"
           "\nPLAYLIST OPTIONS\n"
           "  --shuffle                          Play in random order, every item once per pass\n"
           "  --repeat off|all|one               Repeat behaviour (default off)\n"
           "  --playlist FILE                    Add an .m3u / .m3u8 / .pls playlist (repeatable)\n"
           "\nDISPLAY OPTIONS\n"
           "  --fps                              Show the frames-per-second display\n"
           "  --visualizer                       Show the audio visualizer over video (always on for audio files)\n"
           "  --visualizer-style bars|mirror|ring\n"
           "  --no-metadata                      Do not show the title card when playback starts\n"
           "  --post \"brightness=0.1,contrast=1.2,saturation=1.3\"\n"
           "                                     Post-processing: brightness contrast saturation hue gamma\n"
           "                                     exposure warmth sharpness noiseReduction blur vignette\n"
           "\nPLAYBACK OPTIONS\n"
           "  --config-load FILE                 Load JSON (command-line flags take precedence)\n"
           "  --loop  --mute                     Repeat the current item / mute\n"
           "  --volume 0..1  --rate N            Volume / playback speed\n"
           "  --audio UID                        System output device\n"
           "  --effect NAME[:AMOUNT]             Core Image effect (see effect-list), e.g. sepia:0.6\n"
           "  --shader FILE                      Core Image color kernel\n"
           "  --backend auto|native|prepared\n"
           "  --audio-sample-rate auto|max|HZ    Output device sample rate\n"
           "  --deinterlace  --inverse-telecine  --field-order auto|tff|bff\n"
           "  --upscale 1..4  --scaler metal|lanczos\n"
           "  --vf FILTER  --af FILTER           FFmpeg video / audio filter graphs\n"
           "  --audio-layout auto|stereo|5.1     5.1 synthesizes surround from stereo\n"
           "  --ffmpeg                           Use built-in FFmpeg conversion\n"
           "\nIn the player: Tab shows the menu panel, Space pauses, N/P next/previous, S shuffle, F full screen.\n"
           "See README.md for the full guide, examples and limitations.\n");
}

static NSString * stringFromArgv(const char *cstr) {
    return [NSString stringWithUTF8String:cstr ?: ""];
}

#pragma mark - Command Handlers

/// Parses "brightness=0.1,contrast=1.2" into a post-processing dictionary.
static NSDictionary *ParsePostSpec(NSString *spec, NSString **problem) {
    NSSet *allowed = [NSSet setWithArray:@[@"brightness", @"contrast", @"saturation", @"hue", @"gamma", @"exposure", @"warmth", @"sharpness", @"noiseReduction", @"blur", @"vignette"]];
    NSMutableDictionary *post = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"enabled"];
    for (NSString *pair in [spec componentsSeparatedByString:@","]) {
        NSArray *parts = [pair componentsSeparatedByString:@"="];
        if (parts.count != 2 || ![allowed containsObject:parts[0]]) { if (problem) *problem = [NSString stringWithFormat:@"unknown post-processing setting '%@'", pair]; return nil; }
        post[parts[0]] = @([parts[1] doubleValue]);
    }
    return post;
}

/// Starts the Cocoa player with the given inputs. Never returns until the app quits.
static int RunPlayer(NSArray<NSString *> *inputs, NSDictionary *options, BOOL shuffle) {
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    VPAppDelegate *delegate = [VPAppDelegate new];
    delegate.startupOptions = options;
    delegate.startupInputs = inputs;
    delegate.startupShuffle = shuffle;
    app.delegate = delegate;
    [app run];
    return 0;
}

static int handlePlay(int argc, const char *const argv[]) {
    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    BOOL shuffle = NO;
    for (int i = 2; i < argc; ++i) {
        NSString *arg = stringFromArgv(argv[i]);
        if (![arg hasPrefix:@"--"]) { [inputs addObject:arg]; continue; }
        if ([@[@"--shader", @"--vf", @"--af", @"--audio-layout", @"--ffplay-arg", @"--audio-sample-rate", @"--scaler", @"--field-order", @"--upscale", @"--backend", @"--repeat", @"--visualizer-style", @"--playlist", @"--post"] containsObject:arg]) {
            if (i + 1 >= argc) { fprintf(stderr, "vplay: %s requires a value.\n", arg.UTF8String); return 1; }
            NSString *value = stringFromArgv(argv[++i]);
            if ([arg isEqual:@"--ffplay-arg"]) {
                NSMutableArray *args = [opts[@"ffplayArguments"] mutableCopy] ?: [NSMutableArray array];
                [args addObject:value]; opts[@"ffplayArguments"] = args;
            } else if ([arg isEqual:@"--playlist"]) {
                [inputs addObject:value];
            } else if ([arg isEqual:@"--post"]) {
                NSString *problem = nil;
                NSDictionary *post = ParsePostSpec(value, &problem);
                if (!post) { fprintf(stderr, "vplay: %s.\n", problem.UTF8String); return 1; }
                opts[@"postProcessing"] = post;
            } else {
                NSString *key = @{@"--audio-layout":@"audioLayout", @"--audio-sample-rate":@"audioSampleRate", @"--field-order":@"fieldOrder", @"--backend":@"playbackBackend", @"--visualizer-style":@"visualizerStyle"}[arg] ?: [arg substringFromIndex:2];
                if ([key isEqual:@"upscale"]) {
                    NSScanner *scanner = [NSScanner scannerWithString:value];
                    double factor = 0;
                    if (![scanner scanDouble:&factor] || !scanner.isAtEnd) { fprintf(stderr, "vplay: invalid upscale factor.\n"); return 1; }
                    opts[key] = @(factor);
                } else opts[key] = value;
            }
        }
        else if ([arg isEqualToString:@"--loop"]) opts[@"loop"] = @YES;
        else if ([arg isEqualToString:@"--mute"]) opts[@"mute"] = @YES;
        else if ([arg isEqualToString:@"--shuffle"]) shuffle = YES;
        else if ([arg isEqualToString:@"--fps"]) opts[@"showFPS"] = @YES;
        else if ([arg isEqualToString:@"--visualizer"]) opts[@"visualizer"] = @YES;
        else if ([arg isEqualToString:@"--no-metadata"]) opts[@"showMetadata"] = @NO;
        else if ([arg isEqualToString:@"--audio"]) { if (i+1>=argc) { fprintf(stderr, "--audio requires deviceUID.\n"); return 1; } opts[@"audio"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--effect"]) { if (i+1>=argc) { fprintf(stderr, "--effect requires name.\n"); return 1; } opts[@"effect"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--rate"]) { if (i+1>=argc) { fprintf(stderr, "--rate requires value.\n"); return 1; } opts[@"rate"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--volume"]) { if (i+1>=argc) { fprintf(stderr, "--volume requires value.\n"); return 1; } opts[@"volume"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--ffmpeg"]) opts[@"ffmpeg"] = @YES;
        else if ([arg isEqualToString:@"--ffmpeg-metal"]) opts[@"ffmpegMetal"] = @YES;
        else if ([arg isEqualToString:@"--libav"]) opts[@"libav"] = @YES;
        else if ([arg isEqualToString:@"--preview"]) opts[@"preview"] = @YES;
        else if ([arg isEqualToString:@"--hq"]) opts[@"hq"] = @YES;
        else if ([arg isEqualToString:@"--deinterlace"]) opts[@"deinterlace"] = @YES;
        else if ([arg isEqualToString:@"--inverse-telecine"] || [arg isEqualToString:@"--reverse-telecine"] || [arg isEqualToString:@"--reverse-telecline"]) opts[@"inverseTelecine"] = @YES;
        else if ([arg isEqualToString:@"--post-processing-level"] || [arg isEqualToString:@"--pp-level"]) {
            if (i+1>=argc) { fprintf(stderr, "%s requires value (0.0 - 1.0 or 0 - 100).\n", arg.UTF8String); return 1; }
            double val = stringFromArgv(argv[++i]).doubleValue;
            if (val > 1.0) val /= 100.0;
            opts[@"postProcessingLevel"] = @(val);
        }
        else if ([arg isEqualToString:@"--quality-preset"] || [arg isEqualToString:@"--video-quality-preset"]) {
            if (i+1>=argc) { fprintf(stderr, "%s requires preset name.\n", arg.UTF8String); return 1; }
            opts[@"videoQualityPreset"] = stringFromArgv(argv[++i]);
        }
        else if ([arg isEqualToString:@"--supersample"]) { if (i+1>=argc) { fprintf(stderr, "--supersample requires N.\n"); return 1; } opts[@"supersample"] = @(stringFromArgv(argv[++i]).intValue); }
        else if ([arg isEqualToString:@"--threads"]) { if (i+1>=argc) { fprintf(stderr, "--threads requires N.\n"); return 1; } opts[@"threads"] = @(stringFromArgv(argv[++i]).intValue); }
        else if ([arg isEqualToString:@"--rgb"]) { if (i+1>=argc) { fprintf(stderr, "--rgb requires r,g,b.\n"); return 1; } opts[@"rgb"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--brightness"]) { if (i+1>=argc) { fprintf(stderr, "--brightness requires value.\n"); return 1; } opts[@"brightness"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--contrast"]) { if (i+1>=argc) { fprintf(stderr, "--contrast requires value.\n"); return 1; } opts[@"contrast"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--saturation"]) { if (i+1>=argc) { fprintf(stderr, "--saturation requires value.\n"); return 1; } opts[@"saturation"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--hue"]) { if (i+1>=argc) { fprintf(stderr, "--hue requires degrees.\n"); return 1; } opts[@"hue"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--eq"]) { if (i+1>=argc) { fprintf(stderr, "--eq requires spec.\n"); return 1; } opts[@"eq"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--reverb"]) { if (i+1>=argc) { fprintf(stderr, "--reverb requires 0..100.\n"); return 1; } opts[@"reverb"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--config-load"]) { if (i+1>=argc) { fprintf(stderr, "--config-load requires path.\n"); return 1; } opts[@"configLoadPath"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--keymap"]) { if (i+1>=argc) { fprintf(stderr, "--keymap requires spec.\n"); return 1; } opts[@"keymapSpec"] = stringFromArgv(argv[++i]); }
        else { fprintf(stderr, "Unknown option: %s\nRun 'vplay help' for the list of options.\n", argv[i]); return 1; }
    }

    for (NSString *input in inputs) {
        NSURL *url = [VPURLHelper urlFromString:input];
        if (!url) { fprintf(stderr, "Invalid path or URL: %s\n", input.UTF8String); return 1; }
        if (url.isFileURL && ![NSFileManager.defaultManager isReadableFileAtPath:url.path]) { fprintf(stderr, "vplay: cannot read %s\n", input.UTF8String); return 1; }
    }
    VPConfigManager *config = [VPConfigManager new];
    NSError *configError = nil;
    if (opts[@"configLoadPath"] && ![config loadFromPath:[opts[@"configLoadPath"] stringByExpandingTildeInPath] error:&configError]) {
        fprintf(stderr, "vplay: %s\n", configError.localizedDescription.UTF8String); return 1;
    }
    [opts removeObjectForKey:@"configLoadPath"];
    NSMutableDictionary *merged = [[config toDictionary] mutableCopy];
    [merged addEntriesFromDictionary:opts];
    if (opts[@"audio"]) merged[@"audioDevice"] = opts[@"audio"];
    if (shuffle) merged[@"shuffle"] = @YES;
    for (NSString *key in @[@"ffmpegMetal", @"libav", @"preview", @"hq", @"supersample", @"threads", @"rgb", @"brightness", @"contrast", @"saturation", @"hue", @"eq", @"reverb", @"keymapSpec"]) {
        if (opts[key]) { fprintf(stderr, "vplay: unsupported legacy option --%s; use --post for picture adjustments, or --vf / --af.\n", key.UTF8String); return 1; }
    }
    if (![config applyDictionary:merged error:&configError]) {
        fprintf(stderr, "vplay: %s\n", configError.localizedDescription.UTF8String); return 1;
    }
    return RunPlayer(inputs, merged, shuffle);
}

static int handleDisc(int argc, const char *const argv[]) {
    NSMutableArray *rest = [NSMutableArray array];
    BOOL shuffle = NO;
    for (int i = 2; i < argc; i++) {
        NSString *arg = stringFromArgv(argv[i]);
        if ([arg isEqual:@"--shuffle"]) shuffle = YES; else [rest addObject:arg];
    }
    NSURL *disc = rest.count ? [VPURLHelper urlFromString:rest.firstObject] : [VPDiscSupport mountedDiscs].firstObject;
    if (!disc) { fprintf(stderr, "vplay: no disc found. Insert a disc, or run: vplay disc /path/to/VIDEO_TS-parent-or-image.iso\n"); return 1; }
    VPDiscKind kind = [VPDiscSupport kindForURL:disc];
    if (kind == VPDiscKindNone && ![VPDiscSupport isDiscImage:disc]) { fprintf(stderr, "vplay: %s is not a DVD, Blu-ray, VCD or SVCD.\n", disc.path.UTF8String); return 1; }
    VPConfigManager *config = [VPConfigManager new];
    return RunPlayer(@[disc.path], [config toDictionary], shuffle);
}

static int handleDiscList(void) {
    NSArray *discs = [VPDiscSupport mountedDiscs];
    if (!discs.count) { printf("No discs are mounted.\n"); return 0; }
    for (NSURL *disc in discs) printf("%-8s %s\n", [VPDiscSupport nameForKind:[VPDiscSupport kindForURL:disc]].UTF8String, disc.path.UTF8String);
    return 0;
}

static int handlePlaylist(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "usage: vplay playlist create OUT.m3u INPUT... [--shuffle]\n       vplay playlist show INPUT... [--shuffle]\n"); return 1; }
    NSString *sub = stringFromArgv(argv[2]);
    BOOL create = [sub isEqual:@"create"];
    if (!create && ![sub isEqual:@"show"]) { fprintf(stderr, "vplay: unknown playlist command '%s'.\n", sub.UTF8String); return 1; }
    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    BOOL shuffle = NO;
    for (int i = 3; i < argc; i++) {
        NSString *arg = stringFromArgv(argv[i]);
        if ([arg isEqual:@"--shuffle"]) shuffle = YES; else [inputs addObject:arg];
    }
    NSString *output = nil;
    if (create) { if (inputs.count < 2) { fprintf(stderr, "vplay: playlist create needs an output file and at least one input.\n"); return 1; } output = inputs.firstObject; [inputs removeObjectAtIndex:0]; }
    VPPlaylist *playlist = [VPPlaylist new];
    playlist.shuffle = shuffle;
    [playlist addInputs:[VPPlaylist URLsFromArguments:inputs]];
    NSMutableArray<VPPlaylistItem *> *ordered = [NSMutableArray array];
    for (NSUInteger i = 0; i < playlist.items.count; i++) { VPPlaylistItem *item = [playlist advanceAutomatically:NO]; if (item) [ordered addObject:item]; }
    if (!ordered.count) { fprintf(stderr, "vplay: nothing playable was found.\n"); return 1; }
    if (!create) {
        for (NSUInteger i = 0; i < ordered.count; i++) printf("%3lu  %s\n", (unsigned long)i + 1, (ordered[i].url.isFileURL ? ordered[i].url.path : ordered[i].url.absoluteString).UTF8String);
        return 0;
    }
    NSMutableString *text = [NSMutableString stringWithString:@"#EXTM3U\n"];
    for (VPPlaylistItem *item in ordered) [text appendFormat:@"#EXTINF:-1,%@\n%@\n", item.title, item.url.isFileURL ? item.url.path : item.url.absoluteString];
    NSError *error = nil;
    if (![text writeToFile:output.stringByExpandingTildeInPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) { fprintf(stderr, "vplay: %s\n", error.localizedDescription.UTF8String); return 1; }
    printf("Wrote %lu items to %s%s\n", (unsigned long)ordered.count, output.UTF8String, shuffle ? " (shuffled)" : "");
    return 0;
}

static int handleTracks(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "tracks requires a path or URL.\n"); return 1; }
    NSURL *url = [VPURLHelper urlFromString:stringFromArgv(argv[2])];
    VPMediaProbe *probe = url ? [VPMediaProbe probeSynchronously:url] : nil;
    if (!probe) { fprintf(stderr, "vplay: could not inspect this media with the bundled FFmpeg libraries.\n"); return 9; }
    for (NSArray *group in @[@[@"Video", probe.videoTracks], @[@"Audio", probe.audioTracks], @[@"Subtitle", probe.subtitleTracks]]) {
        for (VPTrack *track in group[1]) printf("%-8s %ld  %s\n", [group[0] UTF8String], (long)track.index, track.displayName.UTF8String);
    }
    return 0;
}

static int handleSeek(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "seek requires seconds.\n"); return 1; }
    // In CLI mode without persistent state, seek is a no-op
    fprintf(stderr, "seek requires a running player instance.\n");
    return 1;
}

static int handleDeviceList(void) {
    NSArray *devices = [VPAudioDeviceManager listDevices];
    printf("%-32s  %-28s  %s\n", "DEVICE UID", "NAME", "TYPE");
    for (NSDictionary *d in devices) {
        BOOL isDefault = [d[@"default"] isEqualToString:@"YES"];
        printf("%-32s  %-28s  %s%s\n",
               [d[@"uid"] UTF8String],
               [d[@"name"] UTF8String],
               [d[@"type"] UTF8String],
               isDefault ? "\t(default)" : "");
    }
    return 0;
}

static int handleDeviceSet(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "device-set requires deviceUID.\n"); return 1; }
    NSString *uid = stringFromArgv(argv[2]);
    NSError *err = nil;
    BOOL ok = [VPAudioDeviceManager setOutputDeviceUID:uid error:&err];
    if (!ok) { fprintf(stderr, "Failed to set audio device: %s\n", err.localizedDescription.UTF8String); return 4; }
    return 0;
}

static int handleEffectList(void) {
    NSArray *effects = [VPEffectPipeline availableEffects];
    for (NSString *name in effects) { printf("%s\n", name.UTF8String); }
    return 0;
}

static int handleEffectSet(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "effect-set requires name.\n"); return 1; }
    NSString *spec = stringFromArgv(argv[2]);
    NSError *err = nil;
    BOOL ok = [VPEffectPipeline applyEffect:spec error:&err];
    if (!ok) { fprintf(stderr, "Failed to set effect: %s\n", err.localizedDescription.UTF8String); return 5; }
    return 0;
}

static int handleScreenshot(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "screenshot requires output path.\n"); return 1; }
    NSString *out = stringFromArgv(argv[2]);
    double time = NAN;
    for (int i = 3; i < argc; ++i) {
        NSString *arg = stringFromArgv(argv[i]);
        if ([arg isEqualToString:@"--time"]) {
            if (i+1>=argc) { fprintf(stderr, "--time requires seconds.\n"); return 1; }
            time = stringFromArgv(argv[++i]).doubleValue;
        } else { fprintf(stderr, "Unknown option: %s\n", argv[i]); return 1; }
    }
    NSError *err = nil;
    BOOL ok = [VPExportManager screenshot:out atTime:(isnan(time) ? nil : @(time)) error:&err];
    if (!ok) { fprintf(stderr, "Failed to screenshot: %s\n", err.localizedDescription.UTF8String); return 6; }
    return 0;
}

static int handleExport(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "export requires output path.\n"); return 1; }
    NSString *out = stringFromArgv(argv[2]);
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    for (int i = 3; i < argc; ++i) {
        NSString *arg = stringFromArgv(argv[i]);
        if ([arg isEqualToString:@"--from"]) { if (i+1>=argc) { fprintf(stderr, "--from requires seconds.\n"); return 1; } opts[@"from"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--to"]) { if (i+1>=argc) { fprintf(stderr, "--to requires seconds.\n"); return 1; } opts[@"to"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--effect"]) { if (i+1>=argc) { fprintf(stderr, "--effect requires spec.\n"); return 1; } opts[@"effect"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--bitrate"]) { if (i+1>=argc) { fprintf(stderr, "--bitrate requires bps.\n"); return 1; } opts[@"bitrate"] = @(stringFromArgv(argv[++i]).longLongValue); }
        else if ([arg isEqualToString:@"--size"]) { if (i+1>=argc) { fprintf(stderr, "--size requires WxH.\n"); return 1; } opts[@"size"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--fps"]) { if (i+1>=argc) { fprintf(stderr, "--fps requires value.\n"); return 1; } opts[@"fps"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--mp4"]) { opts[@"mp4"] = @YES; }
        else if ([arg isEqualToString:@"--ffmpeg"]) { opts[@"ffmpeg"] = @YES; }
        else if ([arg isEqualToString:@"--vcodec"]) { if (i+1>=argc) { fprintf(stderr, "--vcodec requires name.\n"); return 1; } opts[@"vcodec"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--acodec"]) { if (i+1>=argc) { fprintf(stderr, "--acodec requires name.\n"); return 1; } opts[@"acodec"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--abitrate"]) { if (i+1>=argc) { fprintf(stderr, "--abitrate requires bps.\n"); return 1; } opts[@"abitrate"] = @(stringFromArgv(argv[++i]).longLongValue); }
        else if ([arg isEqualToString:@"--rgb"]) { if (i+1>=argc) { fprintf(stderr, "--rgb requires r,g,b.\n"); return 1; } opts[@"rgb"] = stringFromArgv(argv[++i]); }
        else if ([arg isEqualToString:@"--brightness"]) { if (i+1>=argc) { fprintf(stderr, "--brightness requires value.\n"); return 1; } opts[@"brightness"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--contrast"]) { if (i+1>=argc) { fprintf(stderr, "--contrast requires value.\n"); return 1; } opts[@"contrast"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--saturation"]) { if (i+1>=argc) { fprintf(stderr, "--saturation requires value.\n"); return 1; } opts[@"saturation"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else if ([arg isEqualToString:@"--hue"]) { if (i+1>=argc) { fprintf(stderr, "--hue requires degrees.\n"); return 1; } opts[@"hue"] = @(stringFromArgv(argv[++i]).doubleValue); }
        else { fprintf(stderr, "Unknown option: %s\n", argv[i]); return 1; }
    }
    NSError *err = nil;
    BOOL ok = [VPExportManager exportTo:out options:opts error:&err];
    if (!ok) { fprintf(stderr, "Failed to export: %s\n", err.localizedDescription.UTF8String); return 7; }
    return 0;
}

static int handleTrim(int argc, const char *const argv[]) {
    if (argc < 5) { fprintf(stderr, "trim requires <input> <output> --from <s> --to <s>.\n"); return 1; }
    NSString *input = stringFromArgv(argv[2]);
    NSString *output = stringFromArgv(argv[3]);
    double from = NAN, to = NAN;
    for (int i = 4; i < argc; ++i) {
        NSString *arg = stringFromArgv(argv[i]);
        if ([arg isEqualToString:@"--from"]) { if (i+1>=argc) { fprintf(stderr, "--from requires seconds.\n"); return 1; } from = stringFromArgv(argv[++i]).doubleValue; }
        else if ([arg isEqualToString:@"--to"]) { if (i+1>=argc) { fprintf(stderr, "--to requires seconds.\n"); return 1; } to = stringFromArgv(argv[++i]).doubleValue; }
    }
    if (isnan(from) || isnan(to)) { fprintf(stderr, "trim requires --from and --to.\n"); return 1; }
    NSError *err = nil;
    BOOL ok = [VPExportManager trimInput:input output:output from:@(from) to:@(to) error:&err];
    if (!ok) { fprintf(stderr, "Failed to trim: %s\n", err.localizedDescription.UTF8String); return 8; }
    return 0;
}

static int handleInfo(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "info requires path or URL.\n"); return 1; }
    NSString *path = stringFromArgv(argv[2]);
    NSDictionary *info = [VPMediaInfo infoForPathOrURL:path];
    if (!info) { fprintf(stderr, "Failed to read info.\n"); return 9; }
    NSData *json = [NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    return 0;
}

static int handleFFmpegPlay(int argc, const char *const argv[]) {
    NSMutableArray *args = [NSMutableArray array];
    for (int i = 2; i < argc; i++) [args addObject:stringFromArgv(argv[i])];
    NSError *error = nil;
    if ([stringFromArgv(argv[1]) isEqual:@"ffmpeg-play"]) {
        fprintf(stderr, "vplay: use 'vplay play INPUT --backend prepared' for built-in FFmpeg playback.\n");
        return 1;
    }
    NSURL *input = nil, *output = nil; NSDictionary *options = nil;
    if (![VPFFmpegLibrary parseArguments:args input:&input output:&output options:&options error:&error] ||
        ![[VPFFmpegJob new] runInput:input output:output options:options error:&error]) {
        fprintf(stderr, "vplay: %s\n", error.localizedDescription.UTF8String); return 1;
    }
    return 0;
}

static int handleConfigSave(int argc, const char *const argv[]) {
    if (argc < 3) { fprintf(stderr, "config-save requires <path.json>.\n"); return 1; }
    NSString *path = stringFromArgv(argv[2]);
    VPConfigManager *config = [[VPConfigManager alloc] init];
    NSError *err = nil;
    BOOL ok = [config saveToPath:path error:&err];
    if (!ok) { fprintf(stderr, "Failed to save config: %s\n", err.localizedDescription.UTF8String); return 1; }
    return 0;
}

static int handleKeysDefaults(void) {
    NSString *spec = [VPConfigManager defaultKeymapSpec];
    printf("%s\n", spec.UTF8String);
    return 0;
}

#pragma mark - Dispatcher

@implementation VPCLIDispatcher

+ (BOOL)isCommand:(NSString *)name {
    static NSSet *commands;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        commands = [NSSet setWithArray:@[@"help", @"--help", @"-h", @"ffmpeg", @"play", @"pause", @"stop", @"seek", @"rate", @"volume", @"device-list", @"device-set", @"effect-list", @"effect-set", @"screenshot", @"export", @"trim", @"info", @"ffmpeg-play", @"config-save", @"keys-defaults", @"disc", @"disc-list", @"playlist", @"tracks", @"gui", @"configure"]];
    });
    return [commands containsObject:name.lowercaseString];
}

+ (int)dispatchWithArgc:(int)argc argv:(const char * _Nonnull const * _Nonnull)argv {
    if (argc < 2) { print_usage(); return 1; }

    NSString *cmd = stringFromArgv(argv[1]).lowercaseString;

    if ([@[@"help", @"--help", @"-h"] containsObject:cmd]) { print_usage(); return 0; }
    if ([cmd isEqualToString:@"ffmpeg"]) return handleFFmpegPlay(argc, argv);
    if ([cmd isEqualToString:@"play"])          return handlePlay(argc, argv);
    if ([cmd isEqualToString:@"pause"])          { fprintf(stderr, "pause requires a running player instance.\n"); return 1; }
    if ([cmd isEqualToString:@"stop"])           { fprintf(stderr, "stop requires a running player instance.\n"); return 1; }
    if ([cmd isEqualToString:@"seek"])           return handleSeek(argc, argv);
    if ([cmd isEqualToString:@"rate"])           { fprintf(stderr, "rate requires a running player instance.\n"); return 1; }
    if ([cmd isEqualToString:@"volume"])         { fprintf(stderr, "volume requires a running player instance.\n"); return 1; }
    if ([cmd isEqualToString:@"device-list"])    return handleDeviceList();
    if ([cmd isEqualToString:@"device-set"])     return handleDeviceSet(argc, argv);
    if ([cmd isEqualToString:@"effect-list"])    return handleEffectList();
    if ([cmd isEqualToString:@"effect-set"])     return handleEffectSet(argc, argv);
    if ([cmd isEqualToString:@"screenshot"])     return handleScreenshot(argc, argv);
    if ([cmd isEqualToString:@"export"])         return handleExport(argc, argv);
    if ([cmd isEqualToString:@"trim"])           return handleTrim(argc, argv);
    if ([cmd isEqualToString:@"info"])           return handleInfo(argc, argv);
    if ([cmd isEqualToString:@"ffmpeg-play"])    return handleFFmpegPlay(argc, argv);
    if ([cmd isEqualToString:@"config-save"])    return handleConfigSave(argc, argv);
    if ([cmd isEqualToString:@"keys-defaults"])  return handleKeysDefaults();
    if ([cmd isEqualToString:@"disc"])           return handleDisc(argc, argv);
    if ([cmd isEqualToString:@"disc-list"])      return handleDiscList();
    if ([cmd isEqualToString:@"playlist"])       return handlePlaylist(argc, argv);
    if ([cmd isEqualToString:@"tracks"])         return handleTracks(argc, argv);

    print_usage();
    return 1;
}

@end
