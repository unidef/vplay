//
//  VPPlaybackEngine.m
//  vplay
//

#import "VPPlaybackEngine.h"
#import <CoreMedia/CoreMedia.h>
#import "VPEffectPipeline.h"
#import "VPFFmpegOptions.h"
#import "VPAudioDeviceManager.h"
#import "VPProcessingPlan.h"
#import "VPFFmpegPlayer.h"

@interface VPPlaybackEngine () <VPFFmpegPlayerDelegate>
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerItem *currentItem;
@property (nonatomic, strong, nullable) VPFFmpegPlayer *ffmpegPlayer;
@property (nonatomic, assign) BOOL isFFmpegPlaying;
@property (nonatomic, strong, nullable) id timeObserver;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic) BOOL observingStatus;
@property (nonatomic) BOOL reportedItemFailure;
@property (nonatomic, strong, nullable) NSURL *lastURL;
@property (nonatomic, strong, nullable) NSDictionary *lastOptions;
@end

static BOOL IsFormatSupportedNativelyByMacOS(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    NSSet *nativeExts = [NSSet setWithObjects:@"mp4", @"mov", @"m4v", @"m4a", @"mp3", @"aac", @"wav", @"aif", @"aiff", @"m3u8", nil];
    return [nativeExts containsObject:ext];
}

@implementation VPPlaybackEngine

- (void)dealloc {
    [self stop];
}

- (double)currentTime {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        return self.ffmpegPlayer.currentTime;
    }
    if (self.player) {
        double t = CMTimeGetSeconds(self.player.currentTime);
        return isfinite(t) ? MAX(0, t) : 0;
    }
    return 0;
}

- (double)duration {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        return self.ffmpegPlayer.duration;
    }
    if (self.currentItem) {
        double d = CMTimeGetSeconds(self.currentItem.duration);
        return (isfinite(d) && d > 0) ? d : 0;
    }
    return 0;
}

- (BOOL)playURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL."}];
        }
        return NO;
    }

    [self stop];
    self.lastURL = url;
    self.lastOptions = options;

    if (options[@"effectChain"]) { options = [VPProcessingPlan resolvedOptions:options error:error]; if (!options) return NO; }
    if (options[@"audioDevice"] && ![VPAudioDeviceManager setOutputDeviceUID:options[@"audioDevice"] error:error]) return NO;

    NSString *backend = options[@"playbackBackend"] ?: @"auto";
    BOOL forceFFmpeg = [backend isEqual:@"ffmpeg"] || [backend isEqual:@"prepared"] || [backend isEqual:@"ffplay"];
    BOOL disc = [url.pathExtension.lowercaseString isEqual:@"ffconcat"];
    // Prepared media already carries the filters (the audio-filter chain is global state, so it would still look "active").
    BOOL requiresFFmpegFilters = ![options[@"alreadyPrepared"] boolValue] && [VPFFmpegOptions requiresPreparation:options];
    BOOL nativeExt = IsFormatSupportedNativelyByMacOS(url);

    BOOL useFFmpeg = forceFFmpeg || disc || requiresFFmpegFilters || !nativeExt;

    if (!useFFmpeg && [backend isEqual:@"auto"]) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (!asset.isPlayable) {
            useFFmpeg = YES;
        }
    }

    if (useFFmpeg) {
        return [self playWithFFmpeg:url options:options error:error];
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    // HLS streams cannot take video compositions; the video view's effect renderer handles those.
    if (![options[@"hls"] boolValue] && ![VPEffectPipeline configureItem:item options:options error:error]) return NO;
    if (![VPAudioDeviceManager applySampleRateForOptions:options error:error]) return NO;
    self.currentItem = item;
    self.reportedItemFailure = NO;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemFailedToPlayToEnd:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
    self.observingStatus = YES;
    self.player = [AVPlayer playerWithPlayerItem:item];

    // Apply options
    if ([options[@"mute"] boolValue]) {
        self.player.muted = YES;
    }
    if (options[@"volume"]) {
        self.player.volume = [options[@"volume"] floatValue];
    }
    if (options[@"rate"]) {
        self.player.rate = [options[@"rate"] floatValue];
    }
    self.looping = [options[@"loop"] boolValue];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    // Add periodic time observer
    __weak typeof(self) weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC)
                                                                 queue:dispatch_get_main_queue()
                                                            usingBlock:^(CMTime time) {
        [weakSelf.delegate playbackEngineDidUpdateTime:time];
    }];

    if (options[@"audioStream"] && [options[@"audioStream"] integerValue] > 0) {
        NSInteger audioIdx = [options[@"audioStream"] integerValue];
        [item.asset loadMediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible completionHandler:^(AVMediaSelectionGroup *group, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (group && (NSInteger)group.options.count > audioIdx) {
                    [item selectMediaOption:group.options[audioIdx] inMediaSelectionGroup:group];
                }
            });
        }];
    }

    [self.player play];
    if (options[@"rate"]) self.player.rate = [options[@"rate"] floatValue];
    self.isPlaying = YES;
    [self.delegate playbackEngineDidStartPlaying];

    return YES;
}

- (BOOL)playWithFFmpeg:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    if (self.ffmpegPlayer) {
        VPFFmpegPlayer *oldPlayer = self.ffmpegPlayer;
        self.ffmpegPlayer = nil;
        self.isFFmpegPlaying = NO;
        [oldPlayer stop];
    }
    
    VPFFmpegPlayer *ffPlayer = [VPFFmpegPlayer new];
    ffPlayer.delegate = self;
    if (![ffPlayer openURL:url options:options error:error]) {
        return NO;
    }
    self.ffmpegPlayer = ffPlayer;
    self.isFFmpegPlaying = YES;
    self.looping = [options[@"loop"] boolValue];
    ffPlayer.looping = self.looping;
    
    [ffPlayer play];
    self.isPlaying = YES;
    [self.delegate playbackEngineDidStartPlaying];
    return YES;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == self.currentItem && [keyPath isEqual:@"status"]) {
        AVPlayerItem *item = object;
        if (item.status == AVPlayerItemStatusFailed) [self reportFailureForItem:item error:item.error];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)playerItemFailedToPlayToEnd:(NSNotification *)notification {
    [self reportFailureForItem:notification.object error:notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]];
}

- (void)reportFailureForItem:(AVPlayerItem *)item error:(NSError *)error {
    // If native playback fails, attempt transparent fallback to direct FFmpeg playback
    if (self.lastURL && !self.isFFmpegPlaying) {
        NSError *ffErr = nil;
        if ([self playWithFFmpeg:self.lastURL options:self.lastOptions ?: @{} error:&ffErr]) {
            return;
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.currentItem != item || self.reportedItemFailure) return;
        self.reportedItemFailure = YES;
        self.isPlaying = NO;
        [self.delegate playbackEngineDidPause];
        NSError *failure = error ?: item.error ?: [NSError errorWithDomain:@"VPlayErrorDomain" code:85
            userInfo:@{NSLocalizedDescriptionKey:@"Playback stopped unexpectedly."}];
        NSString *airPlayMessage = nil;
        NSString *recovery = @"Check that the receiver is on and connected to the same network. Select this Mac in the AirPlay device list to try local playback, then reconnect.";
        NSError *cause = failure;
        for (NSUInteger depth = 0; cause && depth < 8; depth++) {
            if ([cause.domain isEqualToString:AVFoundationErrorDomain]) {
                switch (cause.code) {
                    case AVErrorAirPlayControllerRequiresInternet:
                        airPlayMessage = @"This Mac needs internet access for AirPlay.";
                        recovery = @"Connect this Mac to the internet, then select the AirPlay receiver again.";
                        break;
                    case AVErrorAirPlayReceiverRequiresInternet:
                        airPlayMessage = @"The AirPlay receiver needs internet access.";
                        recovery = @"Check the receiver’s internet connection, then reconnect from the AirPlay device list.";
                        break;
                    case AVErrorExternalPlaybackNotSupportedForAsset:
                        airPlayMessage = @"This media does not support AirPlay playback.";
                        recovery = @"Select this Mac to play locally. For video on another display, try Screen Mirroring from macOS Control Center.";
                        break;
                    default:
                        if (@available(macOS 13.0, *)) {
                            if (cause.code == AVErrorAirPlayReceiverTemporarilyUnavailable)
                                airPlayMessage = @"The AirPlay receiver is temporarily unavailable.";
                        }
                        break;
                }
            }
            if (airPlayMessage) break;
            cause = cause.userInfo[NSUnderlyingErrorKey];
        }
        if (airPlayMessage || self.player.externalPlaybackActive) {
            failure = [NSError errorWithDomain:@"VPlayAirPlayErrorDomain" code:failure.code userInfo:@{
                NSLocalizedDescriptionKey: airPlayMessage ?: @"AirPlay playback failed.",
                NSLocalizedRecoverySuggestionErrorKey: recovery,
                NSUnderlyingErrorKey: failure
            }];
        }
        if ([self.delegate respondsToSelector:@selector(playbackEngineDidFail:)])
            [self.delegate playbackEngineDidFail:failure];
    });
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    if (self.looping) {
        [self.player seekToTime:kCMTimeZero];
        [self.player play];
    } else {
        self.isPlaying = NO;
        [self.delegate playbackEngineDidReachEnd];
    }
}

- (void)pause {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        [self.ffmpegPlayer pause];
        self.isPlaying = NO;
        return;
    }
    [self.player pause];
    self.isPlaying = NO;
    [self.delegate playbackEngineDidPause];
}

- (void)resume {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        [self.ffmpegPlayer play];
        self.isPlaying = YES;
        return;
    }
    [self.player play];
    self.isPlaying = YES;
    [self.delegate playbackEngineDidStartPlaying];
}

- (void)stop {
    if (self.ffmpegPlayer) {
        VPFFmpegPlayer *player = self.ffmpegPlayer;
        self.ffmpegPlayer = nil;
        self.isFFmpegPlaying = NO;
        [player stop];
    }
    if (self.observingStatus) { [self.currentItem removeObserver:self forKeyPath:@"status"]; self.observingStatus = NO; }
    if (self.timeObserver && self.player) {
        [self.player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:self.currentItem];
    [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.currentItem];
    [self.player pause];
    self.player = nil;
    self.currentItem = nil;
    self.isPlaying = NO;
    [self.delegate playbackEngineDidStop];
}

- (void)seekToSeconds:(double)seconds {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        [self.ffmpegPlayer seekToSeconds:seconds];
        return;
    }
    CMTime time = CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC);
    [self.player seekToTime:time];
}

- (void)setRate:(float)rate {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        [self.ffmpegPlayer setRate:rate];
        self.isPlaying = (rate != 0.0f);
        return;
    }
    self.player.rate = rate;
    self.isPlaying = (rate != 0.0f);
}

- (void)setVolume:(float)volume {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        [self.ffmpegPlayer setVolume:volume];
        return;
    }
    self.player.volume = volume;
}

- (BOOL)usesExternalPlayer { return NO; }

- (void)togglePlayPause {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        [self.ffmpegPlayer togglePlayPause];
        return;
    }
    if (self.player.rate > 0) {
        [self pause];
    } else {
        [self resume];
    }
}

- (BOOL)selectAudioTrack:(NSInteger)index {
    if (self.isFFmpegPlaying && self.ffmpegPlayer) {
        return [self.ffmpegPlayer selectAudioTrack:(int)index];
    }
    return NO;
}

#pragma mark - VPFFmpegPlayerDelegate

- (void)ffmpegPlayerDidStartPlaying {
    self.isPlaying = YES;
    [self.delegate playbackEngineDidStartPlaying];
}

- (void)ffmpegPlayerDidFail:(NSError *)error {
    self.isPlaying = NO;
    if ([self.delegate respondsToSelector:@selector(playbackEngineDidFail:)]) {
        [self.delegate playbackEngineDidFail:error];
    }
}

- (void)ffmpegPlayerDidPause {
    self.isPlaying = NO;
    [self.delegate playbackEngineDidPause];
}

- (void)ffmpegPlayerDidStop {
    self.isPlaying = NO;
    [self.delegate playbackEngineDidStop];
}

- (void)ffmpegPlayerDidReachEnd {
    if (self.looping) {
        [self seekToSeconds:0];
        [self resume];
    } else {
        self.isPlaying = NO;
        [self.delegate playbackEngineDidReachEnd];
    }
}

- (void)ffmpegPlayerDidUpdateTime:(double)currentTime duration:(double)duration {
    [self.delegate playbackEngineDidUpdateTime:CMTimeMakeWithSeconds(currentTime, 1000)];
}

@end
