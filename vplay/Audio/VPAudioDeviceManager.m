//
//  VPAudioDeviceManager.m
//  vplay
//

#import "VPAudioDeviceManager.h"
#import <CoreAudio/CoreAudio.h>
#import <math.h>
#import <limits.h>

@implementation VPAudioDeviceManager

+ (nullable NSString *)defaultOutputDeviceUID {
    AudioObjectPropertyAddress propAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioDeviceID defaultDevice = 0;
    UInt32 size = sizeof(AudioDeviceID);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &size, &defaultDevice);
    if (status != noErr || defaultDevice == 0) return nil;

    AudioObjectPropertyAddress uidAddress = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uidRef = NULL;
    UInt32 uidSize = sizeof(CFStringRef);
    status = AudioObjectGetPropertyData(defaultDevice, &uidAddress, 0, NULL, &uidSize, &uidRef);
    if (status != noErr) return nil;

    NSString *uid = (__bridge_transfer NSString *)uidRef;
    return uid;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)listDevices {
    NSMutableArray *result = [NSMutableArray array];

    NSString *defaultUID = [self defaultOutputDeviceUID];

    AudioObjectPropertyAddress propAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &dataSize);
    if (status != noErr) return result;

    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(dataSize);
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &dataSize, deviceIDs);
    if (status != noErr) { free(deviceIDs); return result; }

    for (UInt32 i = 0; i < deviceCount; i++) {
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        CFStringRef uidRef = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        status = AudioObjectGetPropertyData(deviceIDs[i], &uidAddress, 0, NULL, &uidSize, &uidRef);
        if (status != noErr) continue;

        AudioObjectPropertyAddress nameAddress = {
            kAudioDevicePropertyDeviceNameCFString,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        CFStringRef nameRef = NULL;
        UInt32 nameSize = sizeof(CFStringRef);
        status = AudioObjectGetPropertyData(deviceIDs[i], &nameAddress, 0, NULL, &nameSize, &nameRef);
        if (status != noErr) { CFRelease(uidRef); continue; }

        AudioObjectPropertyAddress outputAddress = {
            kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        UInt32 outputSize = 0;
        AudioObjectGetPropertyDataSize(deviceIDs[i], &outputAddress, 0, NULL, &outputSize);
        NSString *type = (outputSize > 0) ? @"output" : @"input";

        NSString *uid = (__bridge NSString *)uidRef;
        BOOL isDefault = [uid isEqualToString:defaultUID];

        [result addObject:@{
            @"uid": uid,
            @"name": (__bridge NSString *)nameRef,
            @"type": type,
            @"default": isDefault ? @"YES" : @"NO"
        }];

        CFRelease(uidRef);
        CFRelease(nameRef);
    }

    free(deviceIDs);
    return result;
}

+ (AudioObjectID)deviceIDForUID:(NSString *)uid {
    AudioObjectPropertyAddress propAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &dataSize);
    if (status != noErr) return 0;

    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(dataSize);
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &dataSize, deviceIDs);
    if (status != noErr) { free(deviceIDs); return 0; }

    AudioObjectID found = 0;
    for (UInt32 i = 0; i < deviceCount; i++) {
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        CFStringRef uidRef = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        status = AudioObjectGetPropertyData(deviceIDs[i], &uidAddress, 0, NULL, &uidSize, &uidRef);
        if (status != noErr) continue;

        if ([uid isEqualToString:(__bridge NSString *)uidRef]) {
            found = deviceIDs[i];
            CFRelease(uidRef);
            break;
        }
        CFRelease(uidRef);
    }

    free(deviceIDs);
    return found;
}

+ (BOOL)setOutputDeviceUID:(NSString *)uid error:(NSError **)error {
    AudioObjectID deviceID = [self deviceIDForUID:uid];
    if (deviceID == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:10
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Audio device not found: %@", uid]}];
        }
        return NO;
    }

    // Verify it's an output device
    AudioObjectPropertyAddress outputAddress = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 outputSize = 0;
    AudioObjectGetPropertyDataSize(deviceID, &outputAddress, 0, NULL, &outputSize);
    if (outputSize == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:11
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Device is not an output device: %@", uid]}];
        }
        return NO;
    }

    // Set as default output device
    AudioObjectPropertyAddress defaultAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectSetPropertyData(kAudioObjectSystemObject, &defaultAddress, 0, NULL,
                                                  sizeof(AudioDeviceID), &deviceID);
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:12
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Failed to set output device (error %d)", (int)status]}];
        }
        return NO;
    }

    return YES;
}

+ (NSNumber *)sampleRateForOptions:(NSDictionary *)options error:(NSError **)error {
    NSString *selection = options[@"audioSampleRate"] ?: @"auto";
    if ([selection isEqual:@"auto"]) return @0;
    NSString *uid = options[@"audioDevice"] ?: [self defaultOutputDeviceUID];
    AudioObjectID device = uid ? [self deviceIDForUID:uid] : 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (device && AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) == noErr && size >= sizeof(AudioValueRange)) {
        NSMutableData *data = [NSMutableData dataWithLength:size];
        if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, data.mutableBytes) == noErr) {
            const AudioValueRange *ranges = data.bytes;
            double requested = selection.doubleValue;
            double maximum = 0;
            BOOL supported = NO;
            for (NSUInteger i = 0; i < size / sizeof(AudioValueRange); i++) {
                if (isfinite(ranges[i].mMaximum) && ranges[i].mMaximum <= INT_MAX) maximum = MAX(maximum, floor(ranges[i].mMaximum));
                if (requested >= ranges[i].mMinimum && requested <= ranges[i].mMaximum) supported = YES;
            }
            if ([selection isEqual:@"max"] && maximum > 0) return @(maximum);
            if (supported && requested > 0 && requested <= INT_MAX && floor(requested) == requested) return @(requested);
        }
    }
    if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:13 userInfo:@{NSLocalizedDescriptionKey:@"Cannot resolve the requested sample rate on the selected output device. Choose a supported Hz value or auto."}];
    return nil;
}

+ (BOOL)applySampleRateForOptions:(NSDictionary *)options error:(NSError **)error {
    NSNumber *rate = [self sampleRateForOptions:options error:error];
    if (!rate) return NO;
    if (rate.doubleValue == 0) return YES;
    NSString *uid = options[@"audioDevice"] ?: [self defaultOutputDeviceUID];
    AudioObjectID device = uid ? [self deviceIDForUID:uid] : 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float64 current = 0, desired = rate.doubleValue;
    UInt32 size = sizeof(current);
    if (device && AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &current) == noErr && fabs(current - desired) < 0.5) return YES;
    Boolean settable = false;
    OSStatus status = AudioObjectIsPropertySettable(device, &address, &settable);
    if (status == noErr && settable) status = AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(desired), &desired);
    if (status != noErr || !settable) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:14 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"The audio device could not switch to %.0f Hz (Core Audio status %d).", desired, (int)status]}];
        return NO;
    }
    return YES;
}

+ (NSArray<NSValue *> *)rangesForDeviceUID:(NSString *)uid {
    NSString *resolved = uid ?: [self defaultOutputDeviceUID];
    AudioObjectID device = resolved ? [self deviceIDForUID:resolved] : 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    NSMutableArray *ranges = [NSMutableArray array];
    if (device && AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) == noErr && size >= sizeof(AudioValueRange)) {
        NSMutableData *data = [NSMutableData dataWithLength:size];
        if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, data.mutableBytes) == noErr) {
            const AudioValueRange *values = data.bytes;
            for (NSUInteger i = 0; i < size / sizeof(AudioValueRange); i++) [ranges addObject:[NSValue valueWithBytes:&values[i] objCType:@encode(AudioValueRange)]];
        }
    }
    return ranges;
}

+ (NSArray<NSNumber *> *)supportedSampleRatesForDeviceUID:(NSString *)uid {
    NSArray *ranges = [self rangesForDeviceUID:uid];
    NSMutableArray *supported = [NSMutableArray array];
    for (NSNumber *rate in @[@44100, @48000, @88200, @96000, @176400, @192000, @352800, @384000]) {
        for (NSValue *value in ranges) {
            AudioValueRange range; [value getValue:&range];
            if (rate.doubleValue >= range.mMinimum && rate.doubleValue <= range.mMaximum) { [supported addObject:rate]; break; }
        }
    }
    return supported;
}

+ (double)maximumSampleRateForDeviceUID:(NSString *)uid {
    double maximum = 0;
    for (NSValue *value in [self rangesForDeviceUID:uid]) { AudioValueRange range; [value getValue:&range]; if (isfinite(range.mMaximum)) maximum = MAX(maximum, floor(range.mMaximum)); }
    return maximum;
}
@end
