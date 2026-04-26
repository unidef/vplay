#import "VPMediaProbe.h"
#import "VPFFmpegLibrary.h"

@implementation VPTrack
- (NSString *)displayName {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *kindName = self.kind == VPTrackKindVideo ? @"Video" : (self.kind == VPTrackKindAudio ? @"Audio" : @"Subtitle");
    [parts addObject:self.title.length ? self.title : [NSString stringWithFormat:@"%@ %ld", kindName, (long)self.index + 1]];
    if (self.language.length && ![self.language isEqual:@"und"]) {
        NSString *name = [NSLocale.currentLocale localizedStringForLanguageCode:self.language];
        [parts addObject:name ?: self.language];
    }
    NSMutableArray *tech = [NSMutableArray array];
    if (self.codec.length) [tech addObject:self.codec.uppercaseString];
    if (self.detail.length) [tech addObject:self.detail];
    NSString *name = [parts componentsJoinedByString:@" — "];
    return tech.count ? [NSString stringWithFormat:@"%@  (%@)", name, [tech componentsJoinedByString:@", "]] : name;
}
@end

static double ratio(NSString *value) {
    NSArray *p = [value componentsSeparatedByString:@"/"];
    if (p.count == 2 && [p[1] doubleValue] > 0) return [p[0] doubleValue] / [p[1] doubleValue];
    return [value doubleValue];
}

@implementation VPMediaProbe
- (BOOL)hasVideo { return self.videoTracks.count > 0; }

+ (void)probeURL:(NSURL *)url completion:(void (^)(VPMediaProbe *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VPMediaProbe *probe = [self probeSynchronously:url];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(probe); });
    });
}

+ (VPMediaProbe *)probeSynchronously:(NSURL *)url {
    NSDictionary *json = [VPFFmpegLibrary probeURL:url error:nil];
    if (!json) return nil;

    VPMediaProbe *probe = [VPMediaProbe new];
    NSDictionary *format = json[@"format"];
    probe.formatName = format[@"format_long_name"] ?: format[@"format_name"] ?: @"";
    probe.duration = [format[@"duration"] doubleValue];
    probe.bitRate = [format[@"bit_rate"] longLongValue];
    probe.sizeBytes = [format[@"size"] longLongValue];
    NSMutableDictionary *tags = [NSMutableDictionary dictionary];
    void (^collect)(NSDictionary *) = ^(NSDictionary *source) {
        for (NSString *key in source) if (!tags[key.lowercaseString]) tags[key.lowercaseString] = [NSString stringWithFormat:@"%@", source[key]];
    };
    collect(format[@"tags"]);

    NSMutableArray *video = [NSMutableArray array], *audio = [NSMutableArray array], *subs = [NSMutableArray array];
    NSSet *bitmapCodecs = [NSSet setWithArray:@[@"dvd_subtitle", @"hdmv_pgs_subtitle", @"dvb_subtitle", @"xsub", @"vobsub"]];
    for (NSDictionary *stream in json[@"streams"]) {
        NSString *type = stream[@"codec_type"];
        VPTrack *track = [VPTrack new];
        track.streamIndex = [stream[@"index"] integerValue];
        track.codec = stream[@"codec_name"];
        NSDictionary *streamTags = stream[@"tags"];
        for (NSString *key in streamTags) {
            if ([key.lowercaseString isEqual:@"title"]) track.title = streamTags[key];
            if ([key.lowercaseString isEqual:@"language"]) track.language = streamTags[key];
        }
        track.isDefault = [stream[@"disposition"][@"default"] boolValue];
        if ([type isEqual:@"video"]) {
            if ([stream[@"disposition"][@"attached_pic"] boolValue]) continue;   // cover art is not a video track
            track.kind = VPTrackKindVideo; track.index = video.count;
            double fps = ratio(stream[@"avg_frame_rate"] ?: @"0");
            if (fps <= 0) fps = ratio(stream[@"r_frame_rate"] ?: @"0");
            NSInteger w = [stream[@"width"] integerValue], h = [stream[@"height"] integerValue];

            NSString *fieldOrder = stream[@"field_order"];
            track.fieldOrder = fieldOrder;
            BOOL streamInterlaced = NO;
            NSString *parity = @"auto";
            if (fieldOrder.length) {
                NSString *fo = fieldOrder.lowercaseString;
                if ([fo isEqualToString:@"tt"] || [fo isEqualToString:@"tff"] || [fo isEqualToString:@"top first"]) {
                    streamInterlaced = YES;
                    parity = @"tff";
                } else if ([fo isEqualToString:@"bb"] || [fo isEqualToString:@"bff"] || [fo isEqualToString:@"bottom first"]) {
                    streamInterlaced = YES;
                    parity = @"bff";
                } else if ([fo isEqualToString:@"tb"] || [fo isEqualToString:@"bt"]) {
                    streamInterlaced = YES;
                    parity = @"auto";
                } else if ([fo isEqualToString:@"interlaced"]) {
                    streamInterlaced = YES;
                    parity = @"auto";
                }
            }

            // If field_order in stream header is unknown or missing, inspect up to 5 frames
            if (!streamInterlaced && (!fieldOrder.length || [fieldOrder.lowercaseString isEqualToString:@"unknown"])) {
                NSString *ext = url.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"vob"] || [ext isEqualToString:@"ffconcat"] || [ext isEqualToString:@"iso"]) {
                    streamInterlaced = YES;
                    parity = @"tff";
                }
            }
            track.interlaced = streamInterlaced;
            track.fieldOrder = parity;

            NSString *interlaceDetail = streamInterlaced ? [NSString stringWithFormat:@" · interlaced (%@)", parity.uppercaseString] : @"";
            track.detail = [NSString stringWithFormat:@"%ld×%ld%@%@", (long)w, (long)h, fps > 0 ? [NSString stringWithFormat:@" · %.3g fps", fps] : @"", interlaceDetail];
            if (!video.count) {
                probe.frameRate = fps;
                probe.videoSize = NSMakeSize(w, h);
                probe.isInterlaced = streamInterlaced;
                probe.detectedFieldOrder = parity;
            }
            [video addObject:track];
        } else if ([type isEqual:@"audio"]) {
            track.kind = VPTrackKindAudio; track.index = audio.count;
            track.channels = [stream[@"channels"] integerValue];
            NSString *layout = stream[@"channel_layout"] ?: [NSString stringWithFormat:@"%@ ch", stream[@"channels"] ?: @"?"];
            track.detail = [NSString stringWithFormat:@"%@ · %.4g kHz", layout, [stream[@"sample_rate"] doubleValue] / 1000];
            [audio addObject:track];
        } else if ([type isEqual:@"subtitle"]) {
            track.kind = VPTrackKindSubtitle; track.index = subs.count;
            track.bitmap = [bitmapCodecs containsObject:track.codec ?: @""];
            [subs addObject:track];
        } else continue;
        if (!tags.count || video.count + audio.count <= 1) collect(streamTags);
    }
    // A disc list has no duration of its own: add up the files it joins.
    if (probe.duration <= 0 && [url.pathExtension.lowercaseString isEqual:@"ffconcat"]) {
        NSString *list = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"file '"] || line.length < 8) continue;
            NSString *path = [[line substringWithRange:NSMakeRange(6, line.length - 7)] stringByReplacingOccurrencesOfString:@"'\\''" withString:@"'"];
            VPMediaProbe *part = [self probeSynchronously:[NSURL fileURLWithPath:path]];
            probe.duration += part.duration;
            probe.sizeBytes += part.sizeBytes;
        }
    }
    probe.videoTracks = video; probe.audioTracks = audio; probe.subtitleTracks = subs;
    probe.tags = tags;
    return probe;
}

- (NSArray<NSString *> *)overlayLinesForURL:(NSURL *)url {
    NSMutableArray *lines = [NSMutableArray array];
    NSString *title = self.tags[@"title"];
    [lines addObject:title.length ? title : (url.isFileURL ? url.lastPathComponent.stringByDeletingPathExtension : url.absoluteString)];
    NSMutableArray *credits = [NSMutableArray array];
    for (NSString *key in @[@"artist", @"album_artist", @"album", @"show", @"season_number", @"episode_id", @"genre", @"date", @"year", @"comment"]) {
        NSString *value = self.tags[key];
        if (value.length && value.length < 120) [credits addObject:[NSString stringWithFormat:@"%@: %@", key.capitalizedString, value]];
    }
    [lines addObjectsFromArray:credits];
    NSMutableArray *facts = [NSMutableArray array];
    if (self.duration > 0) {
        long total = (long)self.duration;
        [facts addObject:total >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60] : [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60]];
    }
    if (self.videoTracks.count) {
        VPTrack *v = self.videoTracks.firstObject;
        [facts addObject:[NSString stringWithFormat:@"%@ %@", (v.codec ?: @"video").uppercaseString, v.detail ?: @""]];
    }
    if (self.audioTracks.count) {
        VPTrack *a = self.audioTracks.firstObject;
        [facts addObject:[NSString stringWithFormat:@"%@ %@", (a.codec ?: @"audio").uppercaseString, a.detail ?: @""]];
    }
    if (self.subtitleTracks.count) [facts addObject:[NSString stringWithFormat:@"%lu subtitle track%@", (unsigned long)self.subtitleTracks.count, self.subtitleTracks.count == 1 ? @"" : @"s"]];
    if (facts.count) [lines addObject:[facts componentsJoinedByString:@"  ·  "]];
    NSMutableArray *container = [NSMutableArray array];
    if ([url.pathExtension.lowercaseString isEqual:@"ffconcat"]) return lines;   // a disc list file says nothing useful about the disc
    if (self.formatName.length) [container addObject:self.formatName];
    if (self.sizeBytes > 0) [container addObject:[NSByteCountFormatter stringFromByteCount:self.sizeBytes countStyle:NSByteCountFormatterCountStyleFile]];
    if (self.bitRate > 0) [container addObject:[NSString stringWithFormat:@"%.1f Mb/s", self.bitRate / 1e6]];
    if (container.count) [lines addObject:[container componentsJoinedByString:@"  ·  "]];
    return lines;
}
@end
