#import <Foundation/Foundation.h>
#import "VPFFmpegLibrary.h"

static void Check(BOOL pass, NSString *message) {
    if (!pass) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
    printf("PASS: %s\n", message.UTF8String);
}
static NSDictionary *Probe(NSURL *url) {
    NSError *error = nil;
    NSDictionary *probe = [VPFFmpegLibrary probeURL:url error:&error];
    Check(probe != nil, [NSString stringWithFormat:@"probe %@: %@", url.lastPathComponent, error ?: @"OK"]);
    return probe;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSURL *input = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *directory = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        NSDictionary *original = Probe(input);
        Check([original[@"streams"] count] == 3, @"video/audio/subtitle discovery");
        Check(fabs([original[@"format"][@"duration"] doubleValue] - 10) < 0.1, @"source duration");
        NSError *error = nil;
        NSURL *subtitles = [directory URLByAppendingPathComponent:@"captions.srt"];
        Check([VPFFmpegLibrary extractSubtitles:input index:0 output:subtitles error:&error], [NSString stringWithFormat:@"subtitle extraction: %@", error ?: @"OK"]);
        NSString *text = [NSString stringWithContentsOfURL:subtitles encoding:NSUTF8StringEncoding error:nil];
        Check([text containsString:@"Bundled FFmpeg subtitle test"] && [text containsString:@"Second caption"], @"subtitle text preserved");
        NSURL *movie = [directory URLByAppendingPathComponent:@"converted.mov"];
        BOOL converted = [[VPFFmpegJob new] runInput:input output:movie options:@{
            @"videoFilter":@"scale=80:60", @"audioFilter":@"volume=0.5", @"startOffset":@2, @"duration":@3,
            @"overwrite":@YES} error:&error];
        Check(converted, [NSString stringWithFormat:@"filtered, trimmed A/V conversion: %@", error ?: @"OK"]);
        NSDictionary *probe = Probe(movie);
        Check(fabs([probe[@"format"][@"duration"] doubleValue]-3) < 0.12, @"trimmed output duration");
        NSDictionary *video = probe[@"streams"][0];
        Check([video[@"width"] intValue] == 80 && [video[@"height"] intValue] == 60, @"scaling filter output dimensions");
        Check([probe[@"streams"] count] == 2, @"converted video and audio both present");
        error = nil;
        Check(![[VPFFmpegJob new] runInput:input output:movie options:@{} error:&error] && error != nil, @"existing output protected");
        VPFFmpegJob *cancelled = [VPFFmpegJob new]; [cancelled cancel];
        error = nil;
        Check(![cancelled runInput:input output:[directory URLByAppendingPathComponent:@"cancelled.mov"] options:@{} error:&error] && !cancelled.running, @"cancelled job does not run");
        NSURL *audio = [directory URLByAppendingPathComponent:@"audio.wav"];
        error = nil;
        Check([[VPFFmpegJob new] runInput:input output:audio options:@{@"audioOnly":@YES,@"audioCodec":@"pcm_s16le",@"audioFilter":@"aresample=44100",@"overwrite":@YES} error:&error], [NSString stringWithFormat:@"audio-only conversion: %@", error ?: @"OK"]);
        probe = Probe(audio);
        Check([probe[@"streams"] count] == 1 && [probe[@"streams"][0][@"sample_rate"] intValue] == 44100, @"audio resampling");
        NSURL *demo = [directory URLByAppendingPathComponent:@"demo.wav"];
        error = nil;
        Check([VPFFmpegLibrary renderAudioDemoWithGraph:@"highpass=f=100" output:demo error:&error], [NSString stringWithFormat:@"audio filter demo: %@", error ?: @"OK"]);
        probe = Probe(demo);
        Check(fabs([probe[@"format"][@"duration"] doubleValue]-8) < 0.1, @"audio demo duration");
        NSURL *parsedInput = nil, *parsedOutput = nil; NSDictionary *options = nil;
        Check(![VPFFmpegLibrary parseArguments:@[@"-filter_complex",@"unsupported"] input:&parsedInput output:&parsedOutput options:&options error:&error], @"unsupported CLI options rejected");
        Check([VPFFmpegLibrary parseArguments:@[@"-i",input.path,@"-ss",@"2",@"-t",@"3",@"-y",movie.path] input:&parsedInput output:&parsedOutput options:&options error:&error] && [options[@"startOffset"] doubleValue] == 2, @"supported CLI options parsed");
        // Invalid filters must fail without aborting or poisoning a later independent job.
        error = nil;
        Check(![[VPFFmpegJob new] runInput:input output:[directory URLByAppendingPathComponent:@"invalid.mov"] options:@{@"videoFilter":@"not_a_real_filter",@"overwrite":@YES} error:&error] && error != nil, @"invalid filter returns an error");
        error = nil;
        NSURL *playlist = [directory URLByAppendingPathComponent:@"stream.m3u8"];
        BOOL hls = [[VPFFmpegJob new] runInput:input output:playlist options:@{@"format":@"hls",@"overwrite":@YES} error:&error];
        if (!hls && [error.userInfo[@"hardwareEncoderUnavailable"] boolValue]) {
            printf("SKIP: VideoToolbox session unavailable on this host; testing HLS muxing with MPEG-2.\n");
            error = nil;
            hls = [[VPFFmpegJob new] runInput:input output:playlist options:@{@"format":@"hls",@"videoCodec":@"mpeg2video",@"overwrite":@YES} error:&error];
        }
        Check(hls, [NSString stringWithFormat:@"HLS conversion: %@", error ?: @"OK"]);
        NSString *manifest = [NSString stringWithContentsOfURL:playlist encoding:NSUTF8StringEncoding error:nil];
        Check([manifest containsString:@"#EXT-X-ENDLIST"] && [manifest componentsSeparatedByString:@"#EXTINF"].count >= 3, @"HLS segments and finalized playlist");
        NSLog(@"All library integration checks passed.");
    }
    return 0;
}
