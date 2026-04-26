#import "VPSkin.h"
#import <QuartzCore/QuartzCore.h>

NSString *const VPSkinApplyNotificationName = @"com.jonathanmaharaj.vplay.applySkin";

static NSDictionary *Make(NSString *name, NSString *bg, NSString *panel, NSString *highlight, NSString *border, NSString *text, NSString *accent, double opacity, double radius) {
    return @{
        @"name": name,
        @"backgroundColor": bg,
        @"panelColor": panel,
        @"panelHighlightColor": highlight,
        @"borderColor": border,
        @"textColor": text,
        @"accentColor": accent,
        @"opacity": @(opacity),
        @"cornerRadius": @(radius),
        @"fontSize": @13,
        @"panelImageOpacity": @0.55,
        @"textureMenus": @NO,
        @"textureDialogs": @NO
    };
}

static NSArray<NSDictionary *> *BuiltIns(void) {
    static NSArray *skins; static dispatch_once_t once;
    dispatch_once(&once, ^{
        skins = @[
            Make(@"Chrome Navy",   @"#000000", @"#2F5088", @"#8FB0DE", @"#D5E3F6", @"#F2F7FF", @"#BFE3FF", 0.90, 14),
            Make(@"Midnight Blue", @"#000000", @"#1B2A52", @"#4A64A8", @"#9FB4E8", @"#EAF0FF", @"#7FB2FF", 0.92, 14),
            Make(@"Graphite",      @"#050505", @"#3A3D42", @"#8E949C", @"#D2D6DB", @"#F4F5F7", @"#C9D1DA", 0.92, 10),
            Make(@"Aurora",        @"#02100E", @"#0F5B55", @"#3FD1B0", @"#A8F5E0", @"#F0FFFA", @"#7CFFC4", 0.88, 16),
            Make(@"Sunset",        @"#0B0305", @"#8A2F3C", @"#F08A5D", @"#FFD0A8", @"#FFF4EC", @"#FFC857", 0.90, 16),
            Make(@"Rose Quartz",   @"#0A0408", @"#A5527A", @"#E8A0C0", @"#FFD9EA", @"#FFF5FA", @"#FFB3D1", 0.90, 18),
            Make(@"Forest",        @"#030803", @"#2B5A34", @"#7DB26B", @"#CFE8B8", @"#F2FFEA", @"#B5E26B", 0.92, 12),
            Make(@"Ocean Glass",   @"#00060A", @"#1A6E8E", @"#7CD6E8", @"#CFF4FF", @"#F0FCFF", @"#7CF0FF", 0.78, 20),
            Make(@"Solar Gold",    @"#080600", @"#8A6A1B", @"#F0CE6B", @"#FFE9A8", @"#FFFBEA", @"#FFD54A", 0.92, 12),
            Make(@"Crimson Noir",  @"#000000", @"#4A0E16", @"#A3283A", @"#FF8A99", @"#FFEFF1", @"#FF4D63", 0.94, 8),
            Make(@"Arctic",        @"#05080C", @"#D7E4F2", @"#FFFFFF", @"#FFFFFF", @"#0E2238", @"#1D6FD1", 0.94, 14),
            Make(@"Neon Cyber",    @"#02000A", @"#2A0F5C", @"#8A3CFF", @"#00F0FF", @"#F4F0FF", @"#00F0FF", 0.90, 6),
            Make(@"Emerald Mint",  @"#021208", @"#144D32", @"#2E9D68", @"#A0E8C2", @"#F2FFF7", @"#3DDB8C", 0.90, 14),
            Make(@"Amethyst",      @"#0A0314", @"#3B1A59", @"#8444B8", @"#DDBBF5", @"#F8F2FF", @"#B366FF", 0.90, 16),
            Make(@"Amber Slate",   @"#0D0B08", @"#38302A", @"#7D6858", @"#D9CBBF", @"#FFF8F0", @"#F5A623", 0.92, 12),
        ];
    });
    return skins;
}

@implementation VPSkin

+ (NSArray<NSString *> *)colorKeys {
    return @[@"backgroundColor", @"panelColor", @"panelHighlightColor", @"borderColor", @"textColor", @"accentColor"];
}

+ (NSArray<NSString *> *)builtInSkinNames { return [BuiltIns() valueForKey:@"name"]; }

+ (NSDictionary *)builtInSkinNamed:(NSString *)name {
    for (NSDictionary *skin in BuiltIns()) if ([skin[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) return skin;
    return nil;
}

static NSString *NormalizeTextureName(NSString *name) {
    if (!name || ![name isKindOfClass:[NSString class]]) return @"";
    NSString *lower = name.lowercaseString;
    if ([lower isEqualToString:@"ripples"]) return @"ripple";
    if ([lower isEqualToString:@"brushed"]) return @"metal";
    return lower;
}

+ (NSArray<NSString *> *)availableTextures {
    return @[@"rain", @"ripple", @"snow", @"wave", @"metal", @"carbon", @"wood", @"canvas", @"brick", @"dots"];
}

+ (BOOL)isBuiltInTextureName:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    NSString *lower = NormalizeTextureName(name);
    return [[self availableTextures] containsObject:lower];
}

+ (nullable NSImage *)textureNamed:(NSString *)name size:(NSSize)size {
    if (size.width <= 0 || size.height <= 0) size = NSMakeSize(256, 256);
    NSString *tex = NormalizeTextureName(name);
    if (![[self availableTextures] containsObject:tex]) return nil;

    NSString *key = [NSString stringWithFormat:@"%@_%.0fx%.0f", tex, size.width, size.height];
    static NSCache *textureCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textureCache = [[NSCache alloc] init];
    });
    NSImage *cached = [textureCache objectForKey:key];
    if (cached) return cached;

    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        CGFloat w = dstRect.size.width;
        CGFloat h = dstRect.size.height;
        if (w <= 1.0 || h <= 1.0) return YES;

        // Clear background so underlying theme gradient colors shine through seamlessly
        if ([tex isEqual:@"brick"]) {
            CGFloat brickH = 20.0, brickW = 46.0, gap = 3.0;
            NSInteger rows = (NSInteger)ceil(h / (brickH + gap)) + 1;
            NSInteger cols = (NSInteger)ceil(w / (brickW + gap)) + 2;
            for (NSInteger r = 0; r < rows; r++) {
                CGFloat y = r * (brickH + gap);
                CGFloat xOffset = (r % 2 == 0) ? 0 : -(brickW / 2.0);
                for (NSInteger c = 0; c < cols; c++) {
                    CGFloat x = xOffset + c * (brickW + gap);
                    NSRect bRect = NSMakeRect(x, y, brickW, brickH);
                    [[NSColor colorWithWhite:1.0 alpha:0.08] setFill];
                    NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:bRect xRadius:2 yRadius:2];
                    [bp fill];
                    [[NSColor colorWithWhite:0.0 alpha:0.40] setStroke];
                    [NSBezierPath strokeLineFromPoint:NSMakePoint(x, y) toPoint:NSMakePoint(x + brickW, y)];
                    [NSBezierPath strokeLineFromPoint:NSMakePoint(x, y) toPoint:NSMakePoint(x, y + brickH)];
                    [[NSColor colorWithWhite:1.0 alpha:0.25] setStroke];
                    [NSBezierPath strokeLineFromPoint:NSMakePoint(x + 1, y + brickH - 1) toPoint:NSMakePoint(x + brickW - 1, y + brickH - 1)];
                }
            }
        } else if ([tex isEqual:@"snow"]) {
            for (NSInteger i = 0; i < 60; i++) {
                CGFloat sx = ((i * 59 + 17) % (NSInteger)w);
                CGFloat sy = ((i * 83 + 29) % (NSInteger)h);
                CGFloat rad = 2.0 + ((i * 11) % 6);
                CGFloat alpha = 0.35 + 0.55 * (((i * 7) % 10) / 10.0);
                NSColor *snowColor = [NSColor colorWithRed:0.92 green:0.97 blue:1.0 alpha:alpha];
                [snowColor setStroke];
                [snowColor setFill];
                if (i % 3 == 0) {
                    for (int arm = 0; arm < 3; arm++) {
                        CGFloat angle = arm * M_PI / 3.0;
                        CGFloat dx = cos(angle) * rad * 1.6;
                        CGFloat dy = sin(angle) * rad * 1.6;
                        NSBezierPath *line = [NSBezierPath bezierPath];
                        line.lineWidth = 1.2;
                        [line moveToPoint:NSMakePoint(sx - dx, sy - dy)];
                        [line lineToPoint:NSMakePoint(sx + dx, sy + dy)];
                        [line stroke];
                    }
                } else {
                    NSBezierPath *circ = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(sx - rad/2.0, sy - rad/2.0, rad, rad)];
                    [circ fill];
                }
            }
        } else if ([tex isEqual:@"rain"]) {
            for (NSInteger i = 0; i < 75; i++) {
                CGFloat rx = ((i * 47 + 13) % (NSInteger)(w + 40)) - 20;
                CGFloat ry = ((i * 71 + 31) % (NSInteger)(h + 40)) - 20;
                CGFloat len = 14.0 + ((i * 13) % 24);
                CGFloat alpha = 0.25 + 0.60 * (((i * 9) % 10) / 10.0);
                NSColor *rainColor = [NSColor colorWithRed:0.75 green:0.88 blue:1.0 alpha:alpha];
                [rainColor setStroke];
                [rainColor setFill];
                NSBezierPath *streak = [NSBezierPath bezierPath];
                streak.lineWidth = 1.0 + ((i % 5 == 0) ? 0.8 : 0.0);
                [streak moveToPoint:NSMakePoint(rx, ry)];
                [streak lineToPoint:NSMakePoint(rx - len * 0.35, ry - len)];
                [streak stroke];
                if (i % 4 == 0) {
                    NSBezierPath *drop = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(rx - len * 0.35 - 1, ry - len - 1, 2, 2)];
                    [drop fill];
                }
            }
        } else if ([tex isEqual:@"ripple"] || [tex isEqual:@"ripples"]) {
            CGPoint centers[] = { CGPointMake(w * 0.28, h * 0.45), CGPointMake(w * 0.72, h * 0.65), CGPointMake(w * 0.50, h * 0.30) };
            for (int c = 0; c < 3; c++) {
                CGPoint cp = centers[c];
                for (CGFloat r = 10; r < 280; r += 16) {
                    CGFloat alpha = (0.50 - (r / 600.0));
                    if (alpha > 0.05) {
                        NSColor *ringColor = [NSColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:alpha];
                        [ringColor setStroke];
                        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cp.x - r, cp.y - r * 0.65, r * 2, r * 1.3)];
                        ring.lineWidth = 1.4;
                        [ring stroke];
                    }
                }
            }
        } else if ([tex isEqual:@"wave"]) {
            for (NSInteger i = 0; i < 16; i++) {
                CGFloat yBase = i * (h / 14.0) - 10;
                CGFloat alpha = 0.22 + 0.45 * (sin(i * 0.5) * 0.5 + 0.5);
                NSColor *waveColor = [NSColor colorWithRed:0.40 green:0.82 blue:0.98 alpha:alpha];
                [waveColor setStroke];
                NSBezierPath *wp = [NSBezierPath bezierPath];
                wp.lineWidth = 1.6;
                for (CGFloat x = 0; x <= w + 4; x += 4) {
                    CGFloat y = yBase + sin(x * 0.035 + i * 0.7) * 9.0 + cos(x * 0.018 + i) * 5.0;
                    if (x == 0) [wp moveToPoint:NSMakePoint(x, y)];
                    else [wp lineToPoint:NSMakePoint(x, y)];
                }
                [wp stroke];
            }
        } else if ([tex isEqual:@"metal"]) {
            for (CGFloat y = 0; y < h; y += 1.0) {
                CGFloat grain = (((NSInteger)(y * 31 + 7)) % 100) / 100.0;
                if (grain > 0.5) {
                    CGFloat alpha = 0.08 + 0.22 * (grain - 0.5) * 2.0;
                    [[NSColor colorWithWhite:1.0 alpha:alpha] setStroke];
                } else {
                    CGFloat alpha = 0.06 + 0.18 * (0.5 - grain) * 2.0;
                    [[NSColor colorWithWhite:0.0 alpha:alpha] setStroke];
                }
                [NSBezierPath strokeLineFromPoint:NSMakePoint(0, y) toPoint:NSMakePoint(w, y)];
            }
        } else if ([tex isEqual:@"carbon"]) {
            CGFloat unit = 16.0;
            for (CGFloat y = 0; y < h; y += unit) {
                for (CGFloat x = 0; x < w; x += unit) {
                    BOOL diag = (((NSInteger)(x / unit) + (NSInteger)(y / unit)) % 2 == 0);
                    NSRect block = NSMakeRect(x, y, unit, unit);
                    if (diag) {
                        [[NSColor colorWithWhite:1.0 alpha:0.14] setFill];
                        NSRectFill(block);
                        [[NSColor colorWithWhite:1.0 alpha:0.25] setStroke];
                        for (CGFloat s = 2; s < unit; s += 3) {
                            [NSBezierPath strokeLineFromPoint:NSMakePoint(x + s, y) toPoint:NSMakePoint(x + s, y + unit)];
                        }
                    } else {
                        [[NSColor colorWithWhite:0.0 alpha:0.22] setFill];
                        NSRectFill(block);
                        [[NSColor colorWithWhite:0.0 alpha:0.28] setStroke];
                        for (CGFloat s = 2; s < unit; s += 3) {
                            [NSBezierPath strokeLineFromPoint:NSMakePoint(x, y + s) toPoint:NSMakePoint(x + unit, y + s)];
                        }
                    }
                }
            }
        } else if ([tex isEqual:@"wood"]) {
            for (NSInteger i = 0; i < 24; i++) {
                CGFloat xBase = i * (w / 20.0) - 20;
                CGFloat alpha = 0.20 + 0.35 * (((i * 11) % 10) / 10.0);
                NSBezierPath *grain = [NSBezierPath bezierPath];
                grain.lineWidth = 1.2 + (i % 4 == 0 ? 0.8 : 0.0);
                for (CGFloat y = 0; y <= h + 4; y += 4) {
                    CGFloat x = xBase + sin(y * 0.03 + i * 0.6) * 14.0 + cos(y * 0.06) * 6.0;
                    if (y == 0) [grain moveToPoint:NSMakePoint(x, y)];
                    else [grain lineToPoint:NSMakePoint(x, y)];
                }
                [[NSColor colorWithWhite:0.0 alpha:alpha * 0.75] setStroke];
                [grain stroke];
                [[NSColor colorWithWhite:1.0 alpha:alpha * 0.40] setStroke];
                NSAffineTransform *t = [NSAffineTransform transform];
                [t translateXBy:1.0 yBy:0.5];
                [grain transformUsingAffineTransform:t];
                [grain stroke];
            }
        } else if ([tex isEqual:@"canvas"]) {
            for (CGFloat x = 0; x < w; x += 4.0) {
                CGFloat a = 0.10 + 0.18 * (((NSInteger)(x * 19) % 10) / 10.0);
                [[NSColor colorWithWhite:1.0 alpha:a] setStroke];
                [NSBezierPath strokeLineFromPoint:NSMakePoint(x, 0) toPoint:NSMakePoint(x, h)];
            }
            for (CGFloat y = 0; y < h; y += 4.0) {
                CGFloat a = 0.10 + 0.18 * (((NSInteger)(y * 23) % 10) / 10.0);
                [[NSColor colorWithWhite:0.0 alpha:a * 1.2] setStroke];
                [NSBezierPath strokeLineFromPoint:NSMakePoint(0, y) toPoint:NSMakePoint(w, y)];
            }
        } else if ([tex isEqual:@"dots"]) {
            CGFloat spacing = 12.0;
            CGFloat radius = 2.2;
            for (CGFloat y = spacing / 2.0; y < h; y += spacing) {
                for (CGFloat x = spacing / 2.0; x < w; x += spacing) {
                    [[NSColor colorWithWhite:0.0 alpha:0.40] setFill];
                    NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - radius, y - radius, radius * 2, radius * 2)];
                    [dot fill];
                    [[NSColor colorWithWhite:1.0 alpha:0.25] setStroke];
                    NSBezierPath *rim = [NSBezierPath bezierPath];
                    rim.lineWidth = 0.8;
                    [rim appendBezierPathWithArcWithCenter:NSMakePoint(x, y) radius:radius startAngle:200 endAngle:340];
                    [rim stroke];
                }
            }
        }
        return YES;
    }];

    if (image) [textureCache setObject:image forKey:key];
    return image;
}

+ (NSDictionary *)defaultSkin { return BuiltIns().firstObject; }

+ (NSColor *)color:(NSString *)hex {
    unsigned int rgb = 0;
    if (hex.length == 7) [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&rgb];
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255)/255.0 green:((rgb >> 8) & 255)/255.0 blue:(rgb & 255)/255.0 alpha:1];
}

+ (NSString *)hexForColor:(NSColor *)color {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: color;
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(c.redComponent * 255), (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255)];
}

+ (NSDictionary *)harmonizedSkinFromAccent:(NSColor *)accent {
    NSColor *c = [accent colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: accent;
    CGFloat h, s, b, a;
    [c getHue:&h saturation:&s brightness:&b alpha:&a];
    NSColor *panel = [NSColor colorWithHue:h saturation:MIN(1, MAX(0.35, s * 0.8)) brightness:0.42 alpha:1];
    NSColor *highlight = [NSColor colorWithHue:h saturation:MAX(0.2, s * 0.55) brightness:0.88 alpha:1];
    NSColor *border = [NSColor colorWithHue:h saturation:MAX(0.08, s * 0.2) brightness:0.97 alpha:1];
    NSMutableDictionary *skin = [[self defaultSkin] mutableCopy];
    skin[@"name"] = @"Custom";
    skin[@"backgroundColor"] = @"#000000";
    skin[@"panelColor"] = [self hexForColor:panel];
    skin[@"panelHighlightColor"] = [self hexForColor:highlight];
    skin[@"borderColor"] = [self hexForColor:border];
    skin[@"textColor"] = @"#F7FAFF";
    skin[@"accentColor"] = [self hexForColor:c];
    skin[@"textureMenus"] = @NO;
    skin[@"textureDialogs"] = @NO;
    return skin;
}

/// Resolves an image path against the skin file's folder; returns nil for an empty value.
static NSString *ResolveImage(NSString *value, NSString *baseDirectory) {
    if (![value isKindOfClass:NSString.class] || !value.length) return nil;
    NSString *path = value.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath && baseDirectory) path = [baseDirectory stringByAppendingPathComponent:path];
    return path;
}

+ (NSDictionary *)validatedSkin:(NSDictionary *)value baseDirectory:(NSString *)base error:(NSError **)error {
    BOOL valid = [value isKindOfClass:NSDictionary.class];
    NSMutableDictionary *skin = [[self defaultSkin] mutableCopy];
    if (valid) [skin addEntriesFromDictionary:value];
    NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9a-fA-F]{6}$" options:0 error:nil];
    for (NSString *key in [self colorKeys]) {
        id color = skin[key];
        if (![color isKindOfClass:NSString.class] || [hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, [color length])] != 1) valid = NO;
    }
    NSDictionary *ranges = @{@"opacity":@[@0.2,@1], @"cornerRadius":@[@0,@40], @"fontSize":@[@11,@32], @"panelImageOpacity":@[@0,@1]};
    for (NSString *key in ranges) {
        id number = skin[key];
        if (![number isKindOfClass:NSNumber.class] || !isfinite([number doubleValue]) || [number doubleValue] < [ranges[key][0] doubleValue] || [number doubleValue] > [ranges[key][1] doubleValue]) valid = NO;
    }
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:83 userInfo:@{NSLocalizedDescriptionKey:@"Invalid skin. Colors must be #RRGGBB; opacity 0.2–1, cornerRadius 0–40, fontSize 11–32, panelImageOpacity 0–1."}];
        return nil;
    }
    if (![value isKindOfClass:NSDictionary.class] || !value[@"name"]) [skin removeObjectForKey:@"name"];   // do not inherit the default skin's name
    for (NSString *key in @[@"stageImage", @"panelImage"]) {
        if ([skin[key] isKindOfClass:NSString.class] && [self isBuiltInTextureName:skin[key]]) {
            continue;
        }
        NSString *resolved = ResolveImage(skin[key], base);
        if (resolved) skin[key] = resolved; else [skin removeObjectForKey:key];
    }
    return skin;
}

+ (NSDictionary *)loadPath:(NSString *)path error:(NSError **)error {
    if (!path.length) return [self defaultSkin];
    NSDictionary *builtIn = [self builtInSkinNamed:path];
    if (builtIn && ![NSFileManager.defaultManager fileExistsAtPath:path.stringByExpandingTildeInPath]) return builtIn;
    NSString *full = path.stringByExpandingTildeInPath;
    NSData *data = [NSData dataWithContentsOfFile:full options:0 error:error];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [self validatedSkin:value baseDirectory:full.stringByDeletingLastPathComponent error:error];
}

+ (NSDictionary *)skinFromJSONString:(NSString *)json error:(NSError **)error {
    id value = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
    return [self validatedSkin:value baseDirectory:nil error:error];
}

+ (NSString *)JSONStringForSkin:(NSDictionary *)skin {
    NSData *data = [NSJSONSerialization dataWithJSONObject:skin options:NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}
@end

@interface VPChromeView ()
@property (nonatomic, strong) CALayer *imageLayer;
@property (nonatomic, copy) NSString *loadedImagePath;
@end

@implementation VPChromeView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _allowsTexture = YES;
        _imageLayer = [CALayer layer];
        _imageLayer.contentsGravity = kCAGravityResizeAspectFill;
        _imageLayer.hidden = YES;
        [self.layer insertSublayer:_imageLayer atIndex:0];
        self.skin = [VPSkin defaultSkin];
    }
    return self;
}
- (CALayer *)makeBackingLayer { return [CAGradientLayer layer]; }

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    subview.wantsLayer = YES;
    if (self.imageLayer.superlayer == self.layer) {
        [self.layer insertSublayer:self.imageLayer atIndex:0];
    }
}

- (void)layout {
    [super layout];
    [self updateTextureFrame];
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self updateTextureFrame];
}

- (void)setBounds:(NSRect)bounds {
    [super setBounds:bounds];
    [self updateTextureFrame];
}

- (void)updateTextureFrame {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.imageLayer.frame = self.layer.bounds;
    self.imageLayer.cornerRadius = ((CAGradientLayer *)self.layer).cornerRadius;
    self.imageLayer.masksToBounds = YES;
    [CATransaction commit];
}

- (void)setAllowsTexture:(BOOL)allowsTexture {
    _allowsTexture = allowsTexture;
    [self updateTextureLayer];
}

- (void)setSkin:(NSDictionary *)skin {
    _skin = [skin copy];
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    CGFloat alpha = [skin[@"opacity"] doubleValue];
    if (alpha <= 0) alpha = 0.90;
    NSColor *panel = [VPSkin color:skin[@"panelColor"]];
    NSColor *top = [VPSkin color:skin[@"panelHighlightColor"]];
    NSColor *bottom = [panel blendedColorWithFraction:0.55 ofColor:NSColor.blackColor] ?: panel;
    // Brushed-metal look: bright top, saturated middle, dark base.
    layer.colors = @[(id)[top colorWithAlphaComponent:alpha].CGColor,
                     (id)[[top blendedColorWithFraction:0.45 ofColor:panel] colorWithAlphaComponent:alpha].CGColor,
                     (id)[panel colorWithAlphaComponent:alpha].CGColor,
                     (id)[bottom colorWithAlphaComponent:alpha].CGColor];
    layer.locations = @[@0, @0.18, @0.5, @1];
    layer.startPoint = CGPointMake(0.5, 1);   // layer-backed NSView: y grows upward, so 1 is the top edge
    layer.endPoint = CGPointMake(0.5, 0);
    layer.cornerRadius = [skin[@"cornerRadius"] doubleValue];
    layer.borderWidth = 1;
    layer.borderColor = [[VPSkin color:skin[@"borderColor"]] colorWithAlphaComponent:0.85].CGColor;
    layer.masksToBounds = YES;

    [self updateTextureLayer];
}

- (void)updateTextureLayer {
    if (!self.allowsTexture) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.imageLayer.hidden = YES;
        self.imageLayer.contents = nil;
        self.loadedImagePath = nil;
        [CATransaction commit];
        return;
    }

    NSString *imagePath = self.skin[@"panelImage"] ?: self.skin[@"texture"];
    if (imagePath.length && ![imagePath.lowercaseString isEqualToString:@"none"]) {
        NSSize currentSize = self.bounds.size;
        if (currentSize.width <= 1.0 || currentSize.height <= 1.0) {
            currentSize = NSMakeSize(860, 200);
        }

        NSImage *image = nil;
        if ([VPSkin isBuiltInTextureName:imagePath]) {
            image = [VPSkin textureNamed:imagePath size:currentSize];
        } else {
            image = [[NSImage alloc] initWithContentsOfFile:imagePath.stringByExpandingTildeInPath];
        }

        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.imageLayer.frame = self.layer.bounds;
        self.imageLayer.contents = cg ? (__bridge id)cg : nil;
        self.loadedImagePath = cg ? imagePath : nil;

        double opacity = [self.skin[@"panelImageOpacity"] doubleValue];
        if (opacity <= 0.05) opacity = 0.55;
        self.imageLayer.opacity = opacity;
        self.imageLayer.cornerRadius = ((CAGradientLayer *)self.layer).cornerRadius;
        self.imageLayer.masksToBounds = YES;
        self.imageLayer.hidden = (self.loadedImagePath == nil);

        if (self.imageLayer.superlayer != self.layer) {
            [self.layer insertSublayer:self.imageLayer atIndex:0];
        } else {
            [self.layer insertSublayer:self.imageLayer atIndex:0];
        }
        [CATransaction commit];
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.imageLayer.hidden = YES;
        self.loadedImagePath = nil;
        self.imageLayer.contents = nil;
        [CATransaction commit];
    }
}
@end
