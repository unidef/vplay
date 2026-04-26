#import "VPFFmpegLibrary.h"
#import "VPFFmpeg.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#include <libavutil/time.h>
#include <libavutil/pixdesc.h>

static NSError *LibraryError(int code, NSString *operation) {
    char text[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, text, sizeof(text));
    return [NSError errorWithDomain:@"VPlayFFmpegLibrary" code:code userInfo:@{
        NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@: %s", operation, text]}];
}
static NSString *String(const char *text) { return text ? [NSString stringWithUTF8String:text] ?: @"" : @""; }
static NSDictionary *Tags(AVDictionary *metadata) {
    NSMutableDictionary *tags = [NSMutableDictionary dictionary];
    const AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_get(metadata, "", entry, AV_DICT_IGNORE_SUFFIX))) tags[String(entry->key)] = String(entry->value);
    return tags;
}
static void InitializeFFmpeg(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ av_log_set_level(AV_LOG_ERROR); avformat_network_init(); });   // warnings such as the HLS muxer's zero-duration notice only clutter the console
}

typedef struct {
    __unsafe_unretained VPFFmpegJob *job;
    int64_t deadline;
} VPInterrupt;
static int Interrupted(void *opaque) {
    VPInterrupt *state = opaque;
    return state->job.cancelled || (state->deadline > 0 && av_gettime_relative() > state->deadline);
}
static int OpenInput(NSURL *url, AVFormatContext **format, VPInterrupt *interrupt) {
    InitializeFFmpeg();
    *format = avformat_alloc_context();
    if (!*format) return AVERROR(ENOMEM);
    (*format)->interrupt_callback = (AVIOInterruptCB){Interrupted, interrupt};
    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", "15000000", 0);
    const AVInputFormat *demuxer = NULL;
    if (url.isFileURL && [url.pathExtension.lowercaseString isEqual:@"ffconcat"]) {
        demuxer = av_find_input_format("concat");
        av_dict_set(&options, "safe", "0", 0);
    }
    if ([url.scheme.lowercaseString hasPrefix:@"rtsp"]) av_dict_set(&options, "rtsp_transport", "tcp", 0);
    interrupt->deadline = av_gettime_relative() + 15000000;
    int result = avformat_open_input(format, (url.isFileURL ? url.path : url.absoluteString).UTF8String, demuxer, &options);
    av_dict_free(&options);
    if (result >= 0) result = avformat_find_stream_info(*format, NULL);
    return result;
}
static AVCodecContext *OpenDecoder(AVStream *stream, int *result) {
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) { *result = AVERROR_DECODER_NOT_FOUND; return NULL; }
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) { *result = AVERROR(ENOMEM); return NULL; }
    *result = avcodec_parameters_to_context(context, stream->codecpar);
    context->pkt_timebase = stream->time_base;
    context->thread_count = 2;
    if (*result >= 0) *result = avcodec_open2(context, codec, NULL);
    if (*result < 0) avcodec_free_context(&context);
    return context;
}
static int StreamIndex(AVFormatContext *format, enum AVMediaType type, NSInteger ordinal) {
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *stream = format->streams[i];
        if (stream->codecpar->codec_type != type) continue;
        if (type == AVMEDIA_TYPE_VIDEO && (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        if (ordinal-- == 0) return (int)i;
    }
    return -1;
}

@implementation VPFFmpegLibrary
+ (BOOL)supportsStreamingConversion {
    return avcodec_find_encoder_by_name("h264_videotoolbox") && avcodec_find_encoder(AV_CODEC_ID_AAC) && av_guess_format("hls", NULL, NULL);
}
+ (NSDictionary *)probeURL:(NSURL *)url error:(NSError **)error {
    AVFormatContext *format = NULL;
    VPInterrupt interrupt = {nil, 0};
    int result = OpenInput(url, &format, &interrupt);
    if (result < 0) {
        if (error) *error = LibraryError(result, @"Unable to inspect media");
        avformat_close_input(&format); return nil;
    }
    NSMutableArray *streams = [NSMutableArray array];
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *stream = format->streams[i];
        AVCodecParameters *p = stream->codecpar;
        char layout[256] = {0};
        av_channel_layout_describe(&p->ch_layout, layout, sizeof(layout));
        NSString *field = @"unknown";
        switch (p->field_order) {
            case AV_FIELD_PROGRESSIVE: field = @"progressive"; break;
            case AV_FIELD_TT: field = @"tt"; break;
            case AV_FIELD_BB: field = @"bb"; break;
            case AV_FIELD_TB: field = @"tb"; break;
            case AV_FIELD_BT: field = @"bt"; break;
            default: break;
        }
        [streams addObject:@{@"index":@(i), @"codec_type":String(av_get_media_type_string(p->codec_type)),
            @"codec_name":String(avcodec_get_name(p->codec_id)), @"tags":Tags(stream->metadata),
            @"width":@(p->width), @"height":@(p->height), @"channels":@(p->ch_layout.nb_channels),
            @"sample_rate":@(p->sample_rate), @"channel_layout":String(layout), @"field_order":field,
            @"avg_frame_rate":[NSString stringWithFormat:@"%d/%d", stream->avg_frame_rate.num, stream->avg_frame_rate.den],
            @"r_frame_rate":[NSString stringWithFormat:@"%d/%d", stream->r_frame_rate.num, stream->r_frame_rate.den],
            @"disposition":@{@"default":@((stream->disposition & AV_DISPOSITION_DEFAULT) != 0),
                @"attached_pic":@((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0)}}];
    }
    // Inspect a few decoded frames when the container has no interlace information.
    int video = StreamIndex(format, AVMEDIA_TYPE_VIDEO, 0);
    if (video >= 0 && format->streams[video]->codecpar->field_order == AV_FIELD_UNKNOWN) {
        int status = 0, frames = 0;
        AVCodecContext *decoder = OpenDecoder(format->streams[video], &status);
        AVPacket *packet = av_packet_alloc(); AVFrame *frame = av_frame_alloc();
        for (int count = 0; decoder && packet && frame && count < 128 && frames < 5; count++) {
            if (av_read_frame(format, packet) < 0) break;
            if (packet->stream_index == video && avcodec_send_packet(decoder, packet) >= 0) {
                while (frames < 5 && avcodec_receive_frame(decoder, frame) >= 0) {
                    frames++;
                    if (frame->flags & AV_FRAME_FLAG_INTERLACED) {
                        NSMutableDictionary *info = [streams[video] mutableCopy];
                        info[@"field_order"] = (frame->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) ? @"tt" : @"bb";
                        streams[video] = info; frames = 5;
                    }
                    av_frame_unref(frame);
                }
            }
            av_packet_unref(packet);
        }
        av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&decoder);
    }
    int64_t size = format->pb ? avio_size(format->pb) : 0;
    NSDictionary *answer = @{@"streams":streams, @"format":@{
        @"format_name":String(format->iformat->name), @"format_long_name":String(format->iformat->long_name),
        @"duration":@(format->duration == AV_NOPTS_VALUE ? 0 : (double)format->duration / AV_TIME_BASE),
        @"bit_rate":@(format->bit_rate), @"size":@(MAX(0, size)), @"tags":Tags(format->metadata)}};
    avformat_close_input(&format);
    return answer;
}

+ (BOOL)extractSubtitles:(NSURL *)input index:(NSInteger)index output:(NSURL *)output error:(NSError **)error {
    VPInterrupt interrupt = {nil, 0}; AVFormatContext *format = NULL;
    AVCodecContext *decoder = NULL, *encoder = NULL; AVPacket *packet = NULL; char *text = NULL;
    FILE *file = NULL; int result = OpenInput(input, &format, &interrupt), cue = 0;
    if (result < 0) goto done;
    int stream = StreamIndex(format, AVMEDIA_TYPE_SUBTITLE, index);
    if (stream < 0) { result = AVERROR_STREAM_NOT_FOUND; goto done; }
    decoder = OpenDecoder(format->streams[stream], &result);
    if (!decoder) goto done;
    
    const AVCodec *subripCodec = avcodec_find_encoder(AV_CODEC_ID_SUBRIP);
    if (subripCodec) {
        encoder = avcodec_alloc_context3(subripCodec);
        if (encoder) {
            encoder->time_base = (AVRational){1, 1000};
            if (decoder->subtitle_header_size) {
                encoder->subtitle_header = av_memdup(decoder->subtitle_header, decoder->subtitle_header_size);
                encoder->subtitle_header_size = decoder->subtitle_header_size;
            }
            if (avcodec_open2(encoder, subripCodec, NULL) < 0) {
                avcodec_free_context(&encoder);
                encoder = NULL;
            }
        }
    }
    
    file = fopen(output.path.fileSystemRepresentation, "wb");
    if (!file) { result = AVERROR(errno); goto done; }
    packet = av_packet_alloc();
    text = (char *)malloc(65536);
    if (!packet || !text) { result = AVERROR(ENOMEM); goto done; }
    
    while (1) {
        interrupt.deadline = av_gettime_relative() + 15000000;
        result = av_read_frame(format, packet);
        if (result < 0) break;
        if (packet->stream_index == stream) {
            AVSubtitle sub = {0}; int got = 0;
            result = avcodec_decode_subtitle2(decoder, &sub, &got, packet);
            if (result >= 0 && got) {
                BOOL hasText = NO;
                if (encoder) {
                    int encRet = avcodec_encode_subtitle(encoder, (uint8_t *)text, 65535, &sub);
                    if (encRet > 0) {
                        if (encRet >= 65535) encRet = 65534;
                        text[encRet] = 0;
                        hasText = YES;
                    }
                }
                if (!hasText) {
                    int pos = 0;
                    for (unsigned r = 0; r < sub.num_rects; r++) {
                        const char *src = NULL;
                        if (sub.rects[r]->text) {
                            src = sub.rects[r]->text;
                        } else if (sub.rects[r]->ass) {
                            const char *comma = sub.rects[r]->ass;
                            for (int f = 0; f < 8 && comma; f++) {
                                comma = strchr(comma, ',');
                                if (comma) comma++;
                            }
                            src = comma ? comma : sub.rects[r]->ass;
                        }
                        if (src && *src) {
                            if (pos > 0 && pos < 65530) text[pos++] = '\n';
                            int len = snprintf(text + pos, 65535 - pos, "%s", src);
                            if (len > 0) pos += len;
                            hasText = YES;
                        }
                    }
                }
                if (hasText && text[0] != 0) {
                    double origin = format->start_time == AV_NOPTS_VALUE ? 0 : (double)format->start_time / AV_TIME_BASE;
                    double pts = 0;
                    if (sub.pts != AV_NOPTS_VALUE) {
                        pts = (double)sub.pts / AV_TIME_BASE;
                    } else if (packet->pts != AV_NOPTS_VALUE) {
                        pts = packet->pts * av_q2d(format->streams[stream]->time_base);
                    } else if (packet->dts != AV_NOPTS_VALUE) {
                        pts = packet->dts * av_q2d(format->streams[stream]->time_base);
                    }
                    int64_t start = MAX(0, llround((pts - origin) * 1000 + sub.start_display_time));
                    int64_t end = llround((pts - origin) * 1000 + sub.end_display_time);
                    if (end <= start || sub.end_display_time == UINT32_MAX) {
                        if (packet->duration > 0) {
                            end = start + MAX(1, llround(packet->duration * av_q2d(format->streams[stream]->time_base) * 1000));
                        } else {
                            end = start + 3000;
                        }
                    }
                    fprintf(file, "%d\n%02lld:%02lld:%02lld,%03lld --> %02lld:%02lld:%02lld,%03lld\n%s\n\n", ++cue, start/3600000, start/60000%60, start/1000%60, start%1000, end/3600000, end/60000%60, end/1000%60, end%1000, text);
                }
            }
            avsubtitle_free(&sub);
            if (result < 0) { av_packet_unref(packet); break; }
        }
        av_packet_unref(packet);
    }
    if (result == AVERROR_EOF) result = 0;
done:
    if (text) free(text);
    if (file && fclose(file) != 0 && result >= 0) result = AVERROR(errno);
    av_packet_free(&packet); avcodec_free_context(&decoder); avcodec_free_context(&encoder); avformat_close_input(&format);
    if (result < 0 && error) *error = LibraryError(result, @"Unable to extract text subtitles");
    return result >= 0;
}
+ (BOOL)parseArguments:(NSArray<NSString *> *)arguments input:(NSURL **)input output:(NSURL **)output options:(NSDictionary **)options error:(NSError **)error {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSString *inPath = nil, *outPath = nil, *problem = nil;
    NSDictionary *keys = @{@"-vf":@"videoFilter", @"-af":@"audioFilter", @"-ss":@"startOffset", @"-t":@"duration",
        @"-c:v":@"videoCodec", @"-c:a":@"audioCodec", @"-b:v":@"videoBitRate", @"-b:a":@"audioBitRate", @"-f":@"format"};
    NSSet *ignored = [NSSet setWithArray:@[@"-hide_banner", @"-nostdin", @"-nostats"]];
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *arg = arguments[i];
        if ([ignored containsObject:arg]) continue;
        if ([arg isEqual:@"-y"]) { values[@"overwrite"] = @YES; continue; }
        if ([arg isEqual:@"-n"]) { values[@"overwrite"] = @NO; continue; }
        if ([arg isEqual:@"-vn"]) { values[@"audioOnly"] = @YES; continue; }
        if ([arg isEqual:@"-an"]) { values[@"noAudio"] = @YES; continue; }
        if ([arg isEqual:@"-sn"] || [arg isEqual:@"-dn"]) continue;
        if ([arg isEqual:@"-i"] || keys[arg] || [arg isEqual:@"-map"]) {
            if (++i >= arguments.count) { problem = [@"Missing value for " stringByAppendingString:arg]; break; }
            NSString *value = arguments[i];
            if ([arg isEqual:@"-i"]) {
                if (inPath) { problem = @"Library conversion supports one input file per job."; break; }
                inPath = value;
            } else if ([arg isEqual:@"-map"]) {
                NSArray *parts = [[value stringByReplacingOccurrencesOfString:@"?" withString:@""] componentsSeparatedByString:@":"];
                NSScanner *scanner = [NSScanner scannerWithString:parts.lastObject];
                NSInteger index = 0;
                if (parts.count != 3 || ![parts[0] isEqual:@"0"] || ![@[@"v", @"a"] containsObject:parts[1]] ||
                    ![scanner scanInteger:&index] || !scanner.isAtEnd || index < 0) {
                    problem = @"Use -map 0:v:N or -map 0:a:N to select a video or audio track."; break;
                }
                values[[parts[1] isEqual:@"v"] ? @"videoStream" : @"audioStream"] = @(index);
            } else {
                if ([arg isEqual:@"-ss"] || [arg isEqual:@"-t"]) {
                    NSScanner *scanner = [NSScanner scannerWithString:value]; double seconds = 0;
                    if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !isfinite(seconds) || seconds < 0) {
                        problem = @"Start time and duration must be nonnegative seconds."; break;
                    }
                    values[keys[arg]] = @(seconds);
                } else values[keys[arg]] = value;
            }
        } else if ([arg hasPrefix:@"-"]) {
            problem = [NSString stringWithFormat:@"The built-in converter does not support %@. Supported options: -i, -ss, -t, -vf, -af, -map, -c:v, -c:a, -b:v, -b:a, -f, -vn, -an, -sn, -dn, -y, -n.", arg]; break;
        } else if (outPath) { problem = @"Library conversion supports one output file per job."; break; }
        else outPath = arg;
    }
    if (!problem && (!inPath.length || !outPath.length)) problem = @"Supply -i INPUT and an output file path.";
    if (problem) { if (error) *error = [NSError errorWithDomain:@"VPlayFFmpegLibrary" code:EINVAL userInfo:@{NSLocalizedDescriptionKey:problem}]; return NO; }
    *input = [inPath containsString:@"://"] ? [NSURL URLWithString:inPath] : [NSURL fileURLWithPath:inPath.stringByExpandingTildeInPath];
    *output = [NSURL fileURLWithPath:outPath.stringByExpandingTildeInPath];
    *options = values;
    return YES;
}
+ (nullable CIImage *)frameAtTime:(double)seconds fromURL:(NSURL *)url error:(NSError **)error {
    if (!url) return nil;
    AVFormatContext *formatCtx = NULL;
    VPInterrupt interrupt = {0};
    int ret = OpenInput(url, &formatCtx, &interrupt);
    if (ret < 0 || !formatCtx) {
        if (error) *error = LibraryError(ret, @"Failed to open media for frame preview");
        return nil;
    }
    
    int videoIdx = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoIdx < 0) {
        avformat_close_input(&formatCtx);
        if (error) *error = LibraryError(AVERROR_STREAM_NOT_FOUND, @"No video stream found for preview");
        return nil;
    }
    
    AVStream *stream = formatCtx->streams[videoIdx];
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) {
        avformat_close_input(&formatCtx);
        if (error) *error = LibraryError(AVERROR_DECODER_NOT_FOUND, @"No video decoder found for preview");
        return nil;
    }
    
    AVCodecContext *codecCtx = avcodec_alloc_context3(decoder);
    if (!codecCtx) {
        avformat_close_input(&formatCtx);
        return nil;
    }
    avcodec_parameters_to_context(codecCtx, stream->codecpar);
    if (avcodec_open2(codecCtx, decoder, NULL) < 0) {
        avcodec_free_context(&codecCtx);
        avformat_close_input(&formatCtx);
        return nil;
    }
    
    if (seconds > 0 && stream->time_base.den > 0) {
        int64_t targetTS = (int64_t)(seconds / av_q2d(stream->time_base));
        av_seek_frame(formatCtx, videoIdx, targetTS, AVSEEK_FLAG_BACKWARD);
    }
    
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    CIImage *result = nil;
    
    int tries = 0;
    while (av_read_frame(formatCtx, packet) >= 0 && tries++ < 300) {
        if (packet->stream_index == videoIdx) {
            if (avcodec_send_packet(codecCtx, packet) >= 0) {
                while (avcodec_receive_frame(codecCtx, frame) >= 0) {
                    int w = frame->width;
                    int h = frame->height;
                    if (w > 0 && h > 0) {
                        struct SwsContext *sws = sws_getContext(w, h, (enum AVPixelFormat)frame->format,
                                                                w, h, AV_PIX_FMT_BGRA,
                                                                SWS_FAST_BILINEAR, NULL, NULL, NULL);
                        if (sws) {
                            CVPixelBufferRef pb = NULL;
                            NSDictionary *attrs = @{
                                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                (id)kCVPixelBufferMetalCompatibilityKey: @YES,
                                (id)kCVPixelBufferCGImageCompatibilityKey: @YES
                            };
                            if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb) == kCVReturnSuccess) {
                                CVPixelBufferLockBaseAddress(pb, 0);
                                uint8_t *dst[4] = { (uint8_t *)CVPixelBufferGetBaseAddress(pb), NULL, NULL, NULL };
                                int linesize[4] = { (int)CVPixelBufferGetBytesPerRow(pb), 0, 0, 0 };
                                sws_scale(sws, (const uint8_t * const *)frame->data, frame->linesize, 0, h, dst, linesize);
                                CVPixelBufferUnlockBaseAddress(pb, 0);
                                result = [CIImage imageWithCVPixelBuffer:pb];
                                CVPixelBufferRelease(pb);
                            }
                            sws_freeContext(sws);
                        }
                    }
                    if (result) break;
                }
            }
        }
        av_packet_unref(packet);
        if (result) break;
    }
    
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codecCtx);
    avformat_close_input(&formatCtx);
    return result;
}
@end

typedef struct {
    int index;
    AVStream *input, *output;
    AVCodecContext *decoder, *encoder;
    AVFilterGraph *graph;
    AVFilterContext *source, *sink;
    AVFrame *first;
    int64_t nextPTS;
} VPStream;

typedef struct {
    AVCodecContext *decoder;
    AVSubtitle subtitle;
    BOOL valid;
    int index;
    double start, end;
    struct SwsContext *scaler;
} VPBitmapSubtitles;

static int64_t BitRate(id value, int64_t fallback) {
    if (!value) return fallback;
    NSString *text = [value description]; double number = text.doubleValue;
    if ([text.lowercaseString hasSuffix:@"m"]) number *= 1000000;
    else if ([text.lowercaseString hasSuffix:@"k"]) number *= 1000;
    return isfinite(number) && number > 0 && number < (double)INT64_MAX ? (int64_t)number : fallback;
}
static int ConfigureStream(VPStream *stream, AVFormatContext *output, NSDictionary *options, BOOL bitmap) {
    BOOL video = stream->decoder->codec_type == AVMEDIA_TYPE_VIDEO;
    BOOL hls = [options[@"format"] isEqual:@"hls"];
    NSString *name = options[video ? @"videoCodec" : @"audioCodec"] ?: (video ? (hls ? @"h264_videotoolbox" : @"mpeg4") : (hls ? @"aac" : @"pcm_s24le"));
    const AVCodec *codec = avcodec_find_encoder_by_name(name.UTF8String);
    if (!codec || codec->type != stream->decoder->codec_type) return AVERROR_ENCODER_NOT_FOUND;
    stream->encoder = avcodec_alloc_context3(codec);
    stream->graph = avfilter_graph_alloc();
    if (!stream->encoder || !stream->graph) return AVERROR(ENOMEM);
    stream->graph->nb_threads = 2;
    AVFrame *first = stream->first;
    AVCodecContext *encoder = stream->encoder;
    NSString *sourceArgs, *filter;
    double offset = [options[@"startOffset"] doubleValue], duration = [options[@"duration"] doubleValue];
    NSString *trim = [NSString stringWithFormat:@"%@trim=start=%.9f%@,%@setpts=PTS-%.9f/TB", video ? @"" : @"a", offset,
        duration > 0 ? [NSString stringWithFormat:@":duration=%.9f", duration] : @"", video ? @"" : @"a", offset];
    int result = 0;
    if (video) {
        AVRational sar = first->sample_aspect_ratio.num > 0 ? first->sample_aspect_ratio : (AVRational){1,1};
        sourceArgs = [NSString stringWithFormat:@"video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
            first->width, first->height, bitmap ? AV_PIX_FMT_RGBA : first->format, stream->input->time_base.num, stream->input->time_base.den, sar.num, sar.den];
        filter = [NSString stringWithFormat:@"%@,%@format=pix_fmts=yuv420p", trim,
            [options[@"videoFilter"] length] ? [options[@"videoFilter"] stringByAppendingString:@","] : @""];
    } else {
        if (!first->ch_layout.nb_channels || first->sample_rate <= 0) return AVERROR_INVALIDDATA;
        if (first->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
            int channels = first->ch_layout.nb_channels;
            av_channel_layout_uninit(&first->ch_layout); av_channel_layout_default(&first->ch_layout, channels);
        }
        char layout[256]; av_channel_layout_describe(&first->ch_layout, layout, sizeof(layout));
        sourceArgs = [NSString stringWithFormat:@"time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
            stream->input->time_base.num, stream->input->time_base.den, first->sample_rate, av_get_sample_fmt_name(first->format), layout];
        const enum AVSampleFormat *formats = NULL;
        avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, (const void **)&formats, NULL);
        enum AVSampleFormat sampleFormat = formats ? formats[0] : first->format;
        const int *rates = NULL;
        avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_RATE, 0, (const void **)&rates, NULL);
        int rate = first->sample_rate;
        if (rates) {
            rate = rates[0];
            for (int i = 0; rates[i]; i++) if (abs(rates[i] - first->sample_rate) < abs(rate - first->sample_rate)) rate = rates[i];
            filter = [NSString stringWithFormat:@"%@,%@aformat=sample_fmts=%s:sample_rates=%d", trim,
                [options[@"audioFilter"] length] ? [options[@"audioFilter"] stringByAppendingString:@","] : @"", av_get_sample_fmt_name(sampleFormat), rate];
        } else {
            filter = [NSString stringWithFormat:@"%@,%@aformat=sample_fmts=%s", trim,
                [options[@"audioFilter"] length] ? [options[@"audioFilter"] stringByAppendingString:@","] : @"", av_get_sample_fmt_name(sampleFormat)];
        }
    }
    result = avfilter_graph_create_filter(&stream->source, avfilter_get_by_name(video ? "buffer" : "abuffer"), "source", sourceArgs.UTF8String, NULL, stream->graph);
    if (result < 0) return result;
    result = avfilter_graph_create_filter(&stream->sink, avfilter_get_by_name(video ? "buffersink" : "abuffersink"), "sink", NULL, NULL, stream->graph);
    if (result < 0) return result;
    AVFilterInOut *inputs = avfilter_inout_alloc(), *outputs = avfilter_inout_alloc();
    if (!inputs || !outputs) { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs); return AVERROR(ENOMEM); }
    outputs->name = av_strdup("in"); outputs->filter_ctx = stream->source;
    inputs->name = av_strdup("out"); inputs->filter_ctx = stream->sink;
    result = avfilter_graph_parse_ptr(stream->graph, filter.UTF8String, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs); avfilter_inout_free(&outputs);
    if (result >= 0) result = avfilter_graph_config(stream->graph, NULL);
    if (result < 0) return result;
    if (video) {
        encoder->width = av_buffersink_get_w(stream->sink); encoder->height = av_buffersink_get_h(stream->sink);
        encoder->pix_fmt = av_buffersink_get_format(stream->sink);
        encoder->sample_aspect_ratio = av_buffersink_get_sample_aspect_ratio(stream->sink);
        encoder->framerate = stream->input->avg_frame_rate;
        if (encoder->framerate.num <= 0 || encoder->framerate.den <= 0) encoder->framerate = (AVRational){30,1};
        encoder->time_base = codec->id == AV_CODEC_ID_MPEG2VIDEO ? av_inv_q(encoder->framerate) : (AVRational){1, 60000};
        encoder->bit_rate = BitRate(options[@"videoBitRate"], 12000000);
        // One-second GOPs match the one-second HLS segments below, so a restarted conversion becomes playable quickly.
        encoder->gop_size = MAX(1, (int)ceil(av_q2d(encoder->framerate)));
        encoder->max_b_frames = 0;
        av_opt_set(encoder->priv_data, "allow_sw", "1", 0);
    } else {
        encoder->sample_rate = av_buffersink_get_sample_rate(stream->sink);
        encoder->sample_fmt = av_buffersink_get_format(stream->sink);
        result = av_buffersink_get_ch_layout(stream->sink, &encoder->ch_layout);
        if (result < 0) return result;
        encoder->time_base = (AVRational){1, encoder->sample_rate};
        encoder->bit_rate = BitRate(options[@"audioBitRate"], 256000);
    }
    encoder->thread_count = 2;
    if (output->oformat->flags & AVFMT_GLOBALHEADER) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    result = avcodec_open2(encoder, codec, NULL);
    if (result < 0) return result;
    if (!video && encoder->frame_size) av_buffersink_set_frame_size(stream->sink, encoder->frame_size);
    stream->output = avformat_new_stream(output, NULL);
    if (!stream->output) return AVERROR(ENOMEM);
    stream->output->time_base = encoder->time_base;
    av_dict_copy(&stream->output->metadata, stream->input->metadata, 0);
    return avcodec_parameters_from_context(stream->output->codecpar, encoder);
}
static int EncodeFrame(VPStream *stream, AVFrame *frame, AVFormatContext *output) {
    if (frame) {
        frame->pts = av_rescale_q(frame->pts, av_buffersink_get_time_base(stream->sink), stream->encoder->time_base);
        frame->pict_type = AV_PICTURE_TYPE_NONE;
    }
    int result = avcodec_send_frame(stream->encoder, frame);
    if (result < 0) return result;
    AVPacket *packet = av_packet_alloc();
    if (!packet) return AVERROR(ENOMEM);
    while ((result = avcodec_receive_packet(stream->encoder, packet)) >= 0) {
        av_packet_rescale_ts(packet, stream->encoder->time_base, stream->output->time_base);
        packet->stream_index = stream->output->index;
        result = av_interleaved_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0) break;
    }
    av_packet_free(&packet);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}
static int FilterFrame(VPStream *stream, AVFrame *frame, AVFormatContext *output) {
    int result = av_buffersrc_add_frame_flags(stream->source, frame, AV_BUFFERSRC_FLAG_KEEP_REF);
    if (result < 0) return result;
    AVFrame *filtered = av_frame_alloc();
    if (!filtered) return AVERROR(ENOMEM);
    while ((result = av_buffersink_get_frame(stream->sink, filtered)) >= 0) {
        result = EncodeFrame(stream, filtered, output);
        av_frame_unref(filtered);
        if (result < 0) break;
    }
    av_frame_free(&filtered);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}
static AVFrame *BlendSubtitle(AVFrame *frame, VPBitmapSubtitles *subtitles, double seconds) {
    AVFrame *rgba = av_frame_alloc();
    if (!rgba) return NULL;
    rgba->format = AV_PIX_FMT_RGBA; rgba->width = frame->width; rgba->height = frame->height;
    if (av_frame_get_buffer(rgba, 32) < 0 || av_frame_copy_props(rgba, frame) < 0) { av_frame_free(&rgba); return NULL; }
    subtitles->scaler = sws_getCachedContext(subtitles->scaler, frame->width, frame->height, frame->format,
        frame->width, frame->height, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!subtitles->scaler) { av_frame_free(&rgba); return NULL; }
    sws_scale(subtitles->scaler, (const uint8_t * const *)frame->data, frame->linesize, 0, frame->height, rgba->data, rgba->linesize);
    if (!subtitles->valid || seconds < subtitles->start || seconds >= subtitles->end) return rgba;
    for (unsigned i = 0; i < subtitles->subtitle.num_rects; i++) {
        AVSubtitleRect *rect = subtitles->subtitle.rects[i];
        if (rect->type != SUBTITLE_BITMAP || !rect->data[0] || !rect->data[1]) continue;
        int canvasW = subtitles->decoder->width > 0 ? subtitles->decoder->width : frame->width;
        int canvasH = subtitles->decoder->height > 0 ? subtitles->decoder->height : frame->height;
        double sx = (double)frame->width/canvasW, sy = (double)frame->height/canvasH;
        int left = (int)(rect->x*sx), top = (int)(rect->y*sy);
        int width = (int)ceil(rect->w*sx), height = (int)ceil(rect->h*sy);
        for (int y = MAX(0, top); y < MIN(frame->height, top+height); y++) {
            for (int x = MAX(0, left); x < MIN(frame->width, left+width); x++) {
                int rx = MIN(rect->w-1, (int)((x-left)/sx)), ry = MIN(rect->h-1, (int)((y-top)/sy));
                uint8_t index = rect->data[0][ry*rect->linesize[0]+rx];
                if (index >= rect->nb_colors) continue;
                uint32_t color = ((uint32_t *)rect->data[1])[index];
                int alpha = color >> 24;
                uint8_t *pixel = rgba->data[0] + y*rgba->linesize[0]+x*4;
                for (int channel = 0; channel < 3; channel++) pixel[channel] = (((color >> (16-channel*8)) & 255)*alpha + pixel[channel]*(255-alpha)+127)/255;
            }
        }
    }
    return rgba;
}
static int DecodePacket(VPStream *stream, AVPacket *packet, AVFormatContext *output, double origin, VPBitmapSubtitles *subtitles) {
    int result = avcodec_send_packet(stream->decoder, packet);
    if (result < 0) return result;
    AVFrame *frame = av_frame_alloc();
    if (!frame) return AVERROR(ENOMEM);
    while ((result = avcodec_receive_frame(stream->decoder, frame)) >= 0) {
        int64_t pts = frame->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) pts = stream->nextPTS;
        frame->pts = pts - llround(origin / av_q2d(stream->input->time_base));
        int64_t duration = frame->nb_samples > 0 ? av_rescale_q(frame->nb_samples, (AVRational){1,frame->sample_rate}, stream->input->time_base) : frame->duration;
        if (duration <= 0) duration = av_rescale_q(1, av_inv_q(stream->encoder->framerate), stream->input->time_base);
        stream->nextPTS = pts + MAX(1, duration);
        if (stream->decoder->codec_type == AVMEDIA_TYPE_VIDEO && subtitles->decoder) {
            AVFrame *rgba = BlendSubtitle(frame, subtitles, frame->pts * av_q2d(stream->input->time_base));
            result = rgba ? FilterFrame(stream, rgba, output) : AVERROR(ENOMEM);
            av_frame_free(&rgba);
        } else result = FilterFrame(stream, frame, output);
        av_frame_unref(frame);
        if (result < 0) break;
    }
    av_frame_free(&frame);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}



@interface VPFFmpegJob ()
@property (atomic, readwrite, getter=isRunning) BOOL running;
@property (atomic, readwrite, getter=isCancelled) BOOL cancelled;
@end
@implementation VPFFmpegJob
- (void)cancel { self.cancelled = YES; }
- (void)startInput:(NSURL *)input output:(NSURL *)output options:(NSDictionary *)options completion:(void (^)(NSError *))completion {
    self.running = YES;
    NSDictionary *snapshot = [options copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        [self runInput:input output:output options:snapshot error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
- (BOOL)runInput:(NSURL *)input output:(NSURL *)destination options:(NSDictionary *)options error:(NSError **)error {
    self.running = YES;
    VPInterrupt interrupt = {self, 0};
    AVFormatContext *format = NULL, *output = NULL;
    VPStream streams[2] = {{.index=-1}, {.index=-1}};
    VPBitmapSubtitles subtitles = {.index=-1};
    AVPacket *packet = NULL;
    NSMutableArray<NSValue *> *pending = [NSMutableArray array];
    NSString *operation = @"Opening media";
    NSString *formatName = options[@"format"];
    double offset = [options[@"startOffset"] doubleValue], origin = 0;
    int result = 0; BOOL header = NO, hardwareUnavailable = NO;
    AVDictionary *muxOptions = NULL;
    if (input.isFileURL && [input.URLByResolvingSymlinksInPath isEqual:destination.URLByResolvingSymlinksInPath]) {
        result = AVERROR(EINVAL); operation = @"Input and output must be different files"; goto done;
    }
    if (![options[@"overwrite"] boolValue] && [NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        result = AVERROR(EEXIST); operation = @"Output already exists (use -y to replace it)"; goto done;
    }
    if (self.cancelled) { result = AVERROR_EXIT; goto done; }
    result = OpenInput(input, &format, &interrupt);
    if (result < 0) goto done;
    origin = format->start_time == AV_NOPTS_VALUE ? 0 : (double)format->start_time / AV_TIME_BASE;
    streams[0].index = [options[@"audioOnly"] boolValue] ? -1 : StreamIndex(format, AVMEDIA_TYPE_VIDEO, [options[@"videoStream"] integerValue]);
    streams[1].index = [options[@"noAudio"] boolValue] ? -1 : StreamIndex(format, AVMEDIA_TYPE_AUDIO, [options[@"audioStream"] integerValue]);
    if (streams[0].index < 0 && streams[1].index < 0) { result = AVERROR_STREAM_NOT_FOUND; goto done; }
    if (options[@"burnSubtitleStream"] && streams[0].index >= 0) {
        subtitles.index = StreamIndex(format, AVMEDIA_TYPE_SUBTITLE, [options[@"burnSubtitleStream"] integerValue]);
        if (subtitles.index < 0) { result = AVERROR_STREAM_NOT_FOUND; goto done; }
        subtitles.decoder = OpenDecoder(format->streams[subtitles.index], &result);
        if (!subtitles.decoder) goto done;
    }
    for (int i = 0; i < 2; i++) {
        if (streams[i].index < 0) continue;
        streams[i].input = format->streams[streams[i].index];
        streams[i].decoder = OpenDecoder(streams[i].input, &result);
        if (!streams[i].decoder) goto done;
    }
    if (offset > 0) {
        result = avformat_seek_file(format, -1, INT64_MIN, llround((origin+offset)*AV_TIME_BASE), INT64_MAX, 0);
        // Nonseekable sources are decoded from the beginning and trimmed by the filter graph.
        if (result < 0 && format->pb && (format->pb->seekable & AVIO_SEEKABLE_NORMAL)) goto done;
    }
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto done; }
    operation = @"Reading the first audio/video frames";
    // Decode enough to learn actual sample/pixel formats. Replay saved packets after configuring encoders.
    {
        NSUInteger bytes = 0;
        while ((streams[0].decoder && !streams[0].first) || (streams[1].decoder && !streams[1].first)) {
            interrupt.deadline = av_gettime_relative() + 15000000;
            result = av_read_frame(format, packet);
            if (result < 0) break;
            AVPacket *saved = av_packet_clone(packet);
            if (!saved) { result = AVERROR(ENOMEM); break; }
            [pending addObject:[NSValue valueWithPointer:saved]];
            bytes += packet->size;
            if (bytes > 64*1024*1024 || pending.count > 10000) { result = AVERROR(ENOBUFS); break; }
            for (int i = 0; i < 2; i++) {
                VPStream *stream = &streams[i];
                if (stream->index != packet->stream_index || stream->first) continue;
                result = avcodec_send_packet(stream->decoder, packet);
                if (result < 0) break;
                AVFrame *frame = av_frame_alloc();
                if (!frame) { result = AVERROR(ENOMEM); break; }
                result = avcodec_receive_frame(stream->decoder, frame);
                if (result >= 0) stream->first = frame;
                else { av_frame_free(&frame); if (result == AVERROR(EAGAIN)) result = 0; }
            }
            av_packet_unref(packet);
            if (result < 0) break;
        }
        if (result == AVERROR_EOF) {
            result = 0;
            for (int i = 0; i < 2; i++) if (streams[i].decoder && !streams[i].first) {
                avcodec_send_packet(streams[i].decoder, NULL);
                streams[i].first = av_frame_alloc();
                result = streams[i].first ? avcodec_receive_frame(streams[i].decoder, streams[i].first) : AVERROR(ENOMEM);
                if (result < 0) break;
            }
        }
        if (result < 0) goto done;
    }
    operation = @"Configuring conversion filters and encoders";
    result = avformat_alloc_output_context2(&output, NULL, formatName.length ? formatName.UTF8String : NULL, destination.path.fileSystemRepresentation);
    if (result < 0 || !output) { if (result >= 0) result = AVERROR_MUXER_NOT_FOUND; goto done; }
    output->interrupt_callback = (AVIOInterruptCB){Interrupted, &interrupt};
    for (int i = 0; i < 2; i++) if (streams[i].decoder) {
        result = ConfigureStream(&streams[i], output, options, subtitles.decoder != NULL);
        if (result < 0) {
            hardwareUnavailable = streams[i].encoder && streams[i].encoder->codec &&
                strcmp(streams[i].encoder->codec->name, "h264_videotoolbox") == 0 &&
                (result == AVERROR_EXTERNAL || result == AVERROR(ENOSYS));
            goto done;
        }
        avcodec_flush_buffers(streams[i].decoder);
        streams[i].nextPTS = streams[i].input->start_time == AV_NOPTS_VALUE ? 0 : streams[i].input->start_time;
    }
    av_dict_copy(&output->metadata, format->metadata, 0);
    operation = @"Opening conversion output";
    if (!(output->oformat->flags & AVFMT_NOFILE)) {
        result = avio_open2(&output->pb, destination.path.fileSystemRepresentation, AVIO_FLAG_WRITE, &output->interrupt_callback, NULL);
        if (result < 0) goto done;
    }
    if ([formatName isEqual:@"hls"]) {
        av_dict_set(&muxOptions, "hls_time", "1", 0);
        av_dict_set(&muxOptions, "hls_list_size", "0", 0);
        av_dict_set(&muxOptions, "hls_playlist_type", "event", 0);
        av_dict_set(&muxOptions, "hls_flags", "independent_segments+temp_file", 0);
    } else if ([destination.pathExtension.lowercaseString isEqual:@"mov"] || [destination.pathExtension.lowercaseString isEqual:@"mp4"]) {
        av_dict_set(&muxOptions, "movflags", "+faststart", 0);
    }
    interrupt.deadline = 0;
    result = avformat_write_header(output, &muxOptions);
    if (result < 0) goto done;
    header = YES; operation = @"Converting media";
    {
        NSUInteger cursor = 0;
        while (!self.cancelled) {
            av_packet_unref(packet);
            if (cursor < pending.count) {
                AVPacket *saved = pending[cursor++].pointerValue;
                av_packet_move_ref(packet, saved);
            } else {
                interrupt.deadline = av_gettime_relative() + 15000000;
                result = av_read_frame(format, packet);
                interrupt.deadline = 0;
                if (result < 0) break;
            }
            if (subtitles.decoder && packet->stream_index == subtitles.index) {
                AVSubtitle sub = {0}; int got = 0;
                result = avcodec_decode_subtitle2(subtitles.decoder, &sub, &got, packet);
                if (result >= 0 && got) {
                    avsubtitle_free(&subtitles.subtitle);
                    subtitles.subtitle = sub; subtitles.valid = YES;
                    double pts = sub.pts == AV_NOPTS_VALUE ? packet->pts * av_q2d(format->streams[subtitles.index]->time_base) : (double)sub.pts / AV_TIME_BASE;
                    subtitles.start = pts - origin + sub.start_display_time/1000.0;
                    subtitles.end = sub.end_display_time == UINT32_MAX ? DBL_MAX : pts - origin + sub.end_display_time/1000.0;
                } else avsubtitle_free(&sub);
            } else for (int i = 0; i < 2; i++) if (streams[i].decoder && packet->stream_index == streams[i].index) {
                result = DecodePacket(&streams[i], packet, output, origin, &subtitles);
                break;
            }
            if (result < 0) break;
            double duration = [options[@"duration"] doubleValue];
            if (duration > 0 && packet->pts != AV_NOPTS_VALUE && packet->pts * av_q2d(format->streams[packet->stream_index]->time_base) - origin > offset + duration + 2) {
                result = AVERROR_EOF; break;
            }
        }
    }
    if (self.cancelled) result = AVERROR_EXIT;
    if (result == AVERROR_EOF) {
        result = 0;
        for (int i = 0; i < 2; i++) if (streams[i].decoder) {
            result = DecodePacket(&streams[i], NULL, output, origin, &subtitles);
            if (result >= 0) result = FilterFrame(&streams[i], NULL, output);
            if (result >= 0) result = EncodeFrame(&streams[i], NULL, output);
            if (result < 0) break;
        }
    }
    if (result >= 0 && header) result = av_write_trailer(output);
done:
    av_dict_free(&muxOptions);
    av_packet_free(&packet);
    for (NSValue *value in pending) { AVPacket *saved = value.pointerValue; av_packet_free(&saved); }
    for (int i = 0; i < 2; i++) {
        av_frame_free(&streams[i].first); avcodec_free_context(&streams[i].decoder);
        avcodec_free_context(&streams[i].encoder); avfilter_graph_free(&streams[i].graph);
    }
    avsubtitle_free(&subtitles.subtitle); avcodec_free_context(&subtitles.decoder); sws_freeContext(subtitles.scaler);
    if (output) { if (!(output->oformat->flags & AVFMT_NOFILE)) avio_closep(&output->pb); avformat_free_context(output); }
    avformat_close_input(&format);
    self.running = NO;
    if (result < 0 && error) {
        NSError *failure = LibraryError(result, self.cancelled ? @"Conversion cancelled" : operation);
        if (hardwareUnavailable) {
            NSMutableDictionary *info = [failure.userInfo mutableCopy];
            info[@"hardwareEncoderUnavailable"] = @YES;
            failure = [NSError errorWithDomain:failure.domain code:failure.code userInfo:info];
        }
        *error = failure;
    }
    return result >= 0;
}
@end

@implementation VPFFmpegLibrary (AudioDemo)
+ (BOOL)renderAudioDemoWithGraph:(NSString *)filter output:(NSURL *)destination error:(NSError **)error {
    VPStream stream = {0}; AVFormatContext *output = NULL;
    AVFilterInOut *inputs = NULL, *outputs = NULL;
    AVFrame *frame = NULL;
    int result = 0;
    NSString *graphText = [NSString stringWithFormat:
        @"sine=frequency=261.63:sample_rate=44100:duration=8[c];"
         "sine=frequency=329.63:sample_rate=44100:duration=8[e];"
         "sine=frequency=392.00:sample_rate=44100:duration=8[g];"
         "[c][e][g]amix=inputs=3:normalize=1,aformat=channel_layouts=stereo,%@"
         "alimiter=limit=0.95,aformat=sample_fmts=s16:sample_rates=44100:channel_layouts=stereo[out]",
        filter.length ? [filter stringByAppendingString:@","] : @""];
    stream.graph = avfilter_graph_alloc();
    if (!stream.graph) { result = AVERROR(ENOMEM); goto done; }
    stream.graph->nb_threads = 2;
    result = avfilter_graph_create_filter(&stream.sink, avfilter_get_by_name("abuffersink"), "sink", NULL, NULL, stream.graph);
    if (result < 0) goto done;
    inputs = avfilter_inout_alloc();
    if (!inputs) { result = AVERROR(ENOMEM); goto done; }
    inputs->name = av_strdup("out"); inputs->filter_ctx = stream.sink;
    result = avfilter_graph_parse_ptr(stream.graph, graphText.UTF8String, &inputs, &outputs, NULL);
    if (result >= 0) result = avfilter_graph_config(stream.graph, NULL);
    if (result < 0) goto done;
    result = avformat_alloc_output_context2(&output, NULL, "wav", destination.path.fileSystemRepresentation);
    if (result < 0) goto done;
    stream.encoder = avcodec_alloc_context3(avcodec_find_encoder(AV_CODEC_ID_PCM_S16LE));
    if (!stream.encoder) { result = AVERROR(ENOMEM); goto done; }
    stream.encoder->sample_rate = 44100; stream.encoder->sample_fmt = AV_SAMPLE_FMT_S16;
    stream.encoder->time_base = (AVRational){1,44100};
    av_channel_layout_default(&stream.encoder->ch_layout, 2);
    result = avcodec_open2(stream.encoder, stream.encoder->codec, NULL);
    if (result < 0) goto done;
    stream.output = avformat_new_stream(output, NULL);
    if (!stream.output) { result = AVERROR(ENOMEM); goto done; }
    stream.output->time_base = stream.encoder->time_base;
    result = avcodec_parameters_from_context(stream.output->codecpar, stream.encoder);
    if (result < 0) goto done;
    result = avio_open(&output->pb, destination.path.fileSystemRepresentation, AVIO_FLAG_WRITE);
    if (result < 0) goto done;
    result = avformat_write_header(output, NULL);
    if (result < 0) goto done;
    frame = av_frame_alloc();
    if (!frame) { result = AVERROR(ENOMEM); goto done; }
    while ((result = av_buffersink_get_frame(stream.sink, frame)) >= 0) {
        result = EncodeFrame(&stream, frame, output); av_frame_unref(frame);
        if (result < 0) break;
    }
    if (result == AVERROR_EOF) result = EncodeFrame(&stream, NULL, output);
    if (result >= 0) result = av_write_trailer(output);
done:
    av_frame_free(&frame); avcodec_free_context(&stream.encoder);
    avfilter_inout_free(&inputs); avfilter_inout_free(&outputs); avfilter_graph_free(&stream.graph);
    if (output) { avio_closep(&output->pb); avformat_free_context(output); }
    if (result < 0 && error) *error = LibraryError(result, @"Unable to render audio preview");
    return result >= 0;
}
@end
