#import "VPSubtitles.h"
#import "VPFFmpegLibrary.h"

@interface VPSubtitleCue : NSObject
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSString *text;
@end
@implementation VPSubtitleCue
@end

@interface VPSubtitleTrack () {
    NSInteger _lastIndex;
}
@property (nonatomic, strong) NSArray<VPSubtitleCue *> *cues;
@end

static NSCache<NSString *, VPSubtitleTrack *> *SubtitleCache(void) {
    static NSCache<NSString *, VPSubtitleTrack *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 50;
    });
    return cache;
}

static NSString *CacheKey(NSURL *media, NSInteger index) {
    return [NSString stringWithFormat:@"%@#sub:%ld", media.absoluteString, (long)index];
}

@implementation VPSubtitleTrack

- (instancetype)init {
    if ((self = [super init])) {
        _lastIndex = 0;
    }
    return self;
}

- (NSUInteger)cueCount { return self.cues.count; }

+ (nullable instancetype)cachedTrackForMedia:(NSURL *)media subtitleIndex:(NSInteger)index {
    if (!media) return nil;
    return [SubtitleCache() objectForKey:CacheKey(media, index)];
}

+ (void)clearCache {
    [SubtitleCache() removeAllObjects];
}

+ (void)prefetchTrackForMedia:(NSURL *)media subtitleIndex:(NSInteger)index {
    if (!media) return;
    if ([self cachedTrackForMedia:media subtitleIndex:index]) return;
    [self extractFromMedia:media subtitleIndex:index completion:^(VPSubtitleTrack * _Nullable track, NSError * _Nullable error) {
        // Cached internally
    }];
}

#pragma mark - Parsing

/// "00:01:02,345", "01:02.345" or "0:01:02.34" to seconds.
static double ParseTimestamp(NSString *text) {
    NSString *clean = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] stringByReplacingOccurrencesOfString:@"," withString:@"."];
    // Remove any trailing WebVTT cue settings like "align:start"
    NSArray *tokens = [clean componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (tokens.count) clean = tokens.firstObject;

    NSArray *parts = [clean componentsSeparatedByString:@":"];
    double seconds = 0;
    for (NSString *part in parts) seconds = seconds * 60 + part.doubleValue;
    return seconds;
}

static BOOL IsPureInteger(NSString *s) {
    if (!s.length) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    NSInteger val;
    return [scanner scanInteger:&val] && scanner.isAtEnd;
}

static NSString *StripMarkup(NSString *text) {
    if (!text.length) return @"";
    NSMutableString *result = [text mutableCopy];

    // Remove ASS drawing commands: {\p1} ... {\p0}
    NSRegularExpression *drawingRegex = [NSRegularExpression regularExpressionWithPattern:@"\\{\\\\p[1-9]\\}.*?\\{\\\\p0\\}" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    if (drawingRegex) {
        [drawingRegex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    // Remove ASS override tags: {\...} (e.g. {\pos}, {\c&H...}, {\k20}, {\an8}, {\fs...}, {\r})
    NSRegularExpression *assRegex = [NSRegularExpression regularExpressionWithPattern:@"\\{\\\\[^}]*\\}" options:0 error:nil];
    if (assRegex) {
        [assRegex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    // Remove remaining bracketed tags only if they contain backslashes or styling commands
    NSRegularExpression *braceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}\\w]*[\\/][^}]*\\}" options:0 error:nil];
    if (braceRegex) {
        [braceRegex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    // Remove WebVTT timestamp tags <00:01:02.345>
    NSRegularExpression *vttTimeRegex = [NSRegularExpression regularExpressionWithPattern:@"<\\d{2}:[^>]+>" options:0 error:nil];
    if (vttTimeRegex) {
        [vttTimeRegex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    // Remove standard HTML/XML formatting tags: <i>, </i>, <b>, </b>, <u>, </u>, <font ...>, </font>, <span ...>, </span>, <v ...>, </v>, <c...>, </c>, <ruby>, </ruby>, <rt>, </rt>
    // Note: Does NOT strip arbitrary sound captions like <groans> or mathematical expressions like < $5!
    NSRegularExpression *htmlRegex = [NSRegularExpression regularExpressionWithPattern:@"</?(?:i|b|u|s|font|span|v|c|ruby|rt|lang|div|p)(?:\\s+[^>]*)?>|<!--.*?-->" options:NSRegularExpressionCaseInsensitive error:nil];
    if (htmlRegex) {
        [htmlRegex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    // ASS hard spaces and line breaks
    [result replaceOccurrencesOfString:@"\\h" withString:@" " options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\\N" withString:@"\n" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\\n" withString:@"\n" options:0 range:NSMakeRange(0, result.length)];

    // Named HTML entities
    [result replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&apos;" withString:@"'" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&nbsp;" withString:@" " options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&lsquo;" withString:@"‘" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&rsquo;" withString:@"’" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&ldquo;" withString:@"“" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&rdquo;" withString:@"”" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&mdash;" withString:@"—" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&ndash;" withString:@"–" options:0 range:NSMakeRange(0, result.length)];

    // Numeric HTML entities: &#39;, &#x27;, &#8217;, etc.
    NSRegularExpression *numEntity = [NSRegularExpression regularExpressionWithPattern:@"&#(x?[0-9a-fA-F]+);" options:0 error:nil];
    if (numEntity) {
        NSArray<NSTextCheckingResult *> *matches = [numEntity matchesInString:result options:0 range:NSMakeRange(0, result.length)];
        for (NSInteger m = matches.count - 1; m >= 0; m--) {
            NSRange r = matches[m].range;
            NSString *rawCode = [result substringWithRange:[matches[m] rangeAtIndex:1]];
            uint32_t charCode = 0;
            if ([rawCode hasPrefix:@"x"] || [rawCode hasPrefix:@"X"]) {
                NSScanner *scanner = [NSScanner scannerWithString:[rawCode substringFromIndex:1]];
                [scanner scanHexInt:&charCode];
            } else {
                charCode = (uint32_t)rawCode.integerValue;
            }
            if (charCode > 0 && charCode <= 0x10FFFF) {
                UTF32Char c = charCode;
                NSString *replacement = [[NSString alloc] initWithBytes:&c length:sizeof(c) encoding:NSUTF32LittleEndianStringEncoding];
                if (replacement.length) {
                    [result replaceCharactersInRange:r withString:replacement];
                }
            }
        }
    }

    // Normalize multiple blank lines and trim whitespace
    NSArray *rawLines = [result componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray *cleanLines = [NSMutableArray array];
    for (NSString *line in rawLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [cleanLines addObject:trimmed];
    }
    return [cleanLines componentsJoinedByString:@"\n"];
}

+ (NSArray<VPSubtitleCue *> *)parseTimedText:(NSString *)text {
    if (!text.length) return @[];
    NSMutableArray *cues = [NSMutableArray array];

    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray *lines = [normalized componentsSeparatedByString:@"\n"];

    NSRegularExpression *timingRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2}:\\d{2}:\\d{2}[,\\.]\\d{1,4}|\\d{1,2}:\\d{2}[,\\.]\\d{1,4})\\s*-->\\s*(\\d{1,2}:\\d{2}:\\d{2}[,\\.]\\d{1,4}|\\d{1,2}:\\d{2}[,\\.]\\d{1,4})" options:0 error:nil];

    __block VPSubtitleCue *currentCue = nil;
    NSMutableArray<NSString *> *currentLines = [NSMutableArray array];

    void (^saveCurrentCue)(void) = ^{
        if (currentCue && currentLines.count) {
            NSString *raw = [currentLines componentsJoinedByString:@"\n"];
            NSString *body = StripMarkup(raw);
            if (body.length) {
                currentCue.text = body;
                [cues addObject:currentCue];
            }
        }
        [currentLines removeAllObjects];
    };

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

        NSTextCheckingResult *match = [timingRegex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
        if (match && match.numberOfRanges >= 3) {
            // If the preceding line in currentLines was just the cue index number of this new cue, pop it
            if (currentLines.count && IsPureInteger([currentLines.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet])) {
                [currentLines removeLastObject];
            }
            saveCurrentCue();

            NSString *startStr = [trimmed substringWithRange:[match rangeAtIndex:1]];
            NSString *endStr = [trimmed substringWithRange:[match rangeAtIndex:2]];

            currentCue = [VPSubtitleCue new];
            currentCue.start = ParseTimestamp(startStr);
            currentCue.end = ParseTimestamp(endStr);
            continue;
        }

        if (!currentCue) continue;
        if (trimmed.length == 0) continue;
        [currentLines addObject:trimmed];
    }

    saveCurrentCue();
    return cues;
}

+ (NSArray<VPSubtitleCue *> *)parseASS:(NSString *)text {
    NSMutableArray *cues = [NSMutableArray array];
    NSArray<NSString *> *format = nil;
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    for (NSString *raw in [normalized componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"Format:"]) {
            NSString *list = [trimmed substringFromIndex:7];
            NSMutableArray *names = [NSMutableArray array];
            for (NSString *name in [list componentsSeparatedByString:@","]) {
                [names addObject:[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString];
            }
            if ([names containsObject:@"text"]) format = names;
        } else if ([trimmed hasPrefix:@"Dialogue:"] && format) {
            NSString *body = [[trimmed substringFromIndex:9] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSMutableArray *fields = [NSMutableArray array];
            NSString *rest = body;
            while (fields.count < format.count - 1) {   // the final field (Text) may itself contain commas
                NSRange comma = [rest rangeOfString:@","];
                if (comma.location == NSNotFound) break;
                [fields addObject:[rest substringToIndex:comma.location]];
                rest = [rest substringFromIndex:comma.location + 1];
            }
            [fields addObject:rest];
            NSUInteger startIndex = [format indexOfObject:@"start"], endIndex = [format indexOfObject:@"end"], textIndex = [format indexOfObject:@"text"];
            if (startIndex == NSNotFound || endIndex == NSNotFound || fields.count <= startIndex || fields.count <= endIndex) continue;
            NSString *cueTextRaw = (textIndex < fields.count) ? fields[textIndex] : fields.lastObject;
            VPSubtitleCue *cue = [VPSubtitleCue new];
            cue.start = ParseTimestamp(fields[startIndex]); cue.end = ParseTimestamp(fields[endIndex]);
            cue.text = StripMarkup(cueTextRaw);
            if (cue.text.length) [cues addObject:cue];
        }
    }
    return cues;
}

+ (nullable NSString *)loadSubtitleStringFromURL:(NSURL *)url error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data.length) return nil;

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;

    // 1. Check for Byte Order Marks (BOM)
    if (len >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(3, len - 3)] encoding:NSUTF8StringEncoding];
    }
    if (len >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, len - 2)] encoding:NSUTF16LittleEndianStringEncoding];
    }
    if (len >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, len - 2)] encoding:NSUTF16BigEndianStringEncoding];
    }

    // 2. Try UTF-8 (covers 99% of modern subtitles)
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (str.length) return str;

    // 3. Try Windows-1252 (CP1252: smart quotes, apostrophes, western accents)
    str = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
    if (str.length) return str;

    // 4. Try ISO-8859-1 (Latin-1)
    str = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (str.length) return str;

    // 5. Try macOS Roman
    str = [[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding];
    if (str.length) return str;

    // 6. Try UTF-16 without BOM
    str = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (str.length) return str;

    return nil;
}

+ (instancetype)trackWithContentsOfURL:(NSURL *)url error:(NSError **)error {
    NSString *text = [self loadSubtitleStringFromURL:url error:error];
    if (!text) return nil;
    NSString *ext = url.pathExtension.lowercaseString;
    BOOL ass = [@[@"ass", @"ssa"] containsObject:ext] || [text containsString:@"[Script Info]"];
    NSArray *cues = ass ? [self parseASS:text] : [self parseTimedText:text];
    cues = [cues sortedArrayUsingComparator:^NSComparisonResult(VPSubtitleCue *a, VPSubtitleCue *b) { return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame); }];
    if (!cues.count) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:92 userInfo:@{NSLocalizedDescriptionKey:@"No subtitle cues were found. Supported text formats are SRT, WebVTT and ASS/SSA."}];
        return nil;
    }
    VPSubtitleTrack *track = [VPSubtitleTrack new];
    track.cues = cues;
    return track;
}

+ (void)extractFromMedia:(NSURL *)media subtitleIndex:(NSInteger)index completion:(void (^)(VPSubtitleTrack *, NSError *))completion {
    if (!media) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil); });
        return;
    }

    VPSubtitleTrack *cached = [self cachedTrackForMedia:media subtitleIndex:index];
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *output = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSString stringWithFormat:@"vplay-sub-%@.srt", NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        VPSubtitleTrack *track = nil;
        if ([VPFFmpegLibrary extractSubtitles:media index:index output:output error:&error])
            track = [self trackWithContentsOfURL:output error:&error];
        [NSFileManager.defaultManager removeItemAtURL:output error:nil];
        if (track) {
            [SubtitleCache() setObject:track forKey:CacheKey(media, index)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(track, track ? nil : error);
        });
    });
}

#pragma mark - Lookup

- (NSString *)textAtTime:(double)seconds {
    if (!self.cues.count) return nil;
    NSInteger count = (NSInteger)self.cues.count;

    // Binary search for the last cue starting at or before `seconds`
    NSInteger low = 0, high = count - 1, found = -1;
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        if (self.cues[mid].start <= seconds) {
            found = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    if (found < 0) return nil;
    _lastIndex = found;

    // Collect all active cues that overlap this time window (handling simultaneous dialogue)
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    for (NSInteger i = found; i >= 0 && i > found - 8; i--) {
        VPSubtitleCue *cue = self.cues[i];
        if (cue.start <= seconds && cue.end >= seconds) {
            if (cue.text.length && ![active containsObject:cue.text]) {
                [active insertObject:cue.text atIndex:0];
            }
        }
    }
    return active.count ? [active componentsJoinedByString:@"\n"] : nil;
}

@end
