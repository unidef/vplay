#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPDiscKind) {
    VPDiscKindNone = 0,
    VPDiscKindDVD,
    VPDiscKindBluray,
    VPDiscKindVCD,
    VPDiscKindSVCD,
};

/// Recognises DVD, Blu-ray, VCD and SVCD discs (mounted volumes, folder copies and ISO/UDF images) and
/// turns them into something FFmpeg can read. Copy-protected (CSS/AACS) discs cannot be decoded without
/// third-party libraries; unprotected discs, home-made discs and ripped folders work.
@interface VPDiscSupport : NSObject
/// The kind of disc at `url`: a volume root, a VIDEO_TS / BDMV folder, or a folder containing one.
+ (VPDiscKind)kindForURL:(NSURL *)url;
+ (NSString *)nameForKind:(VPDiscKind)kind;
/// Disc images (.iso, .img, .toast, .cdr, .dmg, .udf) need mounting first.
+ (BOOL)isDiscImage:(NSURL *)url;
/// Currently mounted disc volumes in /Volumes.
+ (NSArray<NSURL *> *)mountedDiscs;
/// Finds an already mounted volume for a disc image URL, if any.
+ (nullable NSURL *)mountedVolumeForImageURL:(NSURL *)url;
/// Mounts an image read-only and returns its volume URL.
+ (void)mountImageAtURL:(NSURL *)url completion:(void (^)(NSURL * _Nullable volume, NSError * _Nullable error))completion;
/// Playable entries for a disc: one main title for DVD / Blu-ray, one entry per track for VCD / SVCD.
/// Each URL is a single media file or an .ffconcat list that FFmpeg plays as one program.
+ (nullable NSArray<NSURL *> *)playableURLsForDisc:(NSURL *)url error:(NSError **)error;
/// A display title such as "DVD — MY_MOVIE".
+ (NSString *)titleForDisc:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
