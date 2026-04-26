#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const VPPlaylistDidChangeNotification;

typedef NS_ENUM(NSInteger, VPRepeatMode) { VPRepeatOff, VPRepeatAll, VPRepeatOne };

@interface VPPlaylistItem : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *title;
@end

/// The play queue. Shared by the window, the playlist panel and the command line.
/// Shuffle plays every item once in random order (starting with the current one) before reshuffling.
@interface VPPlaylist : NSObject
@property (nonatomic, readonly) NSArray<VPPlaylistItem *> *items;
@property (nonatomic) NSInteger currentIndex;            // -1 when nothing is selected
@property (nonatomic) BOOL shuffle;
@property (nonatomic) VPRepeatMode repeatMode;
@property (nonatomic, readonly, nullable) VPPlaylistItem *currentItem;

/// Expands files, folders, .m3u/.m3u8/.pls playlists and disc folders into items. Returns the number added.
- (NSUInteger)addInputs:(NSArray<NSURL *> *)urls;
- (void)removeItemsAtIndexes:(NSIndexSet *)indexes;
- (void)moveItemFromIndex:(NSInteger)from toIndex:(NSInteger)to;
- (void)clear;

/// Selects and returns the next / previous item according to shuffle and repeat, or nil at the end of the queue.
- (nullable VPPlaylistItem *)advanceAutomatically:(BOOL)automatic;
- (nullable VPPlaylistItem *)retreat;
- (nullable VPPlaylistItem *)selectIndex:(NSInteger)index;

- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error;
- (BOOL)loadPlaylistFromURL:(NSURL *)url clearExisting:(BOOL)clearExisting error:(NSError **)error;

/// Turns command-line arguments (paths or URLs) into URLs.
+ (NSArray<NSURL *> *)URLsFromArguments:(NSArray<NSString *> *)arguments;
+ (BOOL)isPlaylistFile:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
