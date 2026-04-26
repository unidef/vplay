#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const VPAudioFiltersDidChangeNotification;

/// One filter in the library, for example "Bass boost" with an amount slider in decibels.
@interface VPAudioFilterTemplate : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *details;
@property (nonatomic, copy) NSString *format;           // FFmpeg filter text; contains %f-style placeholder when it has an amount
@property (nonatomic, copy, nullable) NSString *amountName;   // nil when the filter has no amount
@property (nonatomic) double minimum, maximum, defaultAmount;
@property (nonatomic, copy) NSString *unit;
@property (nonatomic, copy) NSString *optionsSummary;
@end

/// The user's audio filter chain. Stages are plain dictionaries so they save as JSON:
/// {"id": "bass", "amount": 8} for library filters, {"custom": "aecho=0.8:0.9:500:0.3"} for hand-written ones.
@interface VPAudioFilters : NSObject
+ (instancetype)shared;
+ (NSArray<VPAudioFilterTemplate *> *)library;
+ (NSArray<NSString *> *)categories;
+ (nullable VPAudioFilterTemplate *)templateWithIdentifier:(NSString *)identifier;

@property (atomic, copy) NSArray<NSDictionary *> *stages;
/// When NO the chain is kept but not applied (an instant A/B comparison).
@property (atomic) BOOL enabled;
@property (nonatomic, readonly) BOOL isActive;

+ (NSString *)filterTextForStage:(NSDictionary *)stage;
+ (NSString *)titleForStage:(NSDictionary *)stage;
/// All stages joined into one FFmpeg -af graph, or an empty string.
- (NSString *)graph;
- (void)changed;

- (NSArray<NSDictionary *> *)stagesForPersistence;
- (void)loadFromArray:(nullable NSArray *)array enabled:(BOOL)enabled;

/// Renders an eight-second test signal (pink noise with tones) through `graph` and returns a WAV file.
/// Pass an empty graph for the unprocessed original. Completes on the main queue.
+ (void)renderDemoWithGraph:(NSString *)graph completion:(void (^)(NSURL * _Nullable file, NSString * _Nullable problem))completion;
@end

NS_ASSUME_NONNULL_END
