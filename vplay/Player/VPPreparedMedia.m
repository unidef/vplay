#import "VPPreparedMedia.h"
#import "VPFFmpegOptions.h"
#import "VPFFmpegLibrary.h"
#import "VPLocalServer.h"

@interface VPPreparedMedia ()
@property (nonatomic, strong) VPFFmpegJob *task;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, strong) NSTimer *readyTimer;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finishedCallback;
@property (nonatomic) BOOL streaming;
@end

@implementation VPPreparedMedia

- (void)dealloc { [self cancel]; }

- (void)cancel {
    self.cancelled = YES;
    [self.readyTimer invalidate]; self.readyTimer = nil;
    if (self.directory) [VPLocalServer.shared unpublishDirectory:self.directory];
    if (self.task.running) [self.task cancel];           // the termination handler removes the directory
    else if (self.directory) [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
}

static NSError *PrepareError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"VPlayErrorDomain" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

- (void)prepareURL:(NSURL *)url options:(NSDictionary *)options completion:(void (^)(NSURL *, NSError *))completion {
    NSError *error = nil;
    if ([options[@"ffplayArguments"] count]) {
        completion(nil, PrepareError(81, @"Raw FFplay arguments are no longer supported. Use video/audio effect stages with the built-in FFmpeg converter.")); return;
    }
    NSMutableDictionary *filterOptions = [options mutableCopy];
    filterOptions[@"effect"] = @"none"; filterOptions[@"shader"] = @""; filterOptions[@"nativeStages"] = @[];
    if (![options[@"scaler"] isEqual:@"lanczos"]) filterOptions[@"upscale"] = @1;
    NSDictionary *filters = [VPFFmpegOptions filterGraphsForOptions:filterOptions error:&error];
    if (!filters) { completion(nil, error); return; }
    NSString *videoFilter = filters[@"videoFilter"], *audioFilter = filters[@"audioFilter"];
    BOOL fastStart = [VPFFmpegOptions supportsStreamingConversion] && ![options[@"audioOnly"] boolValue] && ![options[@"preparedFile"] boolValue];
    self.streaming = fastStart;
    // HLS audio is AAC, which tops out at 96 kHz. Higher output rates are produced by the audio device itself.
    if (fastStart && audioFilter.length) {
        NSMutableArray *kept = [NSMutableArray array];
        for (NSString *part in [audioFilter componentsSeparatedByString:@","]) if (![part hasPrefix:@"aresample="]) [kept addObject:part];
        audioFilter = [kept componentsJoinedByString:@","];
        if ([audioFilter containsString:@"2.1"]) {
            audioFilter = [audioFilter stringByAppendingString:@",aformat=channel_layouts=stereo"];
        }
    }

    self.directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"vplay-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:&error]) { completion(nil, error); return; }
    NSURL *directory = self.directory;

    // Interlaced DVD-style sources look combed after re-encoding; deinterlace only frames flagged as interlaced.
    NSString *ext = url.pathExtension.lowercaseString;
    if (fastStart && ([ext isEqual:@"ffconcat"] || [ext isEqual:@"vob"]) && ![videoFilter containsString:@"bwdif"]) {
        NSString *deint = @"bwdif=mode=send_frame:deint=interlaced";
        videoFilter = videoFilter.length ? [deint stringByAppendingFormat:@",%@", videoFilter] : deint;
    }

    NSMutableDictionary *conversion = [options mutableCopy];
    conversion[@"videoFilter"] = videoFilter ?: @"";
    conversion[@"audioFilter"] = audioFilter ?: @"";
    conversion[@"overwrite"] = @YES;
    NSURL *playlist = [self.directory URLByAppendingPathComponent:@"index.m3u8"];
    if (fastStart) {
        self.outputURL = playlist;
        conversion[@"format"] = @"hls";
        conversion[@"videoCodec"] = @"h264_videotoolbox";
        conversion[@"audioCodec"] = @"aac";
    } else {
        self.outputURL = [self.directory URLByAppendingPathComponent:@"prepared.mov"];
        conversion[@"format"] = @"mov";
        conversion[@"videoCodec"] = @"mpeg4";
        conversion[@"audioCodec"] = @"pcm_s24le";
    }
    VPFFmpegJob *task = [VPFFmpegJob new];
    self.task = task;

    __weak typeof(self) weakSelf = self;
    void (^finish)(NSURL *, NSError *) = ^(NSURL *result, NSError *failure) {
        VPPreparedMedia *owner = weakSelf;
        if (!owner || owner.finishedCallback || owner.cancelled) return;
        owner.finishedCallback = YES;
        [owner.readyTimer invalidate]; owner.readyTimer = nil;
        completion(result, failure);
    };
    BOOL streaming = fastStart;
    [task startInput:url output:self.outputURL options:conversion completion:^(NSError *failure) {
        VPPreparedMedia *owner = weakSelf;
        if (!owner || owner.cancelled) {
            [VPLocalServer.shared unpublishDirectory:directory];
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            return;
        }
        if (failure && streaming && !owner.finishedCallback && [failure.userInfo[@"hardwareEncoderUnavailable"] boolValue]) {
            [owner.readyTimer invalidate]; owner.readyTimer = nil;
            [VPLocalServer.shared unpublishDirectory:directory];
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            NSMutableDictionary *fallback = [options mutableCopy];
            fallback[@"preparedFile"] = @YES;
            [owner prepareURL:url options:fallback completion:completion];
            return;
        }
        if (failure) {
            if (owner.finishedCallback && owner.failureHandler) owner.failureHandler(failure);
            else finish(nil, failure);
            return;
        }
        if (streaming) {
            NSURL *served = [VPLocalServer.shared publishDirectory:directory fileName:@"index.m3u8"];
            finish(served, served ? nil : PrepareError(86, @"The local streaming server could not start."));
        } else finish(owner.outputURL, nil);
    }];
    if (!streaming) return;

    // Start playback as soon as the first one-second HLS segment exists; FFmpeg keeps appending while AVPlayer plays.
    self.readyTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        VPPreparedMedia *owner = weakSelf;
        if (!owner) { [timer invalidate]; return; }
        NSString *text = [NSString stringWithContentsOfURL:playlist encoding:NSUTF8StringEncoding error:nil];
        if (!text) return;
        NSUInteger segments = [text componentsSeparatedByString:@"#EXTINF"].count - 1;
        if (segments < 1 && ![text containsString:@"#EXT-X-ENDLIST"]) return;
        [timer invalidate];
        NSURL *served = [VPLocalServer.shared publishDirectory:directory fileName:@"index.m3u8"];
        finish(served, served ? nil : PrepareError(86, @"The local streaming server could not start."));
    }];
}
@end
