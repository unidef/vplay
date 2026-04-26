//
//  VPFFmpegSourceDatabase.m
//  vplay
//

#import "VPFFmpegSourceDatabase.h"
#import "VPFFmpeg.h"
#import <os/lock.h>

@implementation VPFFmpegStreamInfo
@end

@implementation VPFFmpegChapterInfo
@end

@implementation VPFFmpegSeekCue
@end

@implementation VPFFmpegSourceInfo

- (nullable VPFFmpegStreamInfo *)streamWithIndex:(int)index {
    for (VPFFmpegStreamInfo *info in self.videoStreams) {
        if (info.streamIndex == index) return info;
    }
    for (VPFFmpegStreamInfo *info in self.audioStreams) {
        if (info.streamIndex == index) return info;
    }
    for (VPFFmpegStreamInfo *info in self.subtitleStreams) {
        if (info.streamIndex == index) return info;
    }
    return nil;
}

- (nullable VPFFmpegStreamInfo *)primaryVideoStream {
    if (self.defaultVideoStreamIndex >= 0) {
        VPFFmpegStreamInfo *info = [self streamWithIndex:self.defaultVideoStreamIndex];
        if (info) return info;
    }
    return self.videoStreams.firstObject;
}

- (nullable VPFFmpegStreamInfo *)primaryAudioStream {
    if (self.defaultAudioStreamIndex >= 0) {
        VPFFmpegStreamInfo *info = [self streamWithIndex:self.defaultAudioStreamIndex];
        if (info) return info;
    }
    return self.audioStreams.firstObject;
}

- (double)closestKeyframePTSBefore:(double)targetPTS {
    if (!self.seekCues.count) return targetPTS;
    
    NSInteger low = 0;
    NSInteger high = (NSInteger)self.seekCues.count - 1;
    double bestPTS = self.seekCues.firstObject.pts;
    
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        VPFFmpegSeekCue *cue = self.seekCues[mid];
        if (cue.pts <= targetPTS) {
            bestPTS = cue.pts;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return bestPTS;
}

- (double)closestKeyframePTSAfter:(double)targetPTS {
    if (!self.seekCues.count) return targetPTS;
    
    NSInteger low = 0;
    NSInteger high = (NSInteger)self.seekCues.count - 1;
    double bestPTS = self.seekCues.lastObject.pts;
    
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        VPFFmpegSeekCue *cue = self.seekCues[mid];
        if (cue.pts >= targetPTS) {
            bestPTS = cue.pts;
            high = mid - 1;
        } else {
            low = mid + 1;
        }
    }
    return bestPTS;
}

@end

@interface VPFFmpegSourceDatabase () {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, VPFFmpegSourceInfo *> *_cache;
}
@end

@implementation VPFFmpegSourceDatabase

+ (instancetype)sharedDatabase {
    static VPFFmpegSourceDatabase *db = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        db = [[VPFFmpegSourceDatabase alloc] initPrivate];
    });
    return db;
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _cache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)init {
    return [VPFFmpegSourceDatabase sharedDatabase];
}

static NSString *CacheKeyForURL(NSURL *url) {
    if (!url) return @"";
    if (url.isFileURL) {
        return url.standardizedURL.path ?: url.path;
    }
    return url.absoluteString;
}

- (nullable VPFFmpegSourceInfo *)sourceInfoForURL:(NSURL *)url {
    if (!url) return nil;
    NSString *key = CacheKeyForURL(url);
    os_unfair_lock_lock(&_lock);
    VPFFmpegSourceInfo *info = _cache[key];
    os_unfair_lock_unlock(&_lock);
    return info;
}

- (void)registerSourceInfo:(VPFFmpegSourceInfo *)info forURL:(NSURL *)url {
    if (!info || !url) return;
    NSString *key = CacheKeyForURL(url);
    os_unfair_lock_lock(&_lock);
    _cache[key] = info;
    os_unfair_lock_unlock(&_lock);
}

- (void)removeSourceForURL:(NSURL *)url {
    if (!url) return;
    NSString *key = CacheKeyForURL(url);
    os_unfair_lock_lock(&_lock);
    [_cache removeObjectForKey:key];
    os_unfair_lock_unlock(&_lock);
}

- (void)clearDatabase {
    os_unfair_lock_lock(&_lock);
    [_cache removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (void)indexSourceAtURL:(NSURL *)url completion:(void (^)(VPFFmpegSourceInfo * _Nullable, NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        VPFFmpegSourceInfo *info = [self indexSourceAtURL:url error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(info, error);
        });
    });
}

static NSDictionary<NSString *, NSString *> *ExtractMetadata(AVDictionary *metadata) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    const AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_get(metadata, "", entry, AV_DICT_IGNORE_SUFFIX))) {
        if (entry->key && entry->value) {
            NSString *key = [NSString stringWithUTF8String:entry->key];
            NSString *val = [NSString stringWithUTF8String:entry->value];
            if (key.length && val.length) {
                dict[key.lowercaseString] = val;
            }
        }
    }
    return dict;
}

- (nullable VPFFmpegSourceInfo *)indexSourceAtURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"VPFFmpegSourceDatabase" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid URL."}];
        return nil;
    }
    
    // Check if already indexed
    VPFFmpegSourceInfo *cached = [self sourceInfoForURL:url];
    if (cached) return cached;
    
    static dispatch_once_t netOnce;
    dispatch_once(&netOnce, ^{ avformat_network_init(); });
    
    AVFormatContext *formatCtx = avformat_alloc_context();
    if (!formatCtx) {
        if (error) *error = [NSError errorWithDomain:@"VPFFmpegSourceDatabase" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"Failed to allocate AVFormatContext."}];
        return nil;
    }
    
    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", "15000000", 0);
    const AVInputFormat *demuxer = NULL;
    NSString *path = url.path;
    if (url.isFileURL && [url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) {
        demuxer = av_find_input_format("concat");
        av_dict_set(&options, "safe", "0", 0);
    }
    
    const char *urlStr = (url.isFileURL && path.length) ? path.fileSystemRepresentation : url.absoluteString.UTF8String;
    int ret = avformat_open_input(&formatCtx, urlStr, (AVInputFormat *)demuxer, &options);
    if (options) av_dict_free(&options);
    
    if (ret < 0) {
        char errBuf[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, errBuf, sizeof(errBuf));
        if (error) *error = [NSError errorWithDomain:@"VPFFmpegSourceDatabase" code:ret userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to open source: %s", errBuf]}];
        return nil;
    }
    
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        if (error) *error = [NSError errorWithDomain:@"VPFFmpegSourceDatabase" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"Failed to find stream information."}];
        avformat_close_input(&formatCtx);
        return nil;
    }
    
    VPFFmpegSourceInfo *sourceInfo = [VPFFmpegSourceInfo new];
    sourceInfo.url = url;
    sourceInfo.formatName = formatCtx->iformat ? [NSString stringWithUTF8String:formatCtx->iformat->name] : @"";
    sourceInfo.formatLongName = (formatCtx->iformat && formatCtx->iformat->long_name) ? [NSString stringWithUTF8String:formatCtx->iformat->long_name] : @"";
    sourceInfo.duration = formatCtx->duration != AV_NOPTS_VALUE ? (double)formatCtx->duration / AV_TIME_BASE : 0.0;
    sourceInfo.startTime = formatCtx->start_time != AV_NOPTS_VALUE ? (double)formatCtx->start_time / AV_TIME_BASE : 0.0;
    sourceInfo.bitRate = formatCtx->bit_rate;
    sourceInfo.fileSize = formatCtx->pb ? avio_size(formatCtx->pb) : 0;
    sourceInfo.metadata = ExtractMetadata(formatCtx->metadata);
    sourceInfo.defaultVideoStreamIndex = -1;
    sourceInfo.defaultAudioStreamIndex = -1;
    sourceInfo.defaultSubtitleStreamIndex = -1;
    
    NSMutableArray<VPFFmpegStreamInfo *> *videoStreams = [NSMutableArray array];
    NSMutableArray<VPFFmpegStreamInfo *> *audioStreams = [NSMutableArray array];
    NSMutableArray<VPFFmpegStreamInfo *> *subStreams = [NSMutableArray array];
    
    int bestVideo = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int bestAudio = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    int bestSub = av_find_best_stream(formatCtx, AVMEDIA_TYPE_SUBTITLE, -1, -1, NULL, 0);
    
    sourceInfo.defaultVideoStreamIndex = bestVideo;
    sourceInfo.defaultAudioStreamIndex = bestAudio;
    sourceInfo.defaultSubtitleStreamIndex = bestSub;
    
    for (unsigned int i = 0; i < formatCtx->nb_streams; i++) {
        AVStream *stream = formatCtx->streams[i];
        AVCodecParameters *codecpar = stream->codecpar;
        
        VPFFmpegStreamInfo *sInfo = [VPFFmpegStreamInfo new];
        sInfo.streamIndex = (int)i;
        sInfo.codecID = codecpar->codec_id;
        sInfo.codecName = [NSString stringWithUTF8String:avcodec_get_name(codecpar->codec_id)] ?: @"";
        const AVCodecDescriptor *desc = avcodec_descriptor_get(codecpar->codec_id);
        sInfo.codecLongName = (desc && desc->long_name) ? [NSString stringWithUTF8String:desc->long_name] : sInfo.codecName;
        sInfo.bitRate = codecpar->bit_rate;
        sInfo.timeBaseSeconds = av_q2d(stream->time_base);
        sInfo.duration = stream->duration != AV_NOPTS_VALUE ? stream->duration * sInfo.timeBaseSeconds : sourceInfo.duration;
        sInfo.isDefault = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
        sInfo.isForced = (stream->disposition & AV_DISPOSITION_FORCED) != 0;
        sInfo.metadata = ExtractMetadata(stream->metadata);
        sInfo.language = sInfo.metadata[@"language"] ?: @"";
        sInfo.title = sInfo.metadata[@"title"] ?: @"";
        
        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            sInfo.streamType = VPFFmpegStreamTypeVideo;
            sInfo.isAttachedPic = (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
            if (sInfo.isAttachedPic) continue;
            
            sInfo.width = codecpar->width;
            sInfo.height = codecpar->height;
            if (stream->avg_frame_rate.den > 0 && stream->avg_frame_rate.num > 0) {
                sInfo.frameRate = av_q2d(stream->avg_frame_rate);
            } else if (stream->r_frame_rate.den > 0 && stream->r_frame_rate.num > 0) {
                sInfo.frameRate = av_q2d(stream->r_frame_rate);
            } else {
                sInfo.frameRate = 30.0;
            }
            
            sInfo.pixelFormatName = [NSString stringWithUTF8String:av_get_pix_fmt_name((enum AVPixelFormat)codecpar->format)] ?: @"unknown";
            sInfo.isInterlaced = (codecpar->field_order != AV_FIELD_PROGRESSIVE && codecpar->field_order != AV_FIELD_UNKNOWN);
            sInfo.fieldOrder = codecpar->field_order == AV_FIELD_TT ? @"tff" : (codecpar->field_order == AV_FIELD_BB ? @"bff" : @"progressive");
            if (codecpar->sample_aspect_ratio.num > 0) {
                sInfo.aspectRatio = av_q2d(codecpar->sample_aspect_ratio) * ((double)sInfo.width / MAX(1, sInfo.height));
            } else {
                sInfo.aspectRatio = (double)sInfo.width / MAX(1, sInfo.height);
            }
            [videoStreams addObject:sInfo];
            
        } else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            sInfo.streamType = VPFFmpegStreamTypeAudio;
            sInfo.sampleRate = codecpar->sample_rate;
            sInfo.channels = codecpar->ch_layout.nb_channels;
            char layoutBuf[128] = {0};
            av_channel_layout_describe(&codecpar->ch_layout, layoutBuf, sizeof(layoutBuf));
            sInfo.channelLayout = [NSString stringWithUTF8String:layoutBuf] ?: @"";
            sInfo.sampleFormatName = [NSString stringWithUTF8String:av_get_sample_fmt_name((enum AVSampleFormat)codecpar->format)] ?: @"unknown";
            [audioStreams addObject:sInfo];
            
        } else if (codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            sInfo.streamType = VPFFmpegStreamTypeSubtitle;
            static NSSet *bitmapCodecs = nil;
            static dispatch_once_t bOnce;
            dispatch_once(&bOnce, ^{
                bitmapCodecs = [NSSet setWithObjects:@"dvd_subtitle", @"hdmv_pgs_subtitle", @"dvb_subtitle", @"xsub", @"vobsub", nil];
            });
            sInfo.isBitmapSubtitle = [bitmapCodecs containsObject:sInfo.codecName];
            [subStreams addObject:sInfo];
        }
    }
    
    sourceInfo.videoStreams = videoStreams;
    sourceInfo.audioStreams = audioStreams;
    sourceInfo.subtitleStreams = subStreams;
    
    // Extract Chapters
    NSMutableArray<VPFFmpegChapterInfo *> *chapters = [NSMutableArray array];
    for (unsigned int c = 0; c < formatCtx->nb_chapters; c++) {
        AVChapter *chapter = formatCtx->chapters[c];
        VPFFmpegChapterInfo *cInfo = [VPFFmpegChapterInfo new];
        cInfo.chapterID = chapter->id;
        double tb = av_q2d(chapter->time_base);
        cInfo.startTime = chapter->start * tb;
        cInfo.endTime = chapter->end * tb;
        NSDictionary *cMeta = ExtractMetadata(chapter->metadata);
        cInfo.title = cMeta[@"title"] ?: [NSString stringWithFormat:@"Chapter %u", c + 1];
        [chapters addObject:cInfo];
    }
    sourceInfo.chapters = chapters;
    sourceInfo.seekCues = @[];
    
    avformat_close_input(&formatCtx);
    
    [self registerSourceInfo:sourceInfo forURL:url];
    return sourceInfo;
}

@end
