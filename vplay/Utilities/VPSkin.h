#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Notification posted when a skin is applied.
FOUNDATION_EXPORT NSString *const VPSkinApplyNotificationName;

/// Skins are small JSON files. Colors are "#RRGGBB"; every key is optional and falls back to the
/// built-in "Chrome Navy" skin.
///
/// Keys: backgroundColor, panelColor, panelHighlightColor, borderColor, textColor, accentColor,
///       opacity (0.2–1), cornerRadius (0–40), fontSize (11–32),
///       stageImage (picture shown on the empty stage instead of the logo),
///       panelImage (texture drawn inside panels), panelImageOpacity (0–1),
///       textureMenus (BOOL, default NO: whether menus/dialogs draw panel textures),
///       textureDialogs (BOOL, default NO: whether dialogs draw panel textures).
/// Image paths may be absolute or relative to the skin file; loading resolves them to absolute paths.
/// vplay ships 15 ready-made skins/themes that can be chosen by name.
@interface VPSkin : NSObject
+ (NSDictionary *)defaultSkin;
/// `path` may be a skin file or the name of a built-in skin (case-insensitive). Empty means the default skin.
+ (nullable NSDictionary *)loadPath:(nullable NSString *)path error:(NSError **)error;
+ (nullable NSDictionary *)skinFromJSONString:(NSString *)json error:(NSError **)error;
+ (NSString *)JSONStringForSkin:(NSDictionary *)skin;
+ (NSColor *)color:(NSString *)hex;
+ (NSString *)hexForColor:(NSColor *)color;
/// The color keys every skin carries, in the order the skin editor shows them.
+ (NSArray<NSString *> *)colorKeys;
+ (NSArray<NSString *> *)builtInSkinNames;
+ (nullable NSDictionary *)builtInSkinNamed:(NSString *)name;
/// Up to 10 built-in procedural textures: rain, ripple, snow, wave, metal, carbon, wood, canvas, brick, dots.
+ (NSArray<NSString *> *)availableTextures;
+ (BOOL)isBuiltInTextureName:(nullable NSString *)name;
+ (nullable NSImage *)textureNamed:(NSString *)name size:(NSSize)size;
/// Derives a full coordinated palette from one accent color.
+ (NSDictionary *)harmonizedSkinFromAccent:(NSColor *)accent;
@end

/// A panel that paints the skin's chrome look: a brushed-metal gradient, an optional texture image,
/// a bright edge and rounded corners.
@interface VPChromeView : NSView
@property (nonatomic, copy) NSDictionary *skin;
/// Whether this chrome view renders the skin's panel texture. Defaults to YES for general controls.
/// Menus and dialogs explicitly set this to NO unless textureMenus/textureDialogs is enabled.
@property (nonatomic, assign) BOOL allowsTexture;
- (void)updateTextureLayer;
@end

NS_ASSUME_NONNULL_END
