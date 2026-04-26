#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPTrackKind) { VPTrackKindVideo, VPTrackKindAudio, VPTrackKindSubtitle };

/// One stream inside a media file, as reported by the bundled FFmpeg libraries.
@interface VPTrack : NSObject
@property (nonatomic) VPTrackKind kind;
@property (nonatomic) NSInteger index;          // position within its kind (0-based): ffmpeg's 0:v:N / 0:a:N / 0:s:N
@property (nonatomic) NSInteger streamIndex;    // absolute stream number in the container
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *language;
@property (nonatomic, copy, nullable) NSString *codec;
@property (nonatomic, copy, nullable) NSString *detail;   // "1920×1080 · 23.98 fps" or "5.1 · 48 kHz"
@property (nonatomic) NSInteger channels;          // audio channel count
@property (nonatomic) BOOL bitmap;               // image-based subtitles (DVD/Blu-ray) cannot be converted to text
@property (nonatomic) BOOL isDefault;
@property (nonatomic) BOOL interlaced;
@property (nonatomic, copy, nullable) NSString *fieldOrder;
- (NSString *)displayName;
@end

/// Everything vplay shows in the metadata overlay and the track menus.
@interface VPMediaProbe : NSObject
@property (nonatomic, copy) NSString *formatName;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *tags;   // lowercased keys: title, artist, album, ...
@property (nonatomic) double duration;
@property (nonatomic) long long bitRate;
@property (nonatomic) long long sizeBytes;
@property (nonatomic, copy) NSArray<VPTrack *> *videoTracks;
@property (nonatomic, copy) NSArray<VPTrack *> *audioTracks;
@property (nonatomic, copy) NSArray<VPTrack *> *subtitleTracks;
@property (nonatomic, readonly) BOOL hasVideo;
@property (nonatomic) double frameRate;
@property (nonatomic) NSSize videoSize;
@property (nonatomic) BOOL isInterlaced;
@property (nonatomic, copy, nullable) NSString *detectedFieldOrder;

/// Inspects media off the main thread. Completes on the main queue; nil indicates unreadable media.
+ (void)probeURL:(NSURL *)url completion:(void (^)(VPMediaProbe * _Nullable probe))completion;
/// Blocking variant for command-line tools. Returns nil when the media cannot be inspected.
+ (nullable VPMediaProbe *)probeSynchronously:(NSURL *)url;
/// Human-readable lines for the fading metadata overlay.
- (NSArray<NSString *> *)overlayLinesForURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
