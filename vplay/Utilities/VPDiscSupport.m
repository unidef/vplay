#import "VPDiscSupport.h"

static NSURL *DiscRoot(NSURL *url) {
    // Accept the VIDEO_TS / BDMV folder itself as well as its parent.
    NSString *name = url.lastPathComponent.uppercaseString;
    if ([name isEqual:@"VIDEO_TS"] || [name isEqual:@"BDMV"] || [name isEqual:@"AUDIO_TS"]) return url.URLByDeletingLastPathComponent;
    return url;
}

static NSURL *Child(NSURL *root, NSString *name) {
    // File systems on discs are case-insensitive in practice but UDF on some systems exposes upper-case names.
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:nil];
    for (NSString *candidate in names) if ([candidate.uppercaseString isEqual:name.uppercaseString]) return [root URLByAppendingPathComponent:candidate isDirectory:YES];
    return nil;
}

@implementation VPDiscSupport

+ (BOOL)isDiscImage:(NSURL *)url {
    return [@[@"iso", @"img", @"toast", @"cdr", @"dmg", @"udf"] containsObject:url.pathExtension.lowercaseString] && ![self isDirectory:url];
}

+ (BOOL)isDirectory:(NSURL *)url {
    BOOL directory = NO;
    return url.isFileURL && [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory] && directory;
}

+ (VPDiscKind)kindForURL:(NSURL *)url {
    if (!url.isFileURL || ![self isDirectory:url]) return VPDiscKindNone;
    NSURL *root = DiscRoot(url);
    if (Child(root, @"VIDEO_TS")) return VPDiscKindDVD;
    if (Child(root, @"BDMV")) return VPDiscKindBluray;
    if (Child(root, @"SVCD") || Child(root, @"MPEG2")) return VPDiscKindSVCD;
    if (Child(root, @"VCD") || Child(root, @"MPEGAV")) return VPDiscKindVCD;
    return VPDiscKindNone;
}

+ (NSString *)nameForKind:(VPDiscKind)kind {
    switch (kind) {
        case VPDiscKindDVD: return @"DVD";
        case VPDiscKindBluray: return @"Blu-ray";
        case VPDiscKindVCD: return @"VCD";
        case VPDiscKindSVCD: return @"SVCD";
        default: return @"Disc";
    }
}

+ (NSString *)titleForDisc:(NSURL *)url {
    NSURL *root = DiscRoot(url);
    return [NSString stringWithFormat:@"%@ — %@", [self nameForKind:[self kindForURL:url]], root.lastPathComponent];
}

+ (NSArray<NSURL *> *)mountedDiscs {
    NSMutableArray *discs = [NSMutableArray array];
    for (NSURL *volume in [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:@"/Volumes"] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([self kindForURL:volume] != VPDiscKindNone) [discs addObject:volume];
    }
    return discs;
}

+ (nullable NSURL *)mountedVolumeForImageURL:(NSURL *)url {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
    task.arguments = @[@"info", @"-plist"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if ([task launchAndReturnError:nil]) {
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSDictionary *plist = data.length ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
        if ([plist isKindOfClass:NSDictionary.class]) {
            NSString *targetPath = url.standardizedURL.path;
            for (NSDictionary *img in plist[@"images"]) {
                NSString *imgPath = img[@"image-path"];
                if (imgPath.length) {
                    NSString *stdImg = [NSURL fileURLWithPath:imgPath].standardizedURL.path;
                    if ([stdImg isEqualToString:targetPath] || [imgPath isEqualToString:targetPath]) {
                        for (NSDictionary *entity in img[@"system-entities"]) {
                            NSString *mp = entity[@"mount-point"];
                            if (mp.length) return [NSURL fileURLWithPath:mp isDirectory:YES];
                        }
                    }
                }
            }
        }
    }
    NSString *base = url.URLByDeletingPathExtension.lastPathComponent;
    NSURL *directVol = [NSURL fileURLWithPath:[@"/Volumes" stringByAppendingPathComponent:base] isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:directVol.path]) return directVol;
    return nil;
}

+ (void)mountImageAtURL:(NSURL *)url completion:(void (^)(NSURL *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *existing = [self mountedVolumeForImageURL:url];
        if (existing) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(existing, nil); });
            return;
        }

        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
        task.arguments = @[@"attach", @"-nobrowse", @"-readonly", @"-noverify", @"-noautofsck", @"-plist", url.path];
        NSPipe *out = [NSPipe pipe];
        task.standardOutput = out; task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *error = nil; NSURL *volume = nil;
        if ([task launchAndReturnError:&error]) {
            NSData *data = [out.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            NSDictionary *plist = data.length ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
            if ([plist isKindOfClass:NSDictionary.class]) {
                for (NSDictionary *entity in plist[@"system-entities"]) {
                    if ([entity[@"mount-point"] length]) {
                        NSURL *cand = [NSURL fileURLWithPath:entity[@"mount-point"] isDirectory:YES];
                        if ([self kindForURL:cand] != VPDiscKindNone || !volume) {
                            volume = cand;
                        }
                    }
                }
            }
            if (!volume) volume = [self mountedVolumeForImageURL:url];
            if (!volume) {
                NSString *desc = [NSString stringWithFormat:@"The disc image \"%@\" could not be mounted.", url.lastPathComponent];
                error = [NSError errorWithDomain:@"VPlayErrorDomain" code:90 userInfo:@{NSLocalizedDescriptionKey:desc}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(volume, volume ? nil : error); });
    });
}

#pragma mark - Playlists

+ (NSArray<NSURL *> *)playableURLsForDisc:(NSURL *)url error:(NSError **)error {
    VPDiscKind kind = [self kindForURL:url];
    NSURL *root = DiscRoot(url);
    NSArray<NSURL *> *result = nil;
    switch (kind) {
        case VPDiscKindDVD: result = [self dvdURLs:root]; break;
        case VPDiscKindBluray: result = [self blurayURLs:root]; break;
        case VPDiscKindVCD: result = [self trackURLs:Child(root, @"MPEGAV") extension:@"DAT"]; break;
        case VPDiscKindSVCD: result = [self trackURLs:Child(root, @"MPEG2") extension:@"MPG"]; break;
        default: break;
    }
    if (!result.count && error) {
        *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:91 userInfo:@{NSLocalizedDescriptionKey:
            kind == VPDiscKindNone ? @"No DVD, Blu-ray, VCD or SVCD structure was found here."
                                   : [NSString stringWithFormat:@"No playable %@ video was found. Copy-protected discs cannot be read without decryption libraries.", [self nameForKind:kind]]}];
    }
    return result;
}

+ (NSArray<NSURL *> *)filesIn:(NSURL *)directory extensions:(NSArray *)extensions {
    NSMutableArray *files = [NSMutableArray array];
    for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([extensions containsObject:file.pathExtension.uppercaseString]) [files addObject:file];
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch | NSCaseInsensitiveSearch]; }];
    return files;
}

+ (unsigned long long)sizeOf:(NSURL *)file {
    NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    return size.unsignedLongLongValue;
}

+ (NSURL *)concatListForFiles:(NSArray<NSURL *> *)files name:(NSString *)name {
    NSMutableString *list = [NSMutableString stringWithString:@"ffconcat version 1.0\n"];
    for (NSURL *file in files) [list appendFormat:@"file '%@'\n", [file.path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    NSString *safe = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"_"];
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:@"vplay-discs" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [dir URLByAppendingPathComponent:[safe stringByAppendingString:@".ffconcat"]];
    return [list writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil] ? file : nil;
}

/// DVD: VTS_nn_k.VOB files belong to title set nn. The set with the most data is the main feature.
+ (NSArray<NSURL *> *)dvdURLs:(NSURL *)root {
    NSURL *videoTS = Child(root, @"VIDEO_TS");
    NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *sets = [NSMutableDictionary dictionary];
    for (NSURL *file in [self filesIn:videoTS extensions:@[@"VOB"]]) {
        NSString *name = file.lastPathComponent.uppercaseString;
        if (![name hasPrefix:@"VTS_"] || name.length < 12) continue;
        NSString *set = [name substringWithRange:NSMakeRange(4, 2)];
        if ([[name substringWithRange:NSMakeRange(7, 1)] isEqual:@"0"]) continue;   // VTS_nn_0.VOB is the menu
        if (!sets[set]) sets[set] = [NSMutableArray array];
        [sets[set] addObject:file];
    }
    NSString *best = nil; unsigned long long bestSize = 0;
    for (NSString *set in sets) {
        unsigned long long total = 0;
        for (NSURL *file in sets[set]) total += [self sizeOf:file];
        if (total > bestSize) { bestSize = total; best = set; }
    }
    if (!best) return nil;
    NSURL *list = [self concatListForFiles:sets[best] name:[root.lastPathComponent stringByAppendingString:@"-dvd"]];
    return list ? @[list] : nil;
}

/// Blu-ray: the main feature is, in practice, the largest M2TS stream.
+ (NSArray<NSURL *> *)blurayURLs:(NSURL *)root {
    NSURL *stream = Child(Child(root, @"BDMV"), @"STREAM");
    NSURL *best = nil; unsigned long long bestSize = 0;
    for (NSURL *file in [self filesIn:stream extensions:@[@"M2TS", @"MTS"]]) {
        unsigned long long size = [self sizeOf:file];
        if (size > bestSize) { bestSize = size; best = file; }
    }
    return best ? @[best] : nil;
}

+ (NSArray<NSURL *> *)trackURLs:(NSURL *)directory extension:(NSString *)extension {
    if (!directory) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSURL *file in [self filesIn:directory extensions:@[extension, @"MPG", @"MPEG"]]) {
        if ([self sizeOf:file] > 0) [tracks addObject:file];
    }
    return tracks;
}
@end
