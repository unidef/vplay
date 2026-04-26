//
//  VPAudioDeviceManager.h
//  vplay
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPAudioDeviceManager : NSObject

/// Returns array of dictionaries: @{@"uid": ..., @"name": ..., @"type": @"input"|@"output", @"default": @"YES"|@"NO"}
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)listDevices;

/// Returns the UID of the system default output device
+ (nullable NSString *)defaultOutputDeviceUID;

/// Set the system default audio output device by UID
+ (BOOL)setOutputDeviceUID:(NSString *)uid error:(NSError **)error;

/// Returns the AudioDeviceID for a given UID, or 0 if not found
+ (AudioObjectID)deviceIDForUID:(NSString *)uid;

/// Resolve auto (0), max, or an explicit Hz value against the selected output device.
+ (nullable NSNumber *)sampleRateForOptions:(NSDictionary *)options error:(NSError **)error;
+ (BOOL)applySampleRateForOptions:(NSDictionary *)options error:(NSError **)error;

/// The sample rates (Hz) of the usual set (44.1 kHz … 384 kHz) that the output device reports it can run at.
/// `uid` nil means the system default output device.
+ (NSArray<NSNumber *> *)supportedSampleRatesForDeviceUID:(nullable NSString *)uid;
/// The highest nominal sample rate the device reports, or 0 if unknown.
+ (double)maximumSampleRateForDeviceUID:(nullable NSString *)uid;
@end

NS_ASSUME_NONNULL_END
