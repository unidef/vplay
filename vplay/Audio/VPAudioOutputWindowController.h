#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Choose the audio output device, its sample rate (upsampling) and the channel layout
/// (mono, 2.0, 2.1, 4.0, 4.1, 5.0, 5.1, 7.1) without editing JSON.
@interface VPAudioOutputWindowController : NSWindowController
/// Current values, as configuration keys: audioDevice (optional), audioSampleRate, audioLayout.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *(^currentSettings)(void);
/// Receives the chosen values when the user presses Apply.
@property (nonatomic, copy, nullable) void (^applyHandler)(NSDictionary<NSString *, NSString *> *settings);
- (void)reload;
@end

NS_ASSUME_NONNULL_END
