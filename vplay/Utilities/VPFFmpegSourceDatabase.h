//
//  VPFFmpegSourceDatabase.h
//  vplay
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPFFmpegStreamType) {
    VPFFmpegStreamTypeUnknown = 0,
    VPFFmpegStreamTypeVideo,
    VPFFmpegStreamTypeAudio,
    VPFFmpegStreamTypeSubtitle,
    VPFFmpegStreamTypeAttachment,
    VPFFmpegStreamTypeData
};

/// Detailed metadata for an individual stream inside an FFmpeg media source.
@interface VPFFmpegStreamInfo : NSObject

@property (nonatomic, assign) int streamIndex;
@property (nonatomic, assign) VPFFmpegStreamType streamType;
@property (nonatomic, assign) int codecID;
@property (nonatomic, copy) NSString *codecName;
@property (nonatomic, copy) NSString *codecLongName;
@property (nonatomic, copy) NSString *profile;
@property (nonatomic, assign) int64_t bitRate;
@property (nonatomic, assign) double timeBaseSeconds;
@property (nonatomic, assign) double duration;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) BOOL isDefault;
@property (nonatomic, assign) BOOL isForced;

// Video specific properties
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) double frameRate;
@property (nonatomic, copy) NSString *pixelFormatName;
@property (nonatomic, assign) BOOL isInterlaced;
@property (nonatomic, copy) NSString *fieldOrder;
@property (nonatomic, assign) double aspectRatio;
@property (nonatomic, assign) BOOL isAttachedPic;

// Audio specific properties
@property (nonatomic, assign) int sampleRate;
@property (nonatomic, assign) int channels;
@property (nonatomic, copy) NSString *channelLayout;
@property (nonatomic, copy) NSString *sampleFormatName;

// Subtitle specific properties
@property (nonatomic, assign) BOOL isBitmapSubtitle;

@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *metadata;

@end

/// Chapter metadata from the media container.
@interface VPFFmpegChapterInfo : NSObject

@property (nonatomic, assign) int64_t chapterID;
@property (nonatomic, assign) double startTime;
@property (nonatomic, assign) double endTime;
@property (nonatomic, copy) NSString *title;

@end

/// Keyframe seek point (Cue) for instant and precise scrubbing.
@interface VPFFmpegSeekCue : NSObject

@property (nonatomic, assign) double pts;
@property (nonatomic, assign) int64_t pos;
@property (nonatomic, assign) BOOL keyframe;

@end

/// A comprehensive source descriptor and database record for an FFmpeg media file.
@interface VPFFmpegSourceInfo : NSObject

@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *formatName;
@property (nonatomic, copy) NSString *formatLongName;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double startTime;
@property (nonatomic, assign) int64_t bitRate;
@property (nonatomic, assign) int64_t fileSize;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *metadata;

@property (nonatomic, copy) NSArray<VPFFmpegStreamInfo *> *videoStreams;
@property (nonatomic, copy) NSArray<VPFFmpegStreamInfo *> *audioStreams;
@property (nonatomic, copy) NSArray<VPFFmpegStreamInfo *> *subtitleStreams;
@property (nonatomic, copy) NSArray<VPFFmpegChapterInfo *> *chapters;
@property (nonatomic, copy) NSArray<VPFFmpegSeekCue *> *seekCues;

@property (nonatomic, assign) int defaultVideoStreamIndex;
@property (nonatomic, assign) int defaultAudioStreamIndex;
@property (nonatomic, assign) int defaultSubtitleStreamIndex;

- (nullable VPFFmpegStreamInfo *)streamWithIndex:(int)index;
- (nullable VPFFmpegStreamInfo *)primaryVideoStream;
- (nullable VPFFmpegStreamInfo *)primaryAudioStream;

/// Finds the closest keyframe PTS before or equal to targetPTS.
- (double)closestKeyframePTSBefore:(double)targetPTS;
/// Finds the closest keyframe PTS after targetPTS.
- (double)closestKeyframePTSAfter:(double)targetPTS;

@end

/// Thread-safe central database and registry for all FFmpeg media sources.
@interface VPFFmpegSourceDatabase : NSObject

+ (instancetype)sharedDatabase;

/// Retrieves cached source descriptor if already indexed.
- (nullable VPFFmpegSourceInfo *)sourceInfoForURL:(NSURL *)url;

/// Probes and indexes the media source synchronously, storing it in the database.
- (nullable VPFFmpegSourceInfo *)indexSourceAtURL:(NSURL *)url error:(NSError **)error;

/// Probes and indexes the media source asynchronously.
- (void)indexSourceAtURL:(NSURL *)url completion:(void (^)(VPFFmpegSourceInfo * _Nullable info, NSError * _Nullable error))completion;

/// Manually registers an already constructed source info.
- (void)registerSourceInfo:(VPFFmpegSourceInfo *)info forURL:(NSURL *)url;

/// Removes an entry from the database.
- (void)removeSourceForURL:(NSURL *)url;

/// Clears all entries in the database.
- (void)clearDatabase;

@end

NS_ASSUME_NONNULL_END
