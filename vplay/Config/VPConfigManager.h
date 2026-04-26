//
//  VPConfigManager.h
//  vplay
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPConfigManager : NSObject

/// Loads config from the default path if it exists
- (instancetype)init;

/// Load from a specific path
- (BOOL)loadFromPath:(NSString *)path error:(NSError **)error;

/// Save to a specific path
- (BOOL)saveToPath:(NSString *)path error:(NSError **)error;

/// Save to the default path
- (BOOL)saveDefaults:(NSError **)error;

/// Default config file path (~~/Library/Application Support/vplay/config.json)
+ (NSString *)defaultConfigPath;

// --- Configuration properties ---

@property (nonatomic, copy, nullable) NSString *backgroundImagePath;
@property (nonatomic, copy, nullable) NSString *audioDeviceUID;
@property (nonatomic, assign) float defaultVolume;
@property (nonatomic, assign) float defaultRate;
@property (nonatomic, copy, nullable) NSString *effectSpec;
@property (nonatomic, copy, nullable) NSString *keymapSpec;
@property (nonatomic, copy, nullable) NSString *lastBrowsedDirectory;

@property (nonatomic, copy) NSDictionary *playbackOptions;
- (BOOL)applyDictionary:(NSDictionary *)dictionary error:(NSError **)error;
/// Full config as a dictionary
- (NSDictionary *)toDictionary;

/// Default keymap spec
+ (NSString *)defaultKeymapSpec;

@end

NS_ASSUME_NONNULL_END
