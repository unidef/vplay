#import "VPPlaylist.h"
#import "VPURLHelper.h"
#import "VPDiscSupport.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSNotificationName const VPPlaylistDidChangeNotification = @"VPPlaylistDidChangeNotification";

@implementation VPPlaylistItem
@end

@interface VPPlaylist ()
@property (nonatomic, strong) NSMutableArray<VPPlaylistItem *> *mutableItems;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *order;   // shuffle permutation of item indexes
@property (nonatomic) NSInteger orderPosition;
@end

@implementation VPPlaylist

- (instancetype)init {
    if ((self = [super init])) { _mutableItems = [NSMutableArray array]; _currentIndex = -1; _order = [NSMutableArray array]; }
    return self;
}
- (NSArray<VPPlaylistItem *> *)items { return self.mutableItems; }
- (VPPlaylistItem *)currentItem {
    return self.currentIndex >= 0 && self.currentIndex < (NSInteger)self.mutableItems.count ? self.mutableItems[self.currentIndex] : nil;
}
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:VPPlaylistDidChangeNotification object:self]; }

#pragma mark - Editing

- (NSUInteger)addInputs:(NSArray<NSURL *> *)urls {
    NSUInteger before = self.mutableItems.count;
    for (NSURL *url in urls) [self expand:url depth:0];
    [self rebuildOrder];
    [self changed];
    return self.mutableItems.count - before;
}

- (void)appendURL:(NSURL *)url title:(NSString *)title {
    VPPlaylistItem *item = [VPPlaylistItem new];
    item.url = url;
    item.title = title ?: (url.isFileURL ? url.lastPathComponent : url.absoluteString);
    [self.mutableItems addObject:item];
}

- (void)expand:(NSURL *)url depth:(int)depth {
    if (!url.isFileURL) { [self appendURL:url title:nil]; return; }
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory]) { [self appendURL:url title:nil]; return; }
    if (directory) {
        VPDiscKind kind = [VPDiscSupport kindForURL:url];
        if (kind != VPDiscKindNone) {
            NSArray *tracks = [VPDiscSupport playableURLsForDisc:url error:nil];
            for (NSUInteger i = 0; i < tracks.count; i++) {
                NSString *title = tracks.count == 1 ? [VPDiscSupport titleForDisc:url]
                    : [NSString stringWithFormat:@"%@ — track %lu", [VPDiscSupport titleForDisc:url], (unsigned long)i + 1];
                [self appendURL:tracks[i] title:title];
            }
            return;
        }
        if (depth > 6) return;
        NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        children = [children sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch | NSCaseInsensitiveSearch];
        }];
        for (NSURL *child in children) {
            BOOL childDirectory = NO;
            [NSFileManager.defaultManager fileExistsAtPath:child.path isDirectory:&childDirectory];
            if (childDirectory || [VPPlaylist looksPlayable:child]) [self expand:child depth:depth + 1];
        }
        return;
    }
    if ([VPPlaylist isPlaylistFile:url] && depth < 4) {
        for (NSURL *entry in [VPPlaylist entriesOfPlaylistFile:url]) [self expand:entry depth:depth + 1];
        return;
    }
    [self appendURL:url title:nil];
}

/// A file inside a folder is queued if its type is audio/video or its extension is a known media extension.
+ (BOOL)looksPlayable:(NSURL *)url {
    if ([VPURLHelper isSupportedMediaPath:url.path]) return YES;
    UTType *type = [UTType typeWithFilenameExtension:url.pathExtension];
    return type && ([type conformsToType:UTTypeAudiovisualContent] || [type conformsToType:UTTypeAudio] || [type conformsToType:UTTypeMovie] || [self isPlaylistFile:url]);
}

- (void)removeItemsAtIndexes:(NSIndexSet *)indexes {
    VPPlaylistItem *current = self.currentItem;
    [self.mutableItems removeObjectsAtIndexes:indexes];
    self.currentIndex = current ? (NSInteger)[self.mutableItems indexOfObjectIdenticalTo:current] : -1;
    [self rebuildOrder]; [self changed];
}

- (void)moveItemFromIndex:(NSInteger)from toIndex:(NSInteger)to {
    if (from == to || from < 0 || from >= (NSInteger)self.mutableItems.count) return;
    to = MAX(0, MIN(to, (NSInteger)self.mutableItems.count - 1));
    VPPlaylistItem *current = self.currentItem, *item = self.mutableItems[from];
    [self.mutableItems removeObjectAtIndex:from];
    [self.mutableItems insertObject:item atIndex:to];
    self.currentIndex = current ? (NSInteger)[self.mutableItems indexOfObjectIdenticalTo:current] : -1;
    [self rebuildOrder]; [self changed];
}

- (void)clear {
    [self.mutableItems removeAllObjects]; self.currentIndex = -1; [self rebuildOrder]; [self changed];
}

#pragma mark - Navigation

- (void)setShuffle:(BOOL)shuffle { _shuffle = shuffle; [self rebuildOrder]; [self changed]; }
- (void)setRepeatMode:(VPRepeatMode)mode { _repeatMode = mode; [self changed]; }

/// Builds the play order. With shuffle on, the current item comes first so toggling never jumps tracks.
- (void)rebuildOrder {
    NSMutableArray *indexes = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.mutableItems.count; i++) [indexes addObject:@(i)];
    if (self.shuffle) {
        for (NSInteger i = (NSInteger)indexes.count - 1; i > 0; i--) [indexes exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)i + 1)];
        NSUInteger at = self.currentIndex >= 0 ? [indexes indexOfObject:@(self.currentIndex)] : NSNotFound;
        if (at != NSNotFound && at != 0) [indexes exchangeObjectAtIndex:0 withObjectAtIndex:at];
    }
    self.order = indexes;
    self.orderPosition = self.currentIndex >= 0 ? (NSInteger)[indexes indexOfObject:@(self.currentIndex)] : -1;
    if (self.orderPosition == (NSInteger)NSNotFound) self.orderPosition = -1;
}

- (VPPlaylistItem *)selectIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.mutableItems.count) return nil;
    self.currentIndex = index;
    NSUInteger position = [self.order indexOfObject:@(index)];
    self.orderPosition = position == NSNotFound ? -1 : (NSInteger)position;
    [self changed];
    return self.mutableItems[index];
}

- (VPPlaylistItem *)advanceAutomatically:(BOOL)automatic {
    if (!self.mutableItems.count) return nil;
    if (automatic && self.repeatMode == VPRepeatOne && self.currentItem) return self.currentItem;
    NSInteger next = self.orderPosition + 1;
    if (next >= (NSInteger)self.order.count) {
        if (self.repeatMode == VPRepeatOff && automatic) return nil;
        if (self.shuffle) { self.currentIndex = -1; [self rebuildOrder]; }   // fresh random pass
        next = 0;
    }
    return [self selectIndex:[self.order[next] integerValue]];
}

- (VPPlaylistItem *)retreat {
    if (!self.mutableItems.count) return nil;
    NSInteger previous = self.orderPosition - 1;
    if (previous < 0) previous = (NSInteger)self.order.count - 1;
    return [self selectIndex:[self.order[previous] integerValue]];
}

#pragma mark - Files

+ (BOOL)isPlaylistFile:(NSURL *)url {
    if (!url.isFileURL) return NO;
    NSString *ext = url.pathExtension.lowercaseString;
    if ([@[@"m3u", @"pls"] containsObject:ext]) return YES;
    if ([ext isEqual:@"m3u8"]) {
        // HLS manifests also use .m3u8; a real playlist has no #EXT-X- directives.
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        return text && ![text containsString:@"#EXT-X-"];
    }
    return NO;
}

+ (NSArray<NSURL *> *)entriesOfPlaylistFile:(NSURL *)file {
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil]
        ?: [NSString stringWithContentsOfURL:file encoding:NSISOLatin1StringEncoding error:nil];
    NSMutableArray *urls = [NSMutableArray array];
    BOOL pls = [file.pathExtension.lowercaseString isEqual:@"pls"];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (pls) {
            if (![line.lowercaseString hasPrefix:@"file"]) continue;
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            line = [line substringFromIndex:eq.location + 1];
        }
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSURL *url;
        if ([line containsString:@"://"]) url = [NSURL URLWithString:line];
        else if ([line hasPrefix:@"/"] || [line hasPrefix:@"~"]) url = [NSURL fileURLWithPath:line.stringByExpandingTildeInPath];
        else url = [NSURL fileURLWithPath:line relativeToURL:file.URLByDeletingLastPathComponent].absoluteURL;
        if (url) [urls addObject:url];
    }
    return urls;
}

- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error {
    NSMutableString *text = [NSMutableString stringWithString:@"#EXTM3U\n"];
    for (VPPlaylistItem *item in self.mutableItems) {
        [text appendFormat:@"#EXTINF:-1,%@\n%@\n", item.title, item.url.isFileURL ? item.url.path : item.url.absoluteString];
    }
    return [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (BOOL)loadPlaylistFromURL:(NSURL *)url clearExisting:(BOOL)clearExisting error:(NSError **)error {
    if (!url) return NO;
    NSArray<NSURL *> *entries = [self.class entriesOfPlaylistFile:url];
    if (!entries.count) {
        // Fallback: try parsing generic lines
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil]
            ?: [NSString stringWithContentsOfURL:url encoding:NSISOLatin1StringEncoding error:nil];
        if (!text) {
            if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Could not read playlist file."}];
            return NO;
        }
        NSMutableArray *urls = [NSMutableArray array];
        for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!line.length || [line hasPrefix:@"#"]) continue;
            NSURL *entryURL;
            if ([line containsString:@"://"]) entryURL = [NSURL URLWithString:line];
            else if ([line hasPrefix:@"/"] || [line hasPrefix:@"~"]) entryURL = [NSURL fileURLWithPath:line.stringByExpandingTildeInPath];
            else if (url.isFileURL) entryURL = [NSURL fileURLWithPath:line relativeToURL:url.URLByDeletingLastPathComponent].absoluteURL;
            else entryURL = [VPURLHelper urlFromString:line];
            if (entryURL) [urls addObject:entryURL];
        }
        entries = urls;
    }
    if (!entries.count) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:404 userInfo:@{NSLocalizedDescriptionKey:@"No valid playlist items found in file."}];
        return NO;
    }
    if (clearExisting) {
        [self clear];
    }
    [self addInputs:entries];
    return YES;
}

+ (NSArray<NSURL *> *)URLsFromArguments:(NSArray<NSString *> *)arguments {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *argument in arguments) {
        NSURL *url = [VPURLHelper urlFromString:argument];
        if (url) [urls addObject:url];
    }
    return urls;
}
@end
