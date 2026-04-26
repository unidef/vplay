//
//  VPFFmpegPlayer.m
//  vplay
//

#import "VPFFmpegPlayer.h"
#import "VPFFmpeg.h"
#import "VPFFmpegSourceDatabase.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import <CoreVideo/CVDisplayLink.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <pthread.h>

#define AUDIO_BUFFER_COUNT 4
#define AUDIO_BUFFER_SIZE 16384
#define MAX_QUEUED_VIDEO_FRAMES 24
#define MAX_QUEUED_AUDIO_SECONDS 2.5

static inline double MachTimeToSeconds(uint64_t machTime) {
    static mach_timebase_info_data_t sTimebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&sTimebase);
    });
    return ((double)machTime * (double)sTimebase.numer) / ((double)sTimebase.denom * 1e9);
}

static inline uint64_t SecondsToMachTime(double seconds) {
    static mach_timebase_info_data_t sTimebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&sTimebase);
    });
    return (uint64_t)((seconds * 1e9 * (double)sTimebase.denom) / (double)sTimebase.numer);
}

@interface VPDecodedVideoFrame : NSObject
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) double pts;
@property (nonatomic, assign) double duration;
@end

@implementation VPDecodedVideoFrame
- (void)dealloc {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}
@end

@interface VPFFmpegPlayer () {
@package
    AVFormatContext *_formatCtx;
    AVCodecContext *_videoCodecCtx;
    AVCodecContext *_audioCodecCtx;
    AVBufferRef *_hwDeviceCtx;
    struct SwsContext *_swsCtx;
    SwrContext *_swrCtx;
    AVChannelLayout _swrInLayout;
    enum AVSampleFormat _swrInFmt;
    int _swrInRate;
    AVChannelLayout _swrOutLayout;
    int _swrOutRate;
    int _swrOutChannels;
    pthread_mutex_t _filterMutex;
    
    CVPixelBufferPoolRef _pixelBufferPool;
    size_t _poolWidth;
    size_t _poolHeight;
    
    int _videoStreamIndex;
    int _audioStreamIndex;
    AVRational _videoTimeBase;
    AVRational _audioTimeBase;
    
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[AUDIO_BUFFER_COUNT];
    AudioStreamBasicDescription _audioFormat;
    
    // Video filter graph (libavfilter), built from the first decoded frame; used on the demux thread only
    AVFilterGraph *_videoGraph;
    AVFilterContext *_videoSrcCtx;
    AVFilterContext *_videoSinkCtx;
    AVFrame *_videoFiltFrame;
    NSString *_videoFilterString;
    int _videoGraphWidth, _videoGraphHeight, _videoGraphFormat;

    // Audio filter graph (libavfilter)
    AVFilterGraph *_audioGraph;
    AVFilterContext *_audioSrcCtx;
    AVFilterContext *_audioSinkCtx;
    NSString *_currentAudioFilterGraph;
    int _filterInRate;
    enum AVSampleFormat _filterInFmt;
    AVChannelLayout _filterInLayout;
    
    // Audio ring buffer
    float *_audioRingBuffer;
    size_t _audioRingCapacity;
    size_t _audioRingReadPos;
    size_t _audioRingWritePos;
    size_t _audioRingAvailable;
    int64_t _audioSamplesPlayed;
    os_unfair_lock _audioLock;
    
    // Video frame queue
    NSMutableArray<VPDecodedVideoFrame *> *_videoQueue;
    os_unfair_lock _videoLock;
    
    // Threading & Synchronization
    NSThread *_demuxThread;
    NSCondition *_demuxCond;
    CVDisplayLinkRef _displayLink;
    dispatch_source_t _fallbackVideoTimer;
    dispatch_source_t _audioProgressTimer;
    uint64_t _lastDelegateNotifyHostTime;
    
    BOOL _running;
    BOOL _paused;
    BOOL _seeking;
    BOOL _seekRequested;
    BOOL _seekExact;          // set by frame stepping: land on the requested frame instead of the first frame near it
    BOOL _activeSeekExact;
    BOOL _abortDemux;
    double _seekTargetPTS;
    BOOL _eofReached;
    
    double _audioStartPTS;
    double _audioBasePTS;
    double _audioClockPTS;
    Float64 _audioQueueSampleTimeOffset;
    double _lastRenderedPTS;
    uint64_t _wallClockMachStart;
    double _wallClockBasePTS;
}

@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) double currentTime;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) BOOL hasVideo;
@property (nonatomic, assign) BOOL hasAudio;
@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) double videoFPS;
@property (nonatomic, strong, readwrite, nullable) VPFFmpegSourceInfo *sourceInfo;

- (void)fillAudioBuffer:(AudioQueueBufferRef)buffer;

@end

static void AQOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    VPFFmpegPlayer *player = (__bridge VPFFmpegPlayer *)inUserData;
    [player fillAudioBuffer:inBuffer];
}

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    const enum AVPixelFormat *p;
    for (p = pix_fmts; *p != -1; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    return pix_fmts[0];
}

static int DemuxInterruptCallback(void *ctx) {
    VPFFmpegPlayer *player = (__bridge VPFFmpegPlayer *)ctx;
    if (!player) return 1;
    return player->_abortDemux ? 1 : 0;
}

static int StreamIndexForOrdinal(AVFormatContext *format, enum AVMediaType type, int ordinal) {
    if (!format || ordinal < 0) return -1;
    int cur = 0;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *st = format->streams[i];
        if (st->codecpar->codec_type != type) continue;
        if (type == AVMEDIA_TYPE_VIDEO && (st->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        if (cur == ordinal) return (int)i;
        cur++;
    }
    return -1;
}

@implementation VPFFmpegPlayer

- (instancetype)init {
    if ((self = [super init])) {
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
        _rate = 1.0f;
        _volume = 1.0f;
        _audioLock = OS_UNFAIR_LOCK_INIT;
        _videoLock = OS_UNFAIR_LOCK_INIT;
        _demuxCond = [NSCondition new];
        _videoQueue = [NSMutableArray arrayWithCapacity:MAX_QUEUED_VIDEO_FRAMES];
        _audioStartPTS = -1.0;
        _audioQueueSampleTimeOffset = -1.0;
        _wallClockMachStart = mach_absolute_time();
        
        // Buffer up to 4 seconds of 8-channel audio at up to 384kHz
        _audioRingCapacity = 384000 * 8 * 4;
        _audioRingBuffer = (float *)calloc(_audioRingCapacity, sizeof(float));
        
        memset(&_filterInLayout, 0, sizeof(_filterInLayout));
        _filterInRate = 0;
        _filterInFmt = AV_SAMPLE_FMT_NONE;
        
        pthread_mutexattr_t filterAttr;
        pthread_mutexattr_init(&filterAttr);
        pthread_mutexattr_settype(&filterAttr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_filterMutex, &filterAttr);
        pthread_mutexattr_destroy(&filterAttr);
    }
    return self;
}

- (void)dealloc {
    [self stopAndNotify:NO];
    [self teardownAudioFilterGraph];
    [self cleanupSwrContext];
    pthread_mutex_destroy(&_filterMutex);
    if (_audioRingBuffer) {
        free(_audioRingBuffer);
        _audioRingBuffer = NULL;
    }
}

#pragma mark - Open & Configure

- (BOOL)openURL:(NSURL *)url options:(nullable NSDictionary *)options error:(NSError **)error {
    [self stopAndNotify:NO];
    
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid URL."}];
        return NO;
    }
    
    static dispatch_once_t netOnce;
    dispatch_once(&netOnce, ^{ avformat_network_init(); });
    
    // Index / lookup from VPFFmpegSourceDatabase
    VPFFmpegSourceInfo *sourceInfo = [[VPFFmpegSourceDatabase sharedDatabase] sourceInfoForURL:url];
    if (!sourceInfo) {
        sourceInfo = [[VPFFmpegSourceDatabase sharedDatabase] indexSourceAtURL:url error:error];
    }
    self.sourceInfo = sourceInfo;
    
    AVDictionary *formatOptions = NULL;
    av_dict_set(&formatOptions, "rw_timeout", "15000000", 0);
    const AVInputFormat *inputFmt = NULL;
    
    NSString *path = url.path;
    if (url.isFileURL && [url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) {
        inputFmt = av_find_input_format("concat");
        av_dict_set(&formatOptions, "safe", "0", 0);
    }
    
    _abortDemux = NO;
    _formatCtx = avformat_alloc_context();
    if (_formatCtx) {
        _formatCtx->interrupt_callback.callback = DemuxInterruptCallback;
        _formatCtx->interrupt_callback.opaque = (__bridge void *)self;
    }
    
    const char *urlStr = (url.isFileURL && path.length) ? path.fileSystemRepresentation : url.absoluteString.UTF8String;
    int ret = avformat_open_input(&_formatCtx, urlStr, (AVInputFormat *)inputFmt, &formatOptions);
    if (formatOptions) av_dict_free(&formatOptions);
    
    if (ret < 0) {
        char errBuf[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, errBuf, sizeof(errBuf));
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:ret userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"FFmpeg failed to open media: %s", errBuf]}];
        return NO;
    }
    
    if (avformat_find_stream_info(_formatCtx, NULL) < 0) {
        [self cleanupFFmpeg];
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"Unable to read stream information."}];
        return NO;
    }
    
    if (_formatCtx->duration != AV_NOPTS_VALUE) {
        self.duration = (double)_formatCtx->duration / AV_TIME_BASE;
    } else if (sourceInfo && sourceInfo.duration > 0) {
        self.duration = sourceInfo.duration;
    } else {
        self.duration = 0.0;
    }
    
    // Find streams
    int reqVideoStream = options[@"videoStream"] ? [options[@"videoStream"] intValue] : -1;
    int reqAudioStream = options[@"audioStream"] ? [options[@"audioStream"] intValue] : -1;
    
    _videoStreamIndex = -1;
    if (reqVideoStream >= 0) {
        _videoStreamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_VIDEO, reqVideoStream);
    }
    if (_videoStreamIndex < 0) {
        _videoStreamIndex = av_find_best_stream(_formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    }
    
    _audioStreamIndex = -1;
    if (reqAudioStream >= 0) {
        _audioStreamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_AUDIO, reqAudioStream);
    }
    if (_audioStreamIndex < 0) {
        _audioStreamIndex = av_find_best_stream(_formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    }
    
    self.hasVideo = (_videoStreamIndex >= 0);
    self.hasAudio = (_audioStreamIndex >= 0);
    
    if (!self.hasVideo && !self.hasAudio) {
        [self cleanupFFmpeg];
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"No playable video or audio streams found."}];
        return NO;
    }
    
    // Setup video decoder
    if (self.hasVideo) {
        AVStream *vStream = _formatCtx->streams[_videoStreamIndex];
        _videoTimeBase = vStream->time_base;
        
        const AVCodec *vCodec = avcodec_find_decoder(vStream->codecpar->codec_id);
        if (vCodec) {
            _videoCodecCtx = avcodec_alloc_context3(vCodec);
            avcodec_parameters_to_context(_videoCodecCtx, vStream->codecpar);
            _videoCodecCtx->pkt_timebase = vStream->time_base;
            _videoCodecCtx->thread_count = 0; // Auto multi-threading for maximum decoding speed
            
            // Video filters need software frames, so they replace hardware decoding.
            _videoFilterString = [options[@"videoFilterGraph"] length] ? [options[@"videoFilterGraph"] copy] : nil;
            // Check if VideoToolbox is safely supported for this codec
            BOOL canUseVideoToolbox = NO;
            enum AVCodecID cid = vStream->codecpar->codec_id;
            if (cid == AV_CODEC_ID_H264) {
                // VideoToolbox handles standard 8-bit H.264 profiles; skip for Hi10P
                if (vStream->codecpar->profile != 110 && vStream->codecpar->profile != 122 && vStream->codecpar->profile != 244) {
                    canUseVideoToolbox = YES;
                }
            } else if (cid == AV_CODEC_ID_HEVC || cid == AV_CODEC_ID_PRORES) {
                canUseVideoToolbox = YES;
            }
            
            if (canUseVideoToolbox && !_videoFilterString) {
                if (av_hwdevice_ctx_create(&_hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
                    _videoCodecCtx->hw_device_ctx = av_buffer_ref(_hwDeviceCtx);
                    _videoCodecCtx->get_format = get_hw_format;
                }
            }
            
            if (avcodec_open2(_videoCodecCtx, vCodec, NULL) < 0) {
                // If open failed (e.g. hwaccel rejected), fallback to pure software decoding
                if (_hwDeviceCtx) {
                    av_buffer_unref(&_hwDeviceCtx);
                    _hwDeviceCtx = NULL;
                }
                avcodec_free_context(&_videoCodecCtx);
                _videoCodecCtx = avcodec_alloc_context3(vCodec);
                avcodec_parameters_to_context(_videoCodecCtx, vStream->codecpar);
                _videoCodecCtx->pkt_timebase = vStream->time_base;
                _videoCodecCtx->thread_count = 0;
                
                if (avcodec_open2(_videoCodecCtx, vCodec, NULL) < 0) {
                    avcodec_free_context(&_videoCodecCtx);
                    self.hasVideo = NO;
                }
            }
            
            if (self.hasVideo && _videoCodecCtx) {
                self.videoSize = CGSizeMake(vStream->codecpar->width, vStream->codecpar->height);
                if (vStream->avg_frame_rate.den > 0 && vStream->avg_frame_rate.num > 0) {
                    self.videoFPS = av_q2d(vStream->avg_frame_rate);
                } else if (vStream->r_frame_rate.den > 0 && vStream->r_frame_rate.num > 0) {
                    self.videoFPS = av_q2d(vStream->r_frame_rate);
                } else {
                    self.videoFPS = 30.0;
                }
            }
        }
    }
    
    // Setup audio decoder & AudioQueue
    if (self.hasAudio) {
        AVStream *aStream = _formatCtx->streams[_audioStreamIndex];
        _audioTimeBase = aStream->time_base;
        
        const AVCodec *aCodec = avcodec_find_decoder(aStream->codecpar->codec_id);
        if (aCodec) {
            _audioCodecCtx = avcodec_alloc_context3(aCodec);
            avcodec_parameters_to_context(_audioCodecCtx, aStream->codecpar);
            _audioCodecCtx->pkt_timebase = aStream->time_base;
            _audioCodecCtx->thread_count = 0;
            
            if (avcodec_open2(_audioCodecCtx, aCodec, NULL) >= 0) {
                [self setupAudioOutputWithOptions:options];
                NSString *initialAF = options[@"af"];
                if (initialAF.length > 0) {
                    [self setupAudioFilterGraph:initialAF];
                }
            } else {
                avcodec_free_context(&_audioCodecCtx);
                self.hasAudio = NO;
            }
        }
    }
    
    if (options[@"volume"]) {
        self.volume = [options[@"volume"] floatValue];
    }
    if (options[@"rate"]) {
        self.rate = [options[@"rate"] floatValue];
    }
    self.looping = [options[@"loop"] boolValue];
    
    return YES;
}

#pragma mark - Audio Queue Setup

- (void)setupAudioOutputWithOptions:(nullable NSDictionary *)options {
    double sampleRate = 48000.0;
    if (options[@"audioSampleRate"]) {
        NSString *srStr = [options[@"audioSampleRate"] description];
        if (![srStr isEqual:@"auto"] && ![srStr isEqual:@"max"]) {
            double customSR = srStr.doubleValue;
            if (customSR >= 8000 && customSR <= 384000) {
                sampleRate = customSR;
            }
        }
    }
    
    int channels = 2;
    AVChannelLayout outLayout;
    av_channel_layout_default(&outLayout, 2);
    
    NSString *layoutStr = options[@"audioLayout"] ?: @"auto";
    if ([layoutStr isEqual:@"mono"] || [layoutStr isEqual:@"1.0"]) {
        channels = 1;
        av_channel_layout_default(&outLayout, 1);
    } else if ([layoutStr isEqual:@"stereo"] || [layoutStr isEqual:@"2.0"] || [layoutStr isEqual:@"auto"]) {
        channels = 2;
        av_channel_layout_default(&outLayout, 2);
    } else if ([layoutStr isEqual:@"2.1"]) {
        channels = 3;
        av_channel_layout_from_string(&outLayout, "2.1");
    } else if ([layoutStr isEqual:@"4.0"] || [layoutStr isEqual:@"quad"]) {
        channels = 4;
        av_channel_layout_from_string(&outLayout, "quad");
    } else if ([layoutStr isEqual:@"4.1"]) {
        channels = 5;
        av_channel_layout_from_string(&outLayout, "4.1");
    } else if ([layoutStr isEqual:@"5.0"]) {
        channels = 5;
        av_channel_layout_from_string(&outLayout, "5.0");
    } else if ([layoutStr isEqual:@"5.1"]) {
        channels = 6;
        av_channel_layout_from_string(&outLayout, "5.1");
    } else if ([layoutStr isEqual:@"7.1"]) {
        channels = 8;
        av_channel_layout_from_string(&outLayout, "7.1");
    }
    
    memset(&_audioFormat, 0, sizeof(_audioFormat));
    _audioFormat.mSampleRate = sampleRate;
    _audioFormat.mFormatID = kAudioFormatLinearPCM;
    _audioFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    _audioFormat.mChannelsPerFrame = channels;
    _audioFormat.mBitsPerChannel = 32;
    _audioFormat.mBytesPerFrame = channels * sizeof(float);
    _audioFormat.mFramesPerPacket = 1;
    _audioFormat.mBytesPerPacket = _audioFormat.mBytesPerFrame;
    
    OSStatus status = AudioQueueNewOutput(&_audioFormat, AQOutputCallback, (__bridge void *)self, NULL, NULL, 0, &_audioQueue);
    if (status != noErr) {
        _audioQueue = NULL;
        return;
    }
    
    AudioChannelLayout acl = {0};
    if (channels == 1) acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    else if (channels == 2) acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    else if (channels == 3) acl.mChannelLayoutTag = kAudioChannelLayoutTag_DVD_4;
    else if (channels == 4) acl.mChannelLayoutTag = kAudioChannelLayoutTag_Quadraphonic;
    else if (channels == 6) acl.mChannelLayoutTag = kAudioChannelLayoutTag_AudioUnit_5_1;
    else if (channels == 8) acl.mChannelLayoutTag = kAudioChannelLayoutTag_AudioUnit_7_1;
    if (acl.mChannelLayoutTag != 0) {
        AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_ChannelLayout, &acl, sizeof(acl));
    }
    
    NSString *deviceUID = options[@"audioDevice"];
    if (deviceUID.length > 0) {
        CFStringRef devRef = (__bridge CFStringRef)deviceUID;
        AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_CurrentDevice, &devRef, sizeof(CFStringRef));
    }
    
    for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
        AudioQueueAllocateBuffer(_audioQueue, AUDIO_BUFFER_SIZE, &_audioBuffers[i]);
    }
    
    [self cleanupSwrContext];
    
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, self.volume);
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_PlayRate, self.rate);
}

#pragma mark - Master Clock

- (double)masterClock {
    return [self masterClockAtHostTime:mach_absolute_time()];
}

- (double)masterClockAtHostTime:(uint64_t)targetHostTime {
    if (self.hasAudio && _audioQueue && _audioStartPTS >= 0) {
        AudioTimeStamp ts;
        OSStatus st = AudioQueueGetCurrentTime(_audioQueue, NULL, &ts, NULL);
        if (st == noErr && (ts.mFlags & kAudioTimeStampSampleTimeValid) && ts.mSampleTime >= 0) {
            if (_audioQueueSampleTimeOffset < 0) {
                _audioQueueSampleTimeOffset = ts.mSampleTime;
            }
            double playedSec = ((double)(ts.mSampleTime - _audioQueueSampleTimeOffset) / (_audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0));
            double currentAudioPTS = _audioStartPTS + playedSec;
            
            // Extrapolate precisely to target display host time using hardware anchor
            if ((ts.mFlags & kAudioTimeStampHostTimeValid) && ts.mHostTime > 0 && targetHostTime > ts.mHostTime) {
                double delta = MachTimeToSeconds(targetHostTime - ts.mHostTime) * _rate;
                return currentAudioPTS + delta;
            } else if (targetHostTime > 0) {
                uint64_t now = mach_absolute_time();
                if (targetHostTime > now) {
                    double delta = MachTimeToSeconds(targetHostTime - now) * _rate;
                    return currentAudioPTS + delta;
                }
            }
            return currentAudioPTS;
        }
    }
    
    uint64_t refTime = targetHostTime > 0 ? targetHostTime : mach_absolute_time();
    double wallDelta = MachTimeToSeconds(refTime > _wallClockMachStart ? (refTime - _wallClockMachStart) : 0) * _rate;
    return _wallClockBasePTS + wallDelta;
}

#pragma mark - Playback Controls

- (void)play {
    if (!self.isPlaying && !self.isPaused) {
        [_demuxCond lock];
        _running = YES;
        _paused = NO;
        _eofReached = NO;
        [_demuxCond unlock];
        
        self.isPlaying = YES;
        self.isPaused = NO;
        
        _wallClockMachStart = mach_absolute_time();
        _wallClockBasePTS = self.currentTime;
        _audioBasePTS = self.currentTime;
        _audioStartPTS = -1.0;
        _audioQueueSampleTimeOffset = -1.0;
        _audioSamplesPlayed = 0;
        
        [self startDemuxThread];
        [self startDisplayLinkSync];
        
        if (_audioQueue) {
            AudioQueueStart(_audioQueue, NULL);
        }
        
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        if (del) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [del ffmpegPlayerDidStartPlaying];
            });
        }
    } else if (self.isPaused) {
        [_demuxCond lock];
        _paused = NO;
        [_demuxCond broadcast];
        [_demuxCond unlock];
        
        self.isPaused = NO;
        self.isPlaying = YES;
        
        _wallClockMachStart = mach_absolute_time();
        _wallClockBasePTS = self.currentTime;
        _audioQueueSampleTimeOffset = -1.0;
        
        [self startDisplayLinkSync];
        
        if (_audioQueue) {
            AudioQueueStart(_audioQueue, NULL);
        }
    }
}

- (void)pause {
    if (self.isPlaying && !self.isPaused) {
        [_demuxCond lock];
        _paused = YES;
        [_demuxCond broadcast];
        [_demuxCond unlock];
        
        self.isPaused = YES;
        self.isPlaying = NO;
        self.currentTime = [self masterClock];
        
        [self stopDisplayLinkSync];
        
        if (_audioQueue) {
            AudioQueuePause(_audioQueue);
        }
        
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        if (del) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [del ffmpegPlayerDidPause];
            });
        }
    }
}

- (void)togglePlayPause {
    if (self.isPaused || !self.isPlaying) {
        [self play];
    } else {
        [self pause];
    }
}

- (void)stop {
    [self stopAndNotify:YES];
}

- (void)stopAndNotify:(BOOL)notifyDelegate {
    @synchronized (self) {
        if (!_running && !self.isPlaying && !_demuxThread && !_audioQueue && !_displayLink && !_formatCtx) {
            return;
        }
        
        self.isPlaying = NO;
        self.isPaused = NO;
        _seeking = NO;
        _seekRequested = NO;
        _abortDemux = YES;
        
        [_demuxCond lock];
        _running = NO;
        [_demuxCond broadcast];
        [_demuxCond unlock];
        
        // Wait for demux thread to safely exit
        while (_demuxThread && !_demuxThread.isFinished) {
            [NSThread sleepForTimeInterval:0.005];
        }
        _demuxThread = nil;
        
        [self stopDisplayLinkSync];
        
        if (_audioQueue) {
            AudioQueueRef aq = _audioQueue;
            _audioQueue = NULL;
            AudioQueueStop(aq, YES);
            AudioQueueDispose(aq, YES);
        }
        
        self.frameHandler = nil;
        self.audioSamplesHandler = nil;
        
        [self clearAudioBuffer];
        [self clearVideoQueue];
        [self cleanupFFmpeg];
        
        self.currentTime = 0;
        _audioStartPTS = -1.0;
        _audioQueueSampleTimeOffset = -1.0;
        
        if (notifyDelegate) {
            id<VPFFmpegPlayerDelegate> del = self.delegate;
            if (del) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [del ffmpegPlayerDidStop];
                });
            }
        }
    }
}

- (void)seekToSeconds:(double)seconds {
    if (!_formatCtx) return;
    seconds = MAX(0.0, MIN(seconds, self.duration > 0 ? self.duration : seconds));
    
    [_demuxCond lock];
    _seekRequested = YES;
    _seekExact = NO;
    _seekTargetPTS = seconds;
    _seeking = YES;
    [_demuxCond broadcast];
    [_demuxCond unlock];
}

- (void)stepFrames:(NSInteger)count {
    if (!_formatCtx || !self.hasVideo || count == 0) return;
    if (self.isPlaying && !self.isPaused) [self pause];
    double frameDuration = 1.0 / MAX(1.0, self.videoFPS);
    [_demuxCond lock];
    double base = _lastRenderedPTS > 0 ? _lastRenderedPTS : self.currentTime;
    double target = MAX(0.0, base + count * frameDuration);
    if (self.duration > 0) target = MIN(target, self.duration);
    _seekRequested = YES;
    _seekExact = YES;
    _seekTargetPTS = target;
    _seeking = YES;
    [_demuxCond broadcast];
    [_demuxCond unlock];
}

- (BOOL)selectAudioTrack:(int)trackOrdinal {
    if (!_formatCtx) return NO;
    int streamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_AUDIO, trackOrdinal);
    if (streamIndex < 0 || streamIndex >= (int)_formatCtx->nb_streams) return NO;
    if (streamIndex == _audioStreamIndex && _audioCodecCtx) return YES;
    
    [_demuxCond lock];
    
    if (_audioCodecCtx) {
        avcodec_free_context(&_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
    [self cleanupSwrContext];
    
    AVStream *aStream = _formatCtx->streams[streamIndex];
    _audioStreamIndex = streamIndex;
    _audioTimeBase = aStream->time_base;
    
    const AVCodec *aCodec = avcodec_find_decoder(aStream->codecpar->codec_id);
    if (aCodec) {
        _audioCodecCtx = avcodec_alloc_context3(aCodec);
        avcodec_parameters_to_context(_audioCodecCtx, aStream->codecpar);
        _audioCodecCtx->pkt_timebase = aStream->time_base;
        _audioCodecCtx->thread_count = 0;
        if (avcodec_open2(_audioCodecCtx, aCodec, NULL) >= 0) {
            self.hasAudio = YES;
            if (_currentAudioFilterGraph.length > 0) {
                [self setupAudioFilterGraph:_currentAudioFilterGraph];
            }
        } else {
            avcodec_free_context(&_audioCodecCtx);
            _audioCodecCtx = NULL;
            self.hasAudio = NO;
        }
    } else {
        self.hasAudio = NO;
    }
    
    os_unfair_lock_lock(&_audioLock);
    _audioRingAvailable = 0;
    _audioRingReadPos = 0;
    _audioRingWritePos = 0;
    os_unfair_lock_unlock(&_audioLock);
    
    if (_audioQueue) {
        AudioQueueReset(_audioQueue);
    }
    
    double currTime = self.currentTime;
    _seekRequested = YES;
    _seekTargetPTS = currTime;
    _seeking = YES;
    
    [_demuxCond broadcast];
    [_demuxCond unlock];
    return YES;
}

- (void)setVolume:(float)volume {
    _volume = MAX(0.0f, MIN(volume, 1.0f));
    if (_audioQueue) {
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, _volume);
    }
}

- (void)setRate:(float)rate {
    _rate = MAX(0.25f, MIN(rate, 4.0f));
    if (_audioQueue) {
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_PlayRate, _rate);
    }
    _wallClockMachStart = mach_absolute_time();
    _wallClockBasePTS = self.currentTime;
    _audioQueueSampleTimeOffset = -1.0;
}

#pragma mark - Demuxer Worker Thread

- (void)startDemuxThread {
    if (_demuxThread && !_demuxThread.isFinished) return;
    _demuxThread = [[NSThread alloc] initWithTarget:self selector:@selector(demuxThreadMain) object:nil];
    _demuxThread.name = @"com.vplay.ffmpeg.demux";
    _demuxThread.qualityOfService = NSQualityOfServiceDefault;
    [_demuxThread start];
}

- (void)demuxThreadMain {
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    
    while (1) {
        [_demuxCond lock];
        if (!_running) {
            [_demuxCond unlock];
            break;
        }
        
        // Handle Seek Request
        if (_seekRequested) {
            double target = _seekTargetPTS;
            _activeSeekExact = _seekExact;
            _seekRequested = NO;
            [_demuxCond unlock];
            
            [self performSeekTo:target frame:frame packet:packet];
            continue;
        }
        
        // Handle Paused
        if (_paused) {
            [_demuxCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
            [_demuxCond unlock];
            continue;
        }
        
        // Backpressure check
        BOOL videoFull = NO;
        os_unfair_lock_lock(&_videoLock);
        if (_videoQueue.count >= MAX_QUEUED_VIDEO_FRAMES) videoFull = YES;
        os_unfair_lock_unlock(&_videoLock);
        
        BOOL audioFull = NO;
        os_unfair_lock_lock(&_audioLock);
        int ch = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
        double activeSampleRate = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
        if (_audioRingAvailable > (size_t)(activeSampleRate * ch * MAX_QUEUED_AUDIO_SECONDS)) audioFull = YES;
        os_unfair_lock_unlock(&_audioLock);
        
        if (videoFull && (audioFull || !self.hasAudio)) {
            [_demuxCond unlock];
            [NSThread sleepForTimeInterval:0.010];
            continue;
        }
        [_demuxCond unlock];
        
        // Read next packet
        int ret = av_read_frame(_formatCtx, packet);
        if (ret < 0) {
            if (ret == AVERROR_EOF) {
                [_demuxCond lock];
                _eofReached = YES;
                [_demuxCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                [_demuxCond unlock];
                [self checkEndOfStream];
            } else {
                [NSThread sleepForTimeInterval:0.01];
            }
            continue;
        }
        
        if (packet->stream_index == _videoStreamIndex && _videoCodecCtx) {
            [self decodeVideoPacket:packet frame:frame];
        } else if (packet->stream_index == _audioStreamIndex && _audioCodecCtx) {
            [self decodeAudioPacket:packet frame:frame];
        }
        
        av_packet_unref(packet);
    }
    
    av_packet_free(&packet);
    av_frame_free(&frame);
}

- (void)performSeekTo:(double)target frame:(AVFrame *)frame packet:(AVPacket *)packet {
    if (!_formatCtx) return;
    target = MAX(0.0, MIN(target, self.duration > 0 ? self.duration : target));
    
    int64_t seekTarget = (int64_t)(target * AV_TIME_BASE);
    
    // Multi-tier robust seeking strategy for MKV, MP4, WebM, TS, AVI
    int seekRet = -1;
    if (_videoStreamIndex >= 0 && _formatCtx->streams[_videoStreamIndex]) {
        AVRational tb = _formatCtx->streams[_videoStreamIndex]->time_base;
        int64_t streamTarget = av_rescale_q(seekTarget, AV_TIME_BASE_Q, tb);
        seekRet = avformat_seek_file(_formatCtx, _videoStreamIndex, INT64_MIN, streamTarget, streamTarget, AVSEEK_FLAG_BACKWARD);
        if (seekRet < 0) {
            seekRet = av_seek_frame(_formatCtx, _videoStreamIndex, streamTarget, AVSEEK_FLAG_BACKWARD);
        }
    }
    
    if (seekRet < 0) {
        seekRet = avformat_seek_file(_formatCtx, -1, INT64_MIN, seekTarget, seekTarget, AVSEEK_FLAG_BACKWARD);
        if (seekRet < 0) {
            seekRet = av_seek_frame(_formatCtx, -1, seekTarget, AVSEEK_FLAG_BACKWARD);
        }
    }
    
    if (seekRet < 0) {
        seekRet = avformat_seek_file(_formatCtx, -1, INT64_MIN, seekTarget, INT64_MAX, 0);
        if (seekRet < 0) {
            seekRet = av_seek_frame(_formatCtx, -1, seekTarget, 0);
        }
    }
    
    // Flush codec buffers and queues
    if (_videoCodecCtx) avcodec_flush_buffers(_videoCodecCtx);
    if (_audioCodecCtx) avcodec_flush_buffers(_audioCodecCtx);
    [self teardownVideoGraph];   // rebuilt from the first frame after the seek, dropping any buffered frames
    
    pthread_mutex_lock(&_filterMutex);
    if (_currentAudioFilterGraph.length > 0 && _audioCodecCtx) {
        NSString *cur = [_currentAudioFilterGraph copy];
        [self teardownAudioFilterGraphLocked];
        [self setupAudioFilterGraphLocked:cur inputFrame:nil];
    }
    pthread_mutex_unlock(&_filterMutex);
    
    [self clearAudioBuffer];
    [self clearVideoQueue];
    
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, YES);
        AudioQueueReset(_audioQueue);
        for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
            if (_audioBuffers[i]) {
                _audioBuffers[i]->mAudioDataByteSize = 0;
            }
        }
    }
    
    _audioStartPTS = -1.0;
    _audioBasePTS = target;
    _audioClockPTS = target;
    _audioQueueSampleTimeOffset = -1.0;
    _audioSamplesPlayed = 0;
    _lastRenderedPTS = target;
    _wallClockMachStart = mach_absolute_time();
    _wallClockBasePTS = target;
    self.currentTime = target;
    
    // Decode forward to target so target frame displays immediately
    if (self.hasVideo && _videoCodecCtx) {
        __block BOOL gotFrame = NO;
        double slack = _activeSeekExact ? 0.5 / MAX(1.0, self.videoFPS) : 0.04;
        int maxPackets = 400;
        for (int i = 0; i < maxPackets && !gotFrame; i++) {
            [_demuxCond lock];
            if (_seekRequested) {
                [_demuxCond unlock];
                break;
            }
            [_demuxCond unlock];
            
            if (av_read_frame(_formatCtx, packet) < 0) break;
            
            if (packet->stream_index == _videoStreamIndex) {
                if (avcodec_send_packet(_videoCodecCtx, packet) >= 0) {
                    while (!gotFrame && avcodec_receive_frame(_videoCodecCtx, frame) >= 0) {
                        [self filterVideoFrame:frame fallbackPTS:target handler:^(AVFrame *out, double pts) {
                            if (gotFrame || !(pts >= target - slack || i >= maxPackets - 20)) return;
                            CVPixelBufferRef pb = [self pixelBufferFromFrame:out];
                            if (!pb) return;
                            self->_lastRenderedPTS = pts;
                            self.currentTime = pts;
                            self->_wallClockBasePTS = pts;
                            self->_wallClockMachStart = mach_absolute_time();
                            self->_audioBasePTS = pts;
                            self->_audioClockPTS = pts;
                            if (self.frameHandler) {
                                CVPixelBufferRetain(pb);
                                self.frameHandler(pb, pts);
                                CVPixelBufferRelease(pb);
                            }
                            CVPixelBufferRelease(pb);
                            gotFrame = YES;
                        }];
                    }
                }
            } else if (packet->stream_index == _audioStreamIndex && _audioCodecCtx) {
                double aPts = (packet->pts != AV_NOPTS_VALUE) ? (packet->pts * av_q2d(_audioTimeBase)) : -1.0;
                if (aPts >= target - 0.05) {
                    [self decodeAudioPacket:packet frame:frame];
                }
            }
            av_packet_unref(packet);
        }
        if (_audioCodecCtx && _audioRingAvailable == 0) {
            for (int i = 0; i < 50 && _audioRingAvailable == 0; i++) {
                [_demuxCond lock];
                if (_seekRequested) {
                    [_demuxCond unlock];
                    break;
                }
                [_demuxCond unlock];
                if (av_read_frame(_formatCtx, packet) < 0) break;
                if (packet->stream_index == _audioStreamIndex) {
                    double aPts = (packet->pts != AV_NOPTS_VALUE) ? (packet->pts * av_q2d(_audioTimeBase)) : -1.0;
                    if (aPts >= target - 0.1) {
                        [self decodeAudioPacket:packet frame:frame];
                    }
                }
                av_packet_unref(packet);
            }
        }
    } else if (!self.hasVideo && _audioCodecCtx) {
        for (int i = 0; i < 200; i++) {
            [_demuxCond lock];
            if (_seekRequested) {
                [_demuxCond unlock];
                break;
            }
            [_demuxCond unlock];
            
            if (av_read_frame(_formatCtx, packet) < 0) break;
            if (packet->stream_index == _audioStreamIndex) {
                double aPts = (packet->pts != AV_NOPTS_VALUE) ? (packet->pts * av_q2d(_audioTimeBase)) : -1.0;
                if (aPts >= target - 0.05) {
                    [self decodeAudioPacket:packet frame:frame];
                    av_packet_unref(packet);
                    break;
                }
            }
            av_packet_unref(packet);
        }
    }
    
    [_demuxCond lock];
    if (_seekRequested) {
        [_demuxCond unlock];
        return;
    }
    _eofReached = NO;
    _seeking = NO;
    [_demuxCond unlock];
    
    if (_audioQueue) {
        for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
            if (_audioBuffers[i]->mAudioDataByteSize == 0 && _audioRingAvailable > 0) {
                [self fillAudioBuffer:_audioBuffers[i]];
            }
        }
        if (self.isPlaying && !self.isPaused) {
            AudioQueueStart(_audioQueue, NULL);
        }
    }
    
    id<VPFFmpegPlayerDelegate> del = self.delegate;
    if (del) {
        double cur = self.currentTime;
        double dur = self.duration;
        dispatch_async(dispatch_get_main_queue(), ^{
            [del ffmpegPlayerDidUpdateTime:cur duration:dur];
        });
    }
}

#pragma mark - Video Decoding & Metal Buffer Creation

- (void)decodeVideoPacket:(AVPacket *)packet frame:(AVFrame *)frame {
    int ret = avcodec_send_packet(_videoCodecCtx, packet);
    if (ret < 0) return;
    
    while (ret >= 0) {
        ret = avcodec_receive_frame(_videoCodecCtx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;
        
        double fallback = _lastRenderedPTS + 1.0 / MAX(1.0, self.videoFPS);
        [self filterVideoFrame:frame fallbackPTS:fallback handler:^(AVFrame *out, double pts) {
            if (pts < self.currentTime - 0.05) return;
            CVPixelBufferRef pixelBuffer = [self pixelBufferFromFrame:out];
            if (pixelBuffer) {
                VPDecodedVideoFrame *vFrame = [VPDecodedVideoFrame new];
                vFrame.pixelBuffer = pixelBuffer;
                vFrame.pts = pts;
                vFrame.duration = 1.0 / MAX(1.0, self.videoFPS);
                
                os_unfair_lock_lock(&self->_videoLock);
                [self->_videoQueue addObject:vFrame];
                os_unfair_lock_unlock(&self->_videoLock);
            }
        }];
    }
}

#pragma mark - Video Filter Graph

- (void)teardownVideoGraph {
    if (_videoGraph) avfilter_graph_free(&_videoGraph);
    _videoGraph = NULL; _videoSrcCtx = NULL; _videoSinkCtx = NULL;
    if (_videoFiltFrame) av_frame_free(&_videoFiltFrame);
}

- (BOOL)buildVideoGraphForFrame:(AVFrame *)frame {
    [self teardownVideoGraph];
    _videoGraph = avfilter_graph_alloc();
    const AVFilter *src = avfilter_get_by_name("buffer"), *sink = avfilter_get_by_name("buffersink");
    if (!_videoGraph || !src || !sink) { [self teardownVideoGraph]; return NO; }
    AVRational sar = frame->sample_aspect_ratio.num > 0 ? frame->sample_aspect_ratio : (AVRational){1, 1};
    AVRational fr = _formatCtx->streams[_videoStreamIndex]->avg_frame_rate;
    if (fr.num <= 0 || fr.den <= 0) fr = (AVRational){30, 1};
    NSString *args = [NSString stringWithFormat:@"video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d:frame_rate=%d/%d",
                      frame->width, frame->height, frame->format, _videoTimeBase.num, _videoTimeBase.den, sar.num, sar.den, fr.num, fr.den];
    AVFilterInOut *outputs = avfilter_inout_alloc(), *inputs = avfilter_inout_alloc();
    int err = avfilter_graph_create_filter(&_videoSrcCtx, src, "in", args.UTF8String, NULL, _videoGraph);
    if (err >= 0) err = avfilter_graph_create_filter(&_videoSinkCtx, sink, "out", NULL, NULL, _videoGraph);
    if (err >= 0 && outputs && inputs) {
        outputs->name = av_strdup("in"); outputs->filter_ctx = _videoSrcCtx; outputs->pad_idx = 0; outputs->next = NULL;
        inputs->name = av_strdup("out"); inputs->filter_ctx = _videoSinkCtx; inputs->pad_idx = 0; inputs->next = NULL;
        err = avfilter_graph_parse_ptr(_videoGraph, _videoFilterString.UTF8String, &inputs, &outputs, NULL);
    } else if (err >= 0) err = AVERROR(ENOMEM);
    avfilter_inout_free(&inputs); avfilter_inout_free(&outputs);
    if (err >= 0) err = avfilter_graph_config(_videoGraph, NULL);
    if (err < 0) {
        NSLog(@"[VPFFmpegPlayer] Video filter graph error %d for '%@'", err, _videoFilterString);
        [self teardownVideoGraph];
        return NO;
    }
    _videoFiltFrame = av_frame_alloc();
    _videoGraphWidth = frame->width; _videoGraphHeight = frame->height; _videoGraphFormat = frame->format;
    return YES;
}

/// Hands every frame the video filters produce for `frame` to `handler` (the frame itself when there are none).
- (void)filterVideoFrame:(AVFrame *)frame fallbackPTS:(double)fallback handler:(void (^)(AVFrame *out, double pts))handler {
    if (!_videoFilterString.length) {
        handler(frame, frame->pts != AV_NOPTS_VALUE ? frame->pts * av_q2d(_videoTimeBase) : fallback);
        return;
    }
    if (!_videoGraph || _videoGraphWidth != frame->width || _videoGraphHeight != frame->height || _videoGraphFormat != frame->format) {
        if (![self buildVideoGraphForFrame:frame]) {   // an unusable filter must not blank the picture
            _videoFilterString = nil;
            handler(frame, frame->pts != AV_NOPTS_VALUE ? frame->pts * av_q2d(_videoTimeBase) : fallback);
            return;
        }
    }
    if (av_buffersrc_add_frame_flags(_videoSrcCtx, frame, AV_BUFFERSRC_FLAG_KEEP_REF) < 0) return;
    AVRational tb = av_buffersink_get_time_base(_videoSinkCtx);
    while (av_buffersink_get_frame(_videoSinkCtx, _videoFiltFrame) >= 0) {
        handler(_videoFiltFrame, _videoFiltFrame->pts != AV_NOPTS_VALUE ? _videoFiltFrame->pts * av_q2d(tb) : fallback);
        av_frame_unref(_videoFiltFrame);
    }
}

- (CVPixelBufferRef)pixelBufferFromFrame:(AVFrame *)frame {
    if (!frame) return NULL;
    
    // 1. Hardware-decoded via VideoToolbox
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (frame->data[3] != NULL) {
            CVPixelBufferRef hwBuffer = (CVPixelBufferRef)frame->data[3];
            if (hwBuffer && CFGetTypeID(hwBuffer) == CVPixelBufferGetTypeID()) {
                CVPixelBufferRetain(hwBuffer);
                return hwBuffer;
            }
        }
        return NULL;
    }
    
    // 2. Software decoded: convert to Metal-compatible 32BGRA IOSurface CVPixelBuffer
    int width = frame->width;
    int height = frame->height;
    if (width <= 0 || height <= 0) return NULL;
    
    // Maintain or create CVPixelBufferPool for high performance zero-fragmentation rendering
    if (!_pixelBufferPool || _poolWidth != (size_t)width || _poolHeight != (size_t)height) {
        if (_pixelBufferPool) {
            CVPixelBufferPoolRelease(_pixelBufferPool);
            _pixelBufferPool = NULL;
        }
        
        NSDictionary *poolAttributes = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @(MAX_QUEUED_VIDEO_FRAMES + 4) };
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES
        };
        
        CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes, (__bridge CFDictionaryRef)pixelAttributes, &_pixelBufferPool);
        if (poolStatus != kCVReturnSuccess) {
            _pixelBufferPool = NULL;
        } else {
            _poolWidth = (size_t)width;
            _poolHeight = (size_t)height;
        }
    }
    
    CVPixelBufferRef targetBuffer = NULL;
    if (_pixelBufferPool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &targetBuffer);
    }
    
    if (!targetBuffer) {
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES
        };
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelAttributes, &targetBuffer);
        if (status != kCVReturnSuccess || !targetBuffer) return NULL;
    }
    
    _swsCtx = sws_getCachedContext(_swsCtx, width, height, (enum AVPixelFormat)frame->format,
                                   width, height, AV_PIX_FMT_BGRA,
                                   SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (!_swsCtx) {
        CVPixelBufferRelease(targetBuffer);
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    uint8_t *dstData[4] = { (uint8_t *)CVPixelBufferGetBaseAddress(targetBuffer), NULL, NULL, NULL };
    int dstLinesize[4] = { (int)CVPixelBufferGetBytesPerRow(targetBuffer), 0, 0, 0 };
    
    sws_scale(_swsCtx, (const uint8_t * const *)frame->data, frame->linesize, 0, height, dstData, dstLinesize);
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
    
    return targetBuffer;
}

#pragma mark - SWR Resampler Management

- (void)cleanupSwrContext {
    if (_swrCtx) {
        swr_free(&_swrCtx);
        _swrCtx = NULL;
    }
    av_channel_layout_uninit(&_swrInLayout);
    av_channel_layout_uninit(&_swrOutLayout);
    memset(&_swrInLayout, 0, sizeof(_swrInLayout));
    memset(&_swrOutLayout, 0, sizeof(_swrOutLayout));
    _swrInFmt = AV_SAMPLE_FMT_NONE;
    _swrInRate = 0;
    _swrOutRate = 0;
    _swrOutChannels = 0;
}

#pragma mark - Audio Filter Graph & Decoding

- (void)teardownAudioFilterGraphLocked {
    if (_audioGraph) {
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        _audioSrcCtx = NULL;
        _audioSinkCtx = NULL;
    }
    av_channel_layout_uninit(&_filterInLayout);
    memset(&_filterInLayout, 0, sizeof(_filterInLayout));
    _filterInRate = 0;
    _filterInFmt = AV_SAMPLE_FMT_NONE;
    _currentAudioFilterGraph = nil;
    [self cleanupSwrContext];
}

- (void)teardownAudioFilterGraph {
    pthread_mutex_lock(&_filterMutex);
    [self teardownAudioFilterGraphLocked];
    pthread_mutex_unlock(&_filterMutex);
}

- (BOOL)setupAudioFilterGraph:(NSString *)filterGraphStr {
    pthread_mutex_lock(&_filterMutex);
    BOOL ok = [self setupAudioFilterGraphLocked:filterGraphStr inputFrame:nil];
    pthread_mutex_unlock(&_filterMutex);
    return ok;
}

- (BOOL)setupAudioFilterGraphLocked:(NSString *)filterGraphStr inputFrame:(nullable AVFrame *)inputFrame {
    [self teardownAudioFilterGraphLocked];
    
    if (!filterGraphStr || filterGraphStr.length == 0 || !_audioCodecCtx) {
        return YES;
    }
    
    _audioGraph = avfilter_graph_alloc();
    if (!_audioGraph) {
        return NO;
    }
    
    const AVFilter *abuffer = avfilter_get_by_name("abuffer");
    const AVFilter *abuffersink = avfilter_get_by_name("abuffersink");
    if (!abuffer || !abuffersink) {
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        return NO;
    }
    
    AVChannelLayout chLayout;
    memset(&chLayout, 0, sizeof(chLayout));
    if (inputFrame && inputFrame->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&chLayout, &inputFrame->ch_layout);
    } else if (_audioCodecCtx->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&chLayout, &_audioCodecCtx->ch_layout);
    } else {
        av_channel_layout_default(&chLayout, 2);
    }
    
    char chLayoutStr[128] = {0};
    av_channel_layout_describe(&chLayout, chLayoutStr, sizeof(chLayoutStr));
    if (chLayoutStr[0] == 0 || strcmp(chLayoutStr, "unknown") == 0) {
        int channels = chLayout.nb_channels > 0 ? chLayout.nb_channels : 2;
        snprintf(chLayoutStr, sizeof(chLayoutStr), "%dc", channels);
    }
    
    int sampleRate = 48000;
    if (inputFrame && inputFrame->sample_rate > 0) {
        sampleRate = inputFrame->sample_rate;
    } else if (_audioCodecCtx->sample_rate > 0) {
        sampleRate = _audioCodecCtx->sample_rate;
    }
    
    enum AVSampleFormat sampleFmt = AV_SAMPLE_FMT_FLTP;
    if (inputFrame && inputFrame->format != AV_SAMPLE_FMT_NONE) {
        sampleFmt = (enum AVSampleFormat)inputFrame->format;
    } else if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_NONE) {
        sampleFmt = _audioCodecCtx->sample_fmt;
    }
    
    AVRational timeBase = _audioTimeBase.den > 0 ? _audioTimeBase : (AVRational){1, sampleRate};
    
    char args[512];
    snprintf(args, sizeof(args),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             timeBase.num, timeBase.den, sampleRate,
             av_get_sample_fmt_name(sampleFmt), chLayoutStr);
    
    int err = avfilter_graph_create_filter(&_audioSrcCtx, abuffer, "in", args, NULL, _audioGraph);
    if (err < 0) {
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        return NO;
    }
    
    err = avfilter_graph_create_filter(&_audioSinkCtx, abuffersink, "out", NULL, NULL, _audioGraph);
    if (err < 0) {
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        return NO;
    }
    

    
    // If the filter string does not already have an alimiter, append a transparent brickwall limiter to catch peak overshoots cleanly without clipping or distortion
    NSString *effectiveGraphStr = filterGraphStr;
    if (![filterGraphStr containsString:@"alimiter"]) {
        effectiveGraphStr = [NSString stringWithFormat:@"%@,alimiter=limit=0.98:attack=5:release=50:asc=0:level=0", filterGraphStr];
    }
    
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs  = avfilter_inout_alloc();
    outputs->name       = av_strdup("in");
    outputs->filter_ctx = _audioSrcCtx;
    outputs->pad_idx    = 0;
    outputs->next       = NULL;
    
    inputs->name        = av_strdup("out");
    inputs->filter_ctx  = _audioSinkCtx;
    inputs->pad_idx     = 0;
    inputs->next        = NULL;
    
    err = avfilter_graph_parse_ptr(_audioGraph, effectiveGraphStr.UTF8String, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    
    if (err < 0) {
        NSLog(@"[VPFFmpegPlayer] Audio filter graph parse error %d for '%@'", err, effectiveGraphStr);
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        _audioSrcCtx = NULL;
        _audioSinkCtx = NULL;
        return NO;
    }
    
    err = avfilter_graph_config(_audioGraph, NULL);
    if (err < 0) {
        NSLog(@"[VPFFmpegPlayer] Audio filter graph config error %d for '%@'", err, effectiveGraphStr);
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        _audioSrcCtx = NULL;
        _audioSinkCtx = NULL;
        return NO;
    }
    
    _filterInRate = sampleRate;
    _filterInFmt = sampleFmt;
    av_channel_layout_copy(&_filterInLayout, &chLayout);
    av_channel_layout_uninit(&chLayout);
    
    _currentAudioFilterGraph = [filterGraphStr copy];
    [self cleanupSwrContext];
    return YES;
}

- (void)applyAudioFiltersGraph:(nullable NSString *)graphString {
    [self setupAudioFilterGraph:graphString];
}

- (void)resampleAndEnqueueAudioFrame:(AVFrame *)frame timeBase:(AVRational)timeBase {
    if (!frame || frame->nb_samples <= 0) return;
    
    int inRate = frame->sample_rate > 0 ? frame->sample_rate : (_audioCodecCtx->sample_rate > 0 ? _audioCodecCtx->sample_rate : 48000);
    int targetRate = (int)_audioFormat.mSampleRate > 0 ? (int)_audioFormat.mSampleRate : 48000;
    int targetChannels = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    enum AVSampleFormat inFmt = (enum AVSampleFormat)frame->format;
    
    AVChannelLayout inLayout;
    if (frame->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&inLayout, &frame->ch_layout);
    } else {
        av_channel_layout_default(&inLayout, 2);
    }
    
    AVChannelLayout outLayout;
    if (targetChannels == 6) {
        av_channel_layout_from_mask(&outLayout, AV_CH_LAYOUT_5POINT1);
    } else if (targetChannels == 8) {
        av_channel_layout_from_mask(&outLayout, AV_CH_LAYOUT_7POINT1);
    } else if (targetChannels == 3) {
        av_channel_layout_from_string(&outLayout, "2.1");
    } else {
        av_channel_layout_default(&outLayout, targetChannels);
    }
    
    BOOL needsReinit = NO;
    if (!_swrCtx) {
        needsReinit = YES;
    } else if (_swrInFmt != inFmt ||
               _swrInRate != inRate ||
               _swrOutRate != targetRate ||
               _swrOutChannels != targetChannels ||
               av_channel_layout_compare(&_swrInLayout, &inLayout) != 0 ||
               av_channel_layout_compare(&_swrOutLayout, &outLayout) != 0) {
        needsReinit = YES;
    }
    
    if (needsReinit) {
        [self cleanupSwrContext];
        
        _swrInFmt = inFmt;
        _swrInRate = inRate;
        _swrOutRate = targetRate;
        _swrOutChannels = targetChannels;
        av_channel_layout_copy(&_swrInLayout, &inLayout);
        av_channel_layout_copy(&_swrOutLayout, &outLayout);
        
        swr_alloc_set_opts2(&_swrCtx,
                            &outLayout,
                            AV_SAMPLE_FMT_FLT,
                            targetRate,
                            &inLayout,
                            inFmt,
                            inRate,
                            0, NULL);
        if (_swrCtx) {
            av_opt_set_double(_swrCtx, "rematrix_maxval", 1.0, 0);
            swr_init(_swrCtx);
        }
    }
    av_channel_layout_uninit(&inLayout);
    av_channel_layout_uninit(&outLayout);
    
    if (!_swrCtx) return;
    
    int64_t delay = swr_get_delay(_swrCtx, inRate);
    int outSamples = (int)av_rescale_rnd(delay + frame->nb_samples, targetRate, inRate, AV_ROUND_UP);
    if (outSamples <= 0) return;
    
    float *outBuffer = (float *)malloc((outSamples + 256) * targetChannels * sizeof(float));
    if (!outBuffer) return;
    uint8_t *outPlanes[1] = { (uint8_t *)outBuffer };
    
    const uint8_t **inPlanes = (const uint8_t **)(frame->extended_data ? frame->extended_data : frame->data);
    int converted = swr_convert(_swrCtx, outPlanes, outSamples + 256, inPlanes, frame->nb_samples);
    if (converted > 0) {
        AVRational tb = timeBase.den > 0 ? timeBase : _audioTimeBase;
        double pts = (frame->pts != AV_NOPTS_VALUE) ? (frame->pts * av_q2d(tb)) : _audioClockPTS;
        [self enqueueAudioSamples:outBuffer count:converted * targetChannels pts:pts];
    }
    free(outBuffer);
}

- (void)resampleAndEnqueueAudioFrame:(AVFrame *)frame {
    [self resampleAndEnqueueAudioFrame:frame timeBase:_audioTimeBase];
}

- (void)decodeAudioPacket:(AVPacket *)packet frame:(AVFrame *)frame {
    int ret = avcodec_send_packet(_audioCodecCtx, packet);
    if (ret < 0) return;
    
    while (ret >= 0) {
        ret = avcodec_receive_frame(_audioCodecCtx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;
        
        double pts = (frame->pts != AV_NOPTS_VALUE) ? (frame->pts * av_q2d(_audioTimeBase)) : -1.0;
        if (pts >= 0 && _audioStartPTS < 0 && pts < _audioBasePTS - 0.15) {
            continue;
        }
        
        pthread_mutex_lock(&_filterMutex);
        if (_audioGraph != NULL && _audioSrcCtx != NULL && _audioSinkCtx != NULL) {
            BOOL needsFilterRebuild = NO;
            if (_filterInRate > 0 && frame->sample_rate > 0 && frame->sample_rate != _filterInRate) {
                needsFilterRebuild = YES;
            }
            if (_filterInFmt != AV_SAMPLE_FMT_NONE && frame->format != AV_SAMPLE_FMT_NONE && frame->format != _filterInFmt) {
                needsFilterRebuild = YES;
            }
            if (_filterInLayout.nb_channels > 0 && frame->ch_layout.nb_channels > 0 &&
                av_channel_layout_compare(&_filterInLayout, &frame->ch_layout) != 0) {
                needsFilterRebuild = YES;
            }
            if (needsFilterRebuild && _currentAudioFilterGraph.length > 0) {
                NSString *cur = [_currentAudioFilterGraph copy];
                [self setupAudioFilterGraphLocked:cur inputFrame:frame];
            }
            
            int sRet = av_buffersrc_add_frame_flags(_audioSrcCtx, frame, AV_BUFFERSRC_FLAG_KEEP_REF);
            if (sRet >= 0) {
                AVFrame *filtFrame = av_frame_alloc();
                AVRational sinkTB = av_buffersink_get_time_base(_audioSinkCtx);
                while (1) {
                    int gRet = av_buffersink_get_frame(_audioSinkCtx, filtFrame);
                    if (gRet == AVERROR(EAGAIN) || gRet == AVERROR_EOF) break;
                    if (gRet < 0) break;
                    [self resampleAndEnqueueAudioFrame:filtFrame timeBase:sinkTB];
                    av_frame_unref(filtFrame);
                }
                av_frame_free(&filtFrame);
            } else {
                [self resampleAndEnqueueAudioFrame:frame timeBase:_audioTimeBase];
            }
        } else {
            [self resampleAndEnqueueAudioFrame:frame timeBase:_audioTimeBase];
        }
        pthread_mutex_unlock(&_filterMutex);
    }
}

- (void)enqueueAudioSamples:(const float *)samples count:(int)count pts:(double)pts {
    if (count <= 0) return;
    
    int channels = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    if (self.audioSamplesHandler) {
        self.audioSamplesHandler(samples, count / channels, channels);
    }
    
    os_unfair_lock_lock(&_audioLock);
    if (_audioStartPTS < 0 && pts >= 0) {
        _audioStartPTS = pts;
        _audioBasePTS = pts;
        _audioQueueSampleTimeOffset = -1.0;
        _wallClockBasePTS = pts;
        _wallClockMachStart = mach_absolute_time();
    }
    
    size_t framesAvailable = (_audioRingCapacity - _audioRingAvailable) / channels;
    size_t framesToWrite = MIN((size_t)(count / channels), framesAvailable);
    size_t samplesToWrite = framesToWrite * channels;
    
    for (size_t i = 0; i < samplesToWrite; i++) {
        float s = samples[i];
        if (isnan(s) || isinf(s)) {
            s = 0.0f;
        } else if (s > 0.95f) {
            // Smooth soft-knee saturation with continuous C1 derivative up to 1.0 to eliminate step discontinuities
            s = 0.95f + 0.05f * tanhf((s - 0.95f) / 0.05f);
            if (s > 1.0f) s = 1.0f;
        } else if (s < -0.95f) {
            s = -0.95f - 0.05f * tanhf((-s - 0.95f) / 0.05f);
            if (s < -1.0f) s = -1.0f;
        }
        _audioRingBuffer[_audioRingWritePos] = s;
        _audioRingWritePos = (_audioRingWritePos + 1) % _audioRingCapacity;
    }
    _audioRingAvailable += samplesToWrite;
    _audioClockPTS = pts;
    os_unfair_lock_unlock(&_audioLock);
    
    // Prime AudioQueue if needed
    if (_audioQueue) {
        for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
            if (_audioBuffers[i]->mAudioDataByteSize == 0 && _audioRingAvailable > 0) {
                [self fillAudioBuffer:_audioBuffers[i]];
            }
        }
        if (self.isPlaying && !self.isPaused && _audioRingAvailable > 0) {
            AudioQueueStart(_audioQueue, NULL);
        }
    }
}

- (void)fillAudioBuffer:(AudioQueueBufferRef)buffer {
    if (!_audioQueue || !_running || !self.isPlaying) return;
    
    os_unfair_lock_lock(&_audioLock);
    int channels = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    size_t requestedFrames = (buffer->mAudioDataBytesCapacity / sizeof(float)) / channels;
    size_t availableFrames = _audioRingAvailable / channels;
    size_t framesToCopy = MIN(requestedFrames, availableFrames);
    size_t samplesToCopy = framesToCopy * channels;
    size_t samplesRequested = requestedFrames * channels;
    
    float *dst = (float *)buffer->mAudioData;
    for (size_t i = 0; i < samplesToCopy; i++) {
        dst[i] = _audioRingBuffer[_audioRingReadPos];
        _audioRingReadPos = (_audioRingReadPos + 1) % _audioRingCapacity;
    }
    _audioRingAvailable -= samplesToCopy;
    _audioSamplesPlayed += samplesToCopy;
    
    if (samplesToCopy < samplesRequested) {
        // Smoothly fade out the tail of copied samples if buffer underrun to prevent pop/click
        if (samplesToCopy > 0) {
            size_t fadeLen = MIN((size_t)64 * channels, samplesToCopy);
            for (size_t f = 0; f < fadeLen; f++) {
                float gain = 1.0f - ((float)f / (float)fadeLen);
                dst[samplesToCopy - fadeLen + f] *= gain;
            }
        }
        memset(dst + samplesToCopy, 0, (samplesRequested - samplesToCopy) * sizeof(float));
    }
    
    buffer->mAudioDataByteSize = (UInt32)(samplesRequested * sizeof(float));
    os_unfair_lock_unlock(&_audioLock);
    
    // Audio buffer consumed; demux thread periodically checks backpressure
    
    if (_audioQueue && _running && self.isPlaying) {
        AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
    }
}

#pragma mark - Hardware Accelerated Video Presentation & Sync

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink,
                                   const CVTimeStamp *inNow,
                                   const CVTimeStamp *inOutputTime,
                                   CVOptionFlags flagsIn,
                                   CVOptionFlags *flagsOut,
                                   void *displayLinkContext) {
    @autoreleasepool {
        VPFFmpegPlayer *player = (__bridge VPFFmpegPlayer *)displayLinkContext;
        [player renderVideoFrameForTargetHostTime:inOutputTime->hostTime];
    }
    return kCVReturnSuccess;
}

- (void)startDisplayLinkSync {
    [self stopDisplayLinkSync];
    
    if (!self.hasVideo) {
        [self startFallbackAudioTimer];
        return;
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVReturn ret = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    if (ret == kCVReturnSuccess && _displayLink) {
        CVDisplayLinkSetOutputCallback(_displayLink, DisplayLinkCallback, (__bridge void *)self);
        CVDisplayLinkStart(_displayLink);
    } else {
        _displayLink = NULL;
        [self startFallbackVideoTimer];
    }
#pragma clang diagnostic pop
}

- (void)stopDisplayLinkSync {
    if (_displayLink) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkSetOutputCallback(_displayLink, NULL, NULL);
        CVDisplayLinkRelease(_displayLink);
#pragma clang diagnostic pop
        _displayLink = NULL;
    }
    if (_fallbackVideoTimer) {
        dispatch_source_cancel(_fallbackVideoTimer);
        _fallbackVideoTimer = NULL;
    }
    if (_audioProgressTimer) {
        dispatch_source_cancel(_audioProgressTimer);
        _audioProgressTimer = NULL;
    }
}

- (void)startFallbackVideoTimer {
    if (_fallbackVideoTimer) return;
    _fallbackVideoTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    uint64_t intervalNs = (uint64_t)((1.0 / MAX(30.0, MIN(120.0, self.videoFPS))) * NSEC_PER_SEC);
    dispatch_source_set_timer(_fallbackVideoTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 10);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_fallbackVideoTimer, ^{
        [weakSelf renderVideoFrameForTargetHostTime:mach_absolute_time()];
    });
    dispatch_resume(_fallbackVideoTimer);
}

- (void)startFallbackAudioTimer {
    if (_audioProgressTimer) return;
    _audioProgressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_audioProgressTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_audioProgressTimer, ^{
        VPFFmpegPlayer *player = weakSelf;
        if (!player || !player.isPlaying || player.isPaused) return;
        double clock = [player masterClock];
        player.currentTime = clock;
        id<VPFFmpegPlayerDelegate> del = player.delegate;
        double dur = player.duration;
        if (del) {
            [del ffmpegPlayerDidUpdateTime:clock duration:dur];
        }
    });
    dispatch_resume(_audioProgressTimer);
}

- (void)renderVideoFrameForTargetHostTime:(uint64_t)targetHostTime {
    if (!self.isPlaying || self.isPaused || _seeking) return;
    
    double clock = [self masterClockAtHostTime:targetHostTime];
    self.currentTime = clock;
    
    uint64_t now = mach_absolute_time();
    if (now - _lastDelegateNotifyHostTime >= SecondsToMachTime(0.1)) {
        _lastDelegateNotifyHostTime = now;
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        double cur = clock;
        double dur = self.duration;
        if (del) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [del ffmpegPlayerDidUpdateTime:cur duration:dur];
            });
        }
    }
    
    os_unfair_lock_lock(&_videoLock);
    if (_videoQueue.count == 0) {
        os_unfair_lock_unlock(&_videoLock);
        return;
    }
    
    VPDecodedVideoFrame *frameToRender = nil;
    double frameDuration = 1.0 / MAX(1.0, self.videoFPS);
    
    while (_videoQueue.count > 0) {
        VPDecodedVideoFrame *candidate = _videoQueue.firstObject;
        double diff = candidate.pts - clock;
        
        // Late frame drop (A/V sync catchup): drop frame if it is more than 1.5 frame durations late
        if (diff < -(1.5 * frameDuration) && _videoQueue.count > 1) {
            [_videoQueue removeObjectAtIndex:0];
            continue;
        }
        
        // Frame ready for presentation on this V-Sync pulse
        double tolerance = MAX(0.015, frameDuration * 0.5);
        if (diff <= tolerance) {
            frameToRender = candidate;
            [_videoQueue removeObjectAtIndex:0];
            break;
        } else {
            // Frame is in the future; hold until next V-Sync
            break;
        }
    }
    os_unfair_lock_unlock(&_videoLock);
    
    // Video queue consumed; demux thread periodically checks backpressure
    
    if (frameToRender && self.frameHandler) {
        _lastRenderedPTS = frameToRender.pts;
        CVPixelBufferRef pb = frameToRender.pixelBuffer;
        if (pb) {
            CVPixelBufferRetain(pb);
            self.frameHandler(pb, frameToRender.pts);
            CVPixelBufferRelease(pb);
        }
    }
}

#pragma mark - Queue and Resource Cleanup

- (void)checkEndOfStream {
    [_demuxCond lock];
    BOOL eof = _eofReached;
    [_demuxCond unlock];
    if (!eof) return;
    
    os_unfair_lock_lock(&_videoLock);
    NSUInteger vCount = _videoQueue.count;
    os_unfair_lock_unlock(&_videoLock);
    
    os_unfair_lock_lock(&_audioLock);
    size_t aAvail = _audioRingAvailable;
    os_unfair_lock_unlock(&_audioLock);
    
    if (vCount == 0 && aAvail == 0) {
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.looping) {
                [self seekToSeconds:0];
            } else {
                [self pause];
                if (del) {
                    [del ffmpegPlayerDidReachEnd];
                }
            }
        });
    }
}

- (void)clearAudioBuffer {
    os_unfair_lock_lock(&_audioLock);
    _audioRingReadPos = 0;
    _audioRingWritePos = 0;
    _audioRingAvailable = 0;
    _audioSamplesPlayed = 0;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)clearVideoQueue {
    os_unfair_lock_lock(&_videoLock);
    [_videoQueue removeAllObjects];
    os_unfair_lock_unlock(&_videoLock);
}

- (void)cleanupFFmpeg {
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    _poolWidth = 0;
    _poolHeight = 0;
    
    if (_videoCodecCtx) {
        avcodec_free_context(&_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
    if (_audioCodecCtx) {
        avcodec_free_context(&_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
    if (_hwDeviceCtx) {
        av_buffer_unref(&_hwDeviceCtx);
        _hwDeviceCtx = NULL;
    }
    if (_swsCtx) {
        sws_freeContext(_swsCtx);
        _swsCtx = NULL;
    }
    if (_swrCtx) {
        swr_free(&_swrCtx);
        _swrCtx = NULL;
    }
    [self teardownAudioFilterGraph];
    [self teardownVideoGraph];
    if (_formatCtx) {
        _formatCtx->interrupt_callback.callback = NULL;
        _formatCtx->interrupt_callback.opaque = NULL;
        avformat_close_input(&_formatCtx);
        _formatCtx = NULL;
    }
    
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    self.hasVideo = NO;
    self.hasAudio = NO;
}

@end
