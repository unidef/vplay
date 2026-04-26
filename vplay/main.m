#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "VPCLIDispatcher.h"
#import "VPAppDelegate.h"
#import "VPConfigManager.h"

static void PrintGuiUsage(void) {
    fprintf(stderr, "Usage: vplay [INPUT...] [--shuffle] [--repeat off|all|one] [--config-load config.json]\n"
                    "       vplay gui [INPUT...] [--config-load config.json]\n"
                    "       vplay configure [config.json] [--input FILE_OR_URL]\n"
                    "Run 'vplay help' for every command and option.\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // `vplay` alone, `vplay gui`, `vplay configure` and `vplay FILE...` open the Cocoa app.
        // Everything else is a command-line subcommand handled by the dispatcher.
        NSString *first = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"gui";

        BOOL builder = [first isEqual:@"configure"];
        BOOL explicitGui = [first isEqual:@"gui"];
        // A first argument that is not a subcommand (and is not a flag) is media to play, e.g. `vplay movie.mkv`.
        // macOS also passes "-psn_…" or "-NS…" arguments when launching from Finder; those are ignored.
        BOOL implicitGui = argc > 1 && !builder && !explicitGui && ![VPCLIDispatcher isCommand:first] && ![first hasPrefix:@"-"];
        BOOL launchedByFinder = argc > 1 && ([first hasPrefix:@"-psn_"] || [first hasPrefix:@"-NS"] || [first hasPrefix:@"-Apple"]);
        if (argc > 1 && !builder && !explicitGui && !implicitGui && !launchedByFinder) return [VPCLIDispatcher dispatchWithArgc:argc argv:argv];
        // `vplay FILE...` and `vplay gui FILE...` are the same as `vplay play FILE...`, which understands every option.
        if (implicitGui || (explicitGui && argc > 2)) {
            const char **rewritten = calloc((size_t)argc + 2, sizeof(char *));
            rewritten[0] = argv[0]; rewritten[1] = "play";
            int n = 2;
            for (int i = implicitGui ? 1 : 2; i < argc; i++) rewritten[n++] = argv[i];
            return [VPCLIDispatcher dispatchWithArgc:n argv:rewritten];
        }

        NSString *configPath = nil;
        NSMutableArray<NSString *> *inputs = [NSMutableArray array];
        BOOL shuffle = NO;
        NSString *repeat = nil;
        if (!launchedByFinder) {
            for (int i = (explicitGui || builder) ? 2 : 1; i < argc; i++) {
                NSString *arg = [NSString stringWithUTF8String:argv[i]];
                if (([arg isEqual:@"--config-load"] || [arg isEqual:@"--input"] || [arg isEqual:@"--repeat"]) && i + 1 < argc) {
                    NSString *value = [NSString stringWithUTF8String:argv[++i]];
                    if ([arg isEqual:@"--input"]) [inputs addObject:value];
                    else if ([arg isEqual:@"--repeat"]) repeat = value;
                    else configPath = value;
                } else if ([arg isEqual:@"--shuffle"]) {
                    shuffle = YES;
                } else if (![arg hasPrefix:@"-"]) {
                    // The configure command takes its JSON file first; every other positional is media.
                    if (builder && !configPath && inputs.count == 0 && [arg.pathExtension.lowercaseString isEqual:@"json"]) configPath = arg;
                    else [inputs addObject:arg];
                } else {
                    PrintGuiUsage();
                    return 1;
                }
            }
        }
        VPConfigManager *config = [VPConfigManager new];
        NSError *error = nil;
        if (configPath && ![config loadFromPath:configPath.stringByExpandingTildeInPath error:&error]) {
            fprintf(stderr, "vplay: %s\n", error.localizedDescription.UTF8String); return 1;
        }
        NSMutableDictionary *options = [[config toDictionary] mutableCopy];
        if (inputs.count == 1) options[@"input"] = inputs.firstObject;
        if (shuffle) options[@"shuffle"] = @YES;
        if (repeat) options[@"repeat"] = repeat;
        VPConfigManager *validator = [VPConfigManager new];
        if (![validator applyDictionary:options error:&error]) { fprintf(stderr, "vplay: %s\n", error.localizedDescription.UTF8String); return 1; }

        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        VPAppDelegate *delegate = [VPAppDelegate new];
        delegate.startupOptions = options;
        if (!inputs.count && options[@"input"]) [inputs addObject:options[@"input"]];
        delegate.startupInputs = inputs;
        delegate.startupShuffle = shuffle;
        delegate.showBuilderOnLaunch = builder;
        app.delegate = delegate;
        [app run];
        return 0;
    }
}
