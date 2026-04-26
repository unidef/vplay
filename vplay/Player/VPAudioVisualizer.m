#import "VPAudioVisualizer.h"
#import <Accelerate/Accelerate.h>
#import <MediaToolbox/MediaToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>

NSArray<NSString *> *VPVisualizerStyleNames(void) { return @[@"bars", @"mirror", @"ring", @"terrain3d", @"orbit3d"]; }

#define kRows 20

#define kFFTSize 1024
#define kBands 48

#pragma mark - Tap state (shared between the audio thread and the UI)

@interface VPTapState : NSObject {
@public
    float ring[kFFTSize];
    NSUInteger fill;
    float window[kFFTSize];
    float real[kFFTSize / 2], imag[kFFTSize / 2];
    float bands[kBands];
    FFTSetup setup;
    BOOL floatSamples, interleaved;
    UInt32 channels;
    CFAbsoluteTime lastSignal;
}
@end
@implementation VPTapState
- (instancetype)init {
    if ((self = [super init])) {
        setup = vDSP_create_fftsetup(10, kFFTRadix2);
        vDSP_hann_window(window, kFFTSize, vDSP_HANN_NORM);
    }
    return self;
}
- (void)dealloc { if (setup) vDSP_destroy_fftsetup(setup); }

/// Folds a block of mono samples into the band levels with fast attack and slow release.
- (void)consume:(const float *)samples count:(NSUInteger)count stride:(NSUInteger)stride {
    for (NSUInteger i = 0; i < count; i++) {
        ring[fill++] = samples[i * stride];
        if (fill < kFFTSize) continue;
        fill = 0;
        float windowed[kFFTSize];
        vDSP_vmul(ring, 1, window, 1, windowed, 1, kFFTSize);
        DSPSplitComplex split = {real, imag};
        vDSP_ctoz((const DSPComplex *)windowed, 2, &split, 1, kFFTSize / 2);
        vDSP_fft_zrip(setup, &split, 1, 10, kFFTRadix2);
        float magnitudes[kFFTSize / 2];
        vDSP_zvabs(&split, 1, magnitudes, 1, kFFTSize / 2);
        // Logarithmic band edges from ~40 Hz to ~16 kHz (at 44.1/48 kHz sample rates).
        for (NSUInteger b = 0; b < kBands; b++) {
            double lo = 2 * pow(256.0 / 2, (double)b / kBands), hi = 2 * pow(256.0 / 2, (double)(b + 1) / kBands);
            NSUInteger from = (NSUInteger)lo, to = MAX(from + 1, (NSUInteger)hi);
            float peak = 0;
            for (NSUInteger k = from; k < to && k < kFFTSize / 2; k++) peak = MAX(peak, magnitudes[k]);
            float db = 20 * log10f(MAX(peak / (kFFTSize / 4.0f), 1e-6f));    // dBFS
            float level = MIN(1, MAX(0, (db + 70) / 70));
            bands[b] = level > bands[b] ? level : bands[b] * 0.86f + level * 0.14f;
        }
        lastSignal = CFAbsoluteTimeGetCurrent();
    }
}
@end

#pragma mark - MTAudioProcessingTap callbacks

static void TapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) { *tapStorageOut = clientInfo; }
static void TapFinalize(MTAudioProcessingTapRef tap) { CFBridgingRelease(MTAudioProcessingTapGetStorage(tap)); }
static void TapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    VPTapState *state = (__bridge VPTapState *)MTAudioProcessingTapGetStorage(tap);
    state->floatSamples = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format->mBitsPerChannel == 32;
    state->interleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    state->channels = format->mChannelsPerFrame;
}
static void TapUnprepare(MTAudioProcessingTapRef tap) {}
static void TapProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                       AudioBufferList *buffers, CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    if (MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, NULL, framesOut) != noErr) return;
    VPTapState *state = (__bridge VPTapState *)MTAudioProcessingTapGetStorage(tap);
    if (!state->floatSamples || buffers->mNumberBuffers == 0 || !buffers->mBuffers[0].mData) return;
    NSUInteger stride = state->interleaved ? MAX(1u, state->channels) : 1;
    [state consume:(const float *)buffers->mBuffers[0].mData count:(NSUInteger)*framesOut stride:stride];
}

#pragma mark - Analyzer

@interface VPAudioAnalyzer ()
@property (nonatomic, strong) VPTapState *state;
@property (nonatomic, weak) AVPlayerItem *item;
@property (nonatomic) NSUInteger generation;
@end

@implementation VPAudioAnalyzer
- (instancetype)init { if ((self = [super init])) _state = [VPTapState new]; return self; }
- (NSUInteger)bandCount { return kBands; }
- (BOOL)hasSignal { return CFAbsoluteTimeGetCurrent() - self.state->lastSignal < 0.5; }

- (void)attachToItem:(AVPlayerItem *)item {
    [self detach];
    self.item = item;
    AVURLAsset *asset = [item.asset isKindOfClass:AVURLAsset.class] ? (AVURLAsset *)item.asset : nil;
    if (!asset || !asset.URL.isFileURL) return;     // taps do not work with HTTP Live Streaming
    NSUInteger generation = ++self.generation;
    __weak typeof(self) weakSelf = self;
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VPAudioAnalyzer *analyzer = weakSelf;
            if (!analyzer || generation != analyzer.generation || analyzer.item != item || !tracks.count) return;
            MTAudioProcessingTapCallbacks callbacks = {
                .version = kMTAudioProcessingTapCallbacksVersion_0,
                .clientInfo = (__bridge_retained void *)analyzer.state,
                .init = TapInit, .finalize = TapFinalize, .prepare = TapPrepare, .unprepare = TapUnprepare, .process = TapProcess};
            MTAudioProcessingTapRef tap = NULL;
            if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) != noErr || !tap) {
                CFBridgingRelease(callbacks.clientInfo); return;
            }
            AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
            parameters.audioTapProcessor = tap;
            CFRelease(tap);
            AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
            mix.inputParameters = @[parameters];
            item.audioMix = mix;
        });
    }];
}

- (void)detach {
    self.generation++;
    self.item.audioMix = nil;
    self.item = nil;
    memset(self.state->bands, 0, sizeof(self.state->bands));
    self.state->lastSignal = 0;
}

- (void)copyLevels:(float *)levels {
    memcpy(levels, self.state->bands, sizeof(float) * kBands);
}
@end

#pragma mark - View

@interface VPVisualizerView ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) SCNView *sceneView;
@property (nonatomic, strong) SCNNode *sceneRoot;
@property (nonatomic, strong) SCNNode *coreNode;
@property (nonatomic, strong) NSArray<SCNNode *> *columnNodes;      // kRows × kBands for the terrain, kBands for the orbit
@property (nonatomic) VPVisualizerStyle builtStyle;
@end

@implementation VPVisualizerView {
    float _levels[kBands];
    float _peakCaps[kBands];
    float _history[kRows][kBands];
    double _spin;
}

- (void)setAccentColor:(NSColor *)color {
    _accentColor = [color copy];
    if (self.columnNodes) { self.columnNodes = nil; if ([self is3D]) [self buildSceneIfNeeded]; }   // rebuild with the new colors
}

- (BOOL)is3D { return self.style == VPVisualizerStyleTerrain3D || self.style == VPVisualizerStyleOrbit3D; }

- (void)setStyle:(VPVisualizerStyle)style {
    _style = style;
    BOOL threeD = [self is3D];
    if (threeD) [self buildSceneIfNeeded];
    self.sceneView.hidden = !threeD;
    self.sceneView.playing = threeD;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    self.sceneView.frame = self.bounds;
}

- (NSColor *)bandColor:(NSUInteger)band {
    NSColor *accent = [self.accentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: self.accentColor;
    CGFloat h, s, b, a;
    [accent getHue:&h saturation:&s brightness:&b alpha:&a];
    // Sweep the hue a little across the spectrum so the 3D scenes read as a gradient.
    return [NSColor colorWithHue:fmod(h + 0.18 * band / kBands + 1, 1) saturation:MAX(0.45, s) brightness:MAX(0.8, b) alpha:1];
}

- (void)buildSceneIfNeeded {
    if (self.sceneView && self.builtStyle == self.style && self.columnNodes) return;
    if (!self.sceneView) {
        self.sceneView = [[SCNView alloc] initWithFrame:self.bounds];
        self.sceneView.backgroundColor = NSColor.clearColor;
        self.sceneView.antialiasingMode = SCNAntialiasingModeMultisampling4X;
        self.sceneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:self.sceneView];
    }
    SCNScene *scene = [SCNScene scene];
    self.sceneRoot = [SCNNode node];
    [scene.rootNode addChildNode:self.sceneRoot];
    SCNNode *cameraNode = [SCNNode node];
    cameraNode.camera = [SCNCamera camera];
    cameraNode.camera.wantsHDR = YES;
    cameraNode.camera.bloomIntensity = 1.1; cameraNode.camera.bloomThreshold = 0.55; cameraNode.camera.bloomBlurRadius = 8;
    cameraNode.camera.zFar = 200; cameraNode.camera.fieldOfView = 50;
    SCNNode *light = [SCNNode node];
    light.light = [SCNLight light]; light.light.type = SCNLightTypeOmni; light.light.intensity = 900;
    light.position = SCNVector3Make(0, 10, 12);
    SCNNode *ambient = [SCNNode node];
    ambient.light = [SCNLight light]; ambient.light.type = SCNLightTypeAmbient; ambient.light.intensity = 250;
    [scene.rootNode addChildNode:cameraNode]; [scene.rootNode addChildNode:light]; [scene.rootNode addChildNode:ambient];

    NSMutableArray *nodes = [NSMutableArray array];
    if (self.style == VPVisualizerStyleTerrain3D) {
        cameraNode.position = SCNVector3Make(0, 7.5, 15); cameraNode.eulerAngles = SCNVector3Make(-0.42, 0, 0);
        for (NSUInteger row = 0; row < kRows; row++) for (NSUInteger band = 0; band < kBands; band++) {
            SCNBox *box = [SCNBox boxWithWidth:0.26 height:1 length:0.26 chamferRadius:0.03];
            SCNMaterial *material = [SCNMaterial material];
            NSColor *color = [self bandColor:band];
            material.diffuse.contents = [color colorWithAlphaComponent:1 - 0.7 * row / kRows];
            material.emission.contents = [color colorWithAlphaComponent:0.35 * (1 - (CGFloat)row / kRows)];
            box.materials = @[material];
            SCNNode *node = [SCNNode nodeWithGeometry:box];
            node.position = SCNVector3Make(((CGFloat)band - kBands / 2.0) * 0.32, 0.01, -(CGFloat)row * 0.5 + 2);
            node.scale = SCNVector3Make(1, 0.02, 1);
            [self.sceneRoot addChildNode:node]; [nodes addObject:node];
        }
    } else {
        cameraNode.position = SCNVector3Make(0, 5, 13); cameraNode.eulerAngles = SCNVector3Make(-0.3, 0, 0);
        for (NSUInteger band = 0; band < kBands; band++) {
            SCNBox *box = [SCNBox boxWithWidth:0.36 height:1 length:0.36 chamferRadius:0.05];
            SCNMaterial *material = [SCNMaterial material];
            NSColor *color = [self bandColor:band];
            material.diffuse.contents = color; material.emission.contents = [color colorWithAlphaComponent:0.5];
            box.materials = @[material];
            SCNNode *node = [SCNNode nodeWithGeometry:box];
            CGFloat angle = (CGFloat)band / kBands * 2 * M_PI;
            node.position = SCNVector3Make(cos(angle) * 4.2, 0, sin(angle) * 4.2);
            node.eulerAngles = SCNVector3Make(0, -angle, 0);
            node.scale = SCNVector3Make(1, 0.05, 1);
            [self.sceneRoot addChildNode:node]; [nodes addObject:node];
        }
        SCNSphere *sphere = [SCNSphere sphereWithRadius:1.1];
        SCNMaterial *core = [SCNMaterial material];
        core.diffuse.contents = self.accentColor; core.emission.contents = self.accentColor; core.transparency = 0.85;
        sphere.materials = @[core];
        self.coreNode = [SCNNode nodeWithGeometry:sphere];
        [self.sceneRoot addChildNode:self.coreNode];
    }
    self.columnNodes = nodes;
    self.builtStyle = self.style;
    self.sceneView.scene = scene;
    self.sceneView.playing = YES;
}

/// Pushes the current levels into the 3D scene.
- (void)updateScene {
    if (!self.columnNodes.count) return;
    _spin += 0.004;
    if (self.style == VPVisualizerStyleTerrain3D) {
        memmove(_history[1], _history[0], sizeof(float) * kBands * (kRows - 1));
        memcpy(_history[0], _levels, sizeof(float) * kBands);
        self.sceneRoot.eulerAngles = SCNVector3Make(0, sin(_spin * 0.8) * 0.35, 0);
        for (NSUInteger row = 0; row < kRows; row++) for (NSUInteger band = 0; band < kBands; band++) {
            CGFloat height = MAX(0.03, _history[row][band] * 6.0);
            SCNNode *node = self.columnNodes[row * kBands + band];
            node.scale = SCNVector3Make(1, height, 1);
            node.position = SCNVector3Make(node.position.x, height / 2, node.position.z);
        }
    } else {
        self.sceneRoot.eulerAngles = SCNVector3Make(0, _spin * 2, 0);
        float bass = 0;
        for (NSUInteger band = 0; band < 8; band++) bass += _levels[band] / 8;
        for (NSUInteger band = 0; band < kBands; band++) {
            CGFloat height = MAX(0.05, _levels[band] * 5.0);
            SCNNode *node = self.columnNodes[band];
            node.scale = SCNVector3Make(1, height, 1);
            node.position = SCNVector3Make(node.position.x, height / 2 - 0.0, node.position.z);
        }
        CGFloat pulse = 0.8 + bass * 1.6;
        self.coreNode.scale = SCNVector3Make(pulse, pulse, pulse);
    }
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _accentColor = [NSColor colorWithSRGBRed:0.45 green:0.85 blue:1 alpha:1];
        self.wantsLayer = YES;
    }
    return self;
}
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }   // never intercept clicks meant for the video or controls

- (void)setAnimating:(BOOL)animating {
    _animating = animating;
    [self.timer invalidate]; self.timer = nil;
    if (!animating) return;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        VPVisualizerView *view = weakSelf;
        if (!view || view.hidden || !view.window.isVisible) return;
        [view step];
        if ([view is3D]) [view updateScene]; else view.needsDisplay = YES;
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)dealloc { [self.timer invalidate]; }

- (void)step {
    if (self.analyzer.hasSignal) { [self.analyzer copyLevels:_levels]; }
    else {
        // No samples (paused, silent, or streamed media): breathe gently so the view still feels alive.
        double t = CACurrentMediaTime();
        for (NSUInteger i = 0; i < kBands; i++) {
            float target = 0.10f + 0.06f * (float)(sin(t * 1.6 + i * 0.35) + 1);
            _levels[i] = _levels[i] * 0.9f + target * 0.1f;
        }
    }
    for (NSUInteger i = 0; i < kBands; i++) _peakCaps[i] = MAX(_levels[i], _peakCaps[i] - 0.006f);
}

- (void)drawRect:(NSRect)dirty {
    if ([self is3D]) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    NSRect bounds = self.bounds;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    NSColor *accent = [self.accentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: self.accentColor;
    CGFloat r = accent.redComponent, g = accent.greenComponent, b = accent.blueComponent;
    CGFloat colors[] = {r, g, b, 0.95, 0.25, 0.45, 1, 0.75};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(rgb, colors, NULL, 2);

    if (self.style == VPVisualizerStyleRing) {
        CGPoint c = CGPointMake(NSMidX(bounds), NSMidY(bounds));
        CGFloat inner = MIN(bounds.size.width, bounds.size.height) * 0.22, span = MIN(bounds.size.width, bounds.size.height) * 0.22;
        CGContextSetLineWidth(ctx, MAX(2, inner * 0.07)); CGContextSetLineCap(ctx, kCGLineCapRound);
        for (NSUInteger i = 0; i < kBands; i++) {
            CGFloat angle = (CGFloat)i / kBands * 2 * M_PI - M_PI_2, length = 4 + _levels[i] * span;
            CGContextSetRGBStrokeColor(ctx, r, g, b, 0.45 + _levels[i] * 0.55);
            CGContextMoveToPoint(ctx, c.x + cos(angle) * inner, c.y + sin(angle) * inner);
            CGContextAddLineToPoint(ctx, c.x + cos(angle) * (inner + length), c.y + sin(angle) * (inner + length));
            CGContextStrokePath(ctx);
        }
    } else {
        CGFloat slot = bounds.size.width / kBands, barWidth = MAX(2, slot * 0.68);
        BOOL mirror = self.style == VPVisualizerStyleMirror;
        CGFloat baseline = mirror ? NSMidY(bounds) : 0, room = mirror ? bounds.size.height / 2 : bounds.size.height;
        for (NSUInteger i = 0; i < kBands; i++) {
            CGFloat height = MAX(2, _levels[i] * room * 0.92), x = i * slot + (slot - barWidth) / 2;
            NSRect up = NSMakeRect(x, baseline, barWidth, height);
            CGContextSaveGState(ctx);
            CGPathRef upPath = CGPathCreateWithRoundedRect(up, barWidth / 2, barWidth / 2, NULL);
            CGContextAddPath(ctx, upPath); CGPathRelease(upPath);
            CGContextClip(ctx);
            CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, baseline), CGPointMake(0, baseline + height), 0);
            CGContextRestoreGState(ctx);
            CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.8);
            CGContextFillRect(ctx, CGRectMake(x, baseline + MAX(height, _peakCaps[i] * room * 0.92) + 3, barWidth, 2));
            if (mirror) {
                NSRect down = NSMakeRect(x, baseline - height, barWidth, height);
                CGContextSaveGState(ctx);
                CGContextSetAlpha(ctx, 0.45);
                CGPathRef downPath = CGPathCreateWithRoundedRect(down, barWidth / 2, barWidth / 2, NULL);
                CGContextAddPath(ctx, downPath); CGPathRelease(downPath);
                CGContextClip(ctx);
                CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, baseline), CGPointMake(0, baseline - height), 0);
                CGContextRestoreGState(ctx);
            }
        }
    }
    CGGradientRelease(gradient); CGColorSpaceRelease(rgb);
}
@end
