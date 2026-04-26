#import "VPIntroView.h"
#import <QuartzCore/QuartzCore.h>

static const NSUInteger kParticles = 240;
static const double kIntroDuration = 7.0;

typedef struct { double startAngle, startRadius, swirl, delay, length, size, hue; } VPParticle;

static double Clamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }
static double EaseOutCubic(double t) { t = Clamp01(t); return 1 - pow(1 - t, 3); }
static double EaseInOut(double t) { t = Clamp01(t); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2; }
static double EaseOutBack(double t) { t = Clamp01(t); double c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2); }
static double Segment(double t, double from, double to) { return Clamp01((t - from) / (to - from)); }

@interface VPIntroView () {
    VPParticle _particles[240];
}
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) CFTimeInterval startTime;
@property (nonatomic) double elapsed;
@property (nonatomic) BOOL finished;
@end

@implementation VPIntroView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _accentColor = [NSColor colorWithSRGBRed:0.45 green:0.9 blue:1 alpha:1];
        self.wantsLayer = YES;
        // A fresh arrangement every launch: procedural vortex particle system
        for (NSUInteger i = 0; i < kParticles; i++) {
            _particles[i].startAngle = drand48() * 2 * M_PI;
            _particles[i].startRadius = 0.8 + drand48() * 1.3;       // in units of the ring radius * factor
            _particles[i].swirl = (drand48() * 2 - 1) * 2.8 * M_PI + (drand48() < 0.5 ? -1 : 1) * 1.2 * M_PI;
            _particles[i].delay = drand48() * 1.4;
            _particles[i].length = 1.2 + drand48() * 1.4;
            _particles[i].size = 1.2 + drand48() * 2.6;
            _particles[i].hue = drand48();
        }
    }
    return self;
}

- (NSTimeInterval)duration { return kIntroDuration; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)start {
    srand48((long)(CACurrentMediaTime() * 1000));
    self.startTime = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        VPIntroView *view = weakSelf;
        if (!view) { [timer invalidate]; return; }
        view.elapsed = CACurrentMediaTime() - view.startTime;
        view.needsDisplay = YES;
        if (view.elapsed >= kIntroDuration) [view finish];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)skip { [self finish]; }

- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [self.timer invalidate]; self.timer = nil;
    void (^handler)(void) = self.finishHandler;
    self.finishHandler = nil;
    if (handler) handler();
}

- (void)dealloc { [self.timer invalidate]; }

- (void)mouseDown:(NSEvent *)event { [self skip]; }   // a click skips the intro
- (void)keyDown:(NSEvent *)event { [self skip]; }     // any key skips the intro

#pragma mark - Drawing

/// Rounded play triangle (same construction as the static logo).
static CGPathRef CreateTriangle(CGFloat cx, CGFloat cy, CGFloat r) {
    CGPoint pts[3];
    for (int i = 0; i < 3; i++) { CGFloat a = i * 2 * M_PI / 3; pts[i] = CGPointMake(cx + r * cos(a), cy + r * sin(a)); }
    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < 3; i++) {
        CGPoint prev = pts[(i + 2) % 3], cur = pts[i], next = pts[(i + 1) % 3];
        CGPoint a = CGPointMake(cur.x + (prev.x - cur.x) * 0.22, cur.y + (prev.y - cur.y) * 0.22);
        CGPoint b = CGPointMake(cur.x + (next.x - cur.x) * 0.22, cur.y + (next.y - cur.y) * 0.22);
        if (i == 0) CGPathMoveToPoint(path, NULL, a.x, a.y); else CGPathAddLineToPoint(path, NULL, a.x, a.y);
        CGPathAddQuadCurveToPoint(path, NULL, cur.x, cur.y, b.x, b.y);
    }
    CGPathCloseSubpath(path);
    return path;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    double t = MIN(self.elapsed, kIntroDuration);
    NSRect bounds = self.bounds;

    // Same placement as the static 1600x900 logo image, aspect-fit into the view.
    CGFloat scale = MIN(bounds.size.width / 1600.0, bounds.size.height / 900.0);
    CGSize size = CGSizeMake(1600 * scale, 900 * scale);
    CGPoint origin = CGPointMake(NSMidX(bounds) - size.width / 2, NSMidY(bounds) - size.height / 2);
    CGPoint center = CGPointMake(origin.x + 800 * scale, origin.y + 520 * scale);
    CGFloat s = 560 * scale, ringR = 0.40 * s;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    NSColor *accent = [self.accentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: self.accentColor;

    // Black stage with a soft blue glow that swells as the logo forms.
    [NSColor.blackColor setFill]; NSRectFill(bounds);
    double glow = EaseOutCubic(Segment(t, 0.3, 3.8));
    double pulse = 1.0 + (t > 3.8 ? 0.04 * sin((t - 3.8) * 2.5) : 0);
    CGFloat glowColors[] = {0.12, 0.48, 1, (CGFloat)(0.28 * glow), 0.12, 0.48, 1, 0};
    CGGradientRef glowGradient = CGGradientCreateWithColorComponents(rgb, glowColors, NULL, 2);
    CGContextDrawRadialGradient(ctx, glowGradient, center, 0, center, 560 * scale * (0.6 + 0.4 * glow) * pulse, 0);
    CGGradientRelease(glowGradient);

    // 1. Particles spiral inward and settle onto the ring.
    double settle = 1 - Segment(t, 3.8, 5.0);       // particles dissolve once the real ring has drawn
    for (NSUInteger i = 0; i < kParticles; i++) {
        VPParticle p = _particles[i];
        double progress = EaseOutCubic((t - p.delay) / p.length);
        if (t < p.delay) continue;
        double targetAngle = (double)i / (double)kParticles * 2 * M_PI - M_PI_2;
        double angle = targetAngle + (p.startAngle - targetAngle) * (1 - progress) + p.swirl * (1 - progress) * (1 - progress) * 0.35;
        double radius = ringR + (ringR * 3.6 * p.startRadius - ringR) * (1 - progress);
        CGPoint pos = CGPointMake(center.x + cos(angle) * radius, center.y + sin(angle) * radius);
        double alpha = (0.15 + 0.85 * Clamp01(progress * 1.5)) * settle;
        if (alpha <= 0.01) continue;
        NSColor *color = [NSColor colorWithHue:fmod(0.52 + 0.1 * p.hue, 1) saturation:0.55 brightness:1 alpha:alpha];
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 8 * scale, [color colorWithAlphaComponent:0.9].CGColor);
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGFloat dot = p.size * scale * (0.8 + 0.6 * (1 - progress));
        CGContextFillEllipseInRect(ctx, CGRectMake(pos.x - dot, pos.y - dot, dot * 2, dot * 2));
        CGContextRestoreGState(ctx);
    }

    // 2. The chrome ring draws itself clockwise from the top.
    double ringProgress = EaseInOut(Segment(t, 1.2, 3.6));
    if (ringProgress > 0) {
        CGContextSaveGState(ctx);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineWidth(ctx, s * 0.032);
        NSUInteger segments = 140;
        for (NSUInteger i = 0; i < segments * ringProgress; i++) {
            double a0 = M_PI_2 - (double)i / segments * 2 * M_PI, a1 = M_PI_2 - (double)(i + 1.3) / segments * 2 * M_PI;
            double shade = 0.5 + 0.5 * sin(a0 * 2 + 0.8);         // brushed-metal banding
            CGContextSetRGBStrokeColor(ctx, 0.43 + 0.55 * shade, 0.48 + 0.5 * shade, 0.58 + 0.4 * shade, 1);
            CGContextAddArc(ctx, center.x, center.y, ringR, a0, a1, 1);
            CGContextStrokePath(ctx);
        }
        CGContextRestoreGState(ctx);
    }

    // 3. Tick marks appear around the ring one after another.
    double tickProgress = Segment(t, 2.4, 4.2);
    if (tickProgress > 0) {
        CGContextSaveGState(ctx);
        CGContextSetRGBStrokeColor(ctx, 0.75, 0.84, 0.96, 0.55);
        CGContextSetLineWidth(ctx, s * 0.006);
        for (NSUInteger i = 0; i < 72; i++) {
            double reveal = Clamp01(tickProgress * 72 - i);
            if (reveal <= 0) break;
            double a = M_PI_2 - (double)i / 72 * 2 * M_PI;
            double r1 = ringR * 1.08, r2 = ringR * (1.08 + (i % 6 == 0 ? 0.09 : 0.04) * reveal);
            CGContextMoveToPoint(ctx, center.x + r1 * cos(a), center.y + r1 * sin(a));
            CGContextAddLineToPoint(ctx, center.x + r2 * cos(a), center.y + r2 * sin(a));
        }
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    // 4. Neon orbit arcs sweep in, with a little wobble that settles to the static pose.
    double orbitProgress = EaseInOut(Segment(t, 2.8, 4.8));
    if (orbitProgress > 0) {
        double wobble = (1 - Segment(t, 2.8, 5.6)) * 1.4;
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, s * 0.05, [accent colorWithAlphaComponent:0.9].CGColor);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetRGBStrokeColor(ctx, 0.44, 0.94, 1, 1);
        CGContextSetLineWidth(ctx, s * 0.018);
        double ranges[3][2] = {{20, 100}, {140, 200}, {230, 320}};
        for (int i = 0; i < 3; i++) {
            double from = ranges[i][0] * M_PI / 180 + wobble * (i % 2 ? -1 : 1), to = from + (ranges[i][1] - ranges[i][0]) * M_PI / 180 * orbitProgress;
            CGContextAddArc(ctx, center.x, center.y, ringR * 0.86, from, to, 0);
            CGContextStrokePath(ctx);
        }
        CGContextRestoreGState(ctx);
    }

    // 5. The play triangle ignites: it pops in with overshoot and a glow, then a scan line crosses it.
    double triangleProgress = Segment(t, 3.4, 4.8);
    if (triangleProgress > 0) {
        double pop = EaseOutBack(triangleProgress);
        CGFloat radius = s * 0.26 * pop;
        CGPathRef path = CreateTriangle(center.x + s * 0.02, center.y, radius);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, s * 0.09 * triangleProgress, [NSColor colorWithSRGBRed:0.18 green:0.84 blue:1 alpha:0.95].CGColor);
        CGContextAddPath(ctx, path); CGContextSetRGBFillColor(ctx, 0.18, 0.66, 1, triangleProgress); CGContextFillPath(ctx);
        CGContextRestoreGState(ctx);
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, path); CGContextClip(ctx);
        CGFloat fill[] = {0.91, 0.99, 1, 1,  0.38, 0.84, 1, 1,  0.11, 0.42, 0.88, 1};
        CGFloat locations[] = {0, 0.45, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(rgb, fill, locations, 3);
        CGContextSetAlpha(ctx, triangleProgress);
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(center.x, center.y + radius), CGPointMake(center.x, center.y - radius), 0);
        CGGradientRelease(gradient);
        double scan = Segment(t, 4.6, 5.6);
        if (scan > 0 && scan < 1) {
            CGFloat x = center.x - radius + scan * radius * 2.4;
            CGFloat sweep[] = {1, 1, 1, 0,  1, 1, 1, 0.75,  1, 1, 1, 0};
            CGFloat sweepLocations[] = {0, 0.5, 1};
            CGGradientRef shine = CGGradientCreateWithColorComponents(rgb, sweep, sweepLocations, 3);
            CGContextDrawLinearGradient(ctx, shine, CGPointMake(x - radius * 0.35, center.y), CGPointMake(x + radius * 0.35, center.y), 0);
            CGGradientRelease(shine);
        }
        CGContextRestoreGState(ctx);
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, path); CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.85 * triangleProgress); CGContextSetLineWidth(ctx, s * 0.008); CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
        CGPathRelease(path);
    }

    // 6. Wordmark, letter by letter, then the tagline.
    NSString *word = @"Mac Video Player";
    NSFont *font = [NSFont systemFontOfSize:84 * scale weight:NSFontWeightLight];
    CGFloat kern = 6 * scale, x = 0;
    NSMutableArray<NSAttributedString *> *letters = [NSMutableArray array];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (NSUInteger i = 0; i < word.length; i++) {
        NSAttributedString *letter = [[NSAttributedString alloc] initWithString:[word substringWithRange:NSMakeRange(i, 1)] attributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:[NSColor colorWithCalibratedRed:0.86 green:0.96 blue:1 alpha:1]}];
        [letters addObject:letter]; [offsets addObject:@(x)];
        x += letter.size.width + kern;
    }
    CGFloat total = x - kern, baseline = origin.y + 130 * scale;
    for (NSUInteger i = 0; i < letters.count; i++) {
        double reveal = EaseOutCubic(Segment(t, 4.2 + i * 0.08, 4.8 + i * 0.08));
        if (reveal <= 0) continue;
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, reveal);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 24 * scale * (1 + (1 - reveal) * 2), [accent colorWithAlphaComponent:0.8].CGColor);
        [letters[i] drawAtPoint:NSMakePoint(NSMidX(bounds) - total / 2 + offsets[i].doubleValue, baseline + (1 - reveal) * 26 * scale - font.descender * 0 - 4 * scale)];
        CGContextRestoreGState(ctx);
    }
    double tagline = Segment(t, 5.5, 6.4);
    if (tagline > 0) {
        NSMutableAttributedString *tag = [[NSMutableAttributedString alloc] initWithString:@"P R E M I E R   M A C   M E D I A   P L A Y E R" attributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:20 * scale weight:NSFontWeightLight], NSForegroundColorAttributeName:[NSColor colorWithCalibratedRed:0.62 green:0.74 blue:0.92 alpha:0.9 * tagline], NSKernAttributeName:@(4 * scale)}];
        NSSize tagSize = tag.size;
        [tag drawAtPoint:NSMakePoint(NSMidX(bounds) - tagSize.width / 2, origin.y + 84 * scale - 6 * scale)];
        CGContextSetRGBStrokeColor(ctx, 0.44, 0.94, 1, 0.5 * tagline);
        CGContextSetLineWidth(ctx, 2 * scale);
        CGFloat lineHalf = 320 * scale * tagline;
        CGContextMoveToPoint(ctx, NSMidX(bounds) - lineHalf, origin.y + 60 * scale); CGContextAddLineToPoint(ctx, NSMidX(bounds) + lineHalf, origin.y + 60 * scale);
        CGContextStrokePath(ctx);
    }
    CGColorSpaceRelease(rgb);
}
@end
