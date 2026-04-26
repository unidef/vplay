#import "VPEffectRenderer.h"
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

@interface VPEffectRenderer ()
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, strong) AVPlayerItem *item;
@property (nonatomic, strong) AVPlayerItemVideoOutput *output;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong) CIImage *lastSource;
@property (nonatomic) BOOL dirty;
@property (nonatomic) CVPixelBufferRef destination;     // current render target (retained)
@property (nonatomic) size_t destinationWidth, destinationHeight;
@property (nonatomic) NSUInteger drawCount;
@property (nonatomic) CVPixelBufferPoolRef pool;
@property (nonatomic) size_t poolWidth, poolHeight;
@end

@implementation VPEffectRenderer

- (instancetype)init {
    if ((self = [super init])) {
        _layer = [CALayer layer];
        _layer.contentsGravity = kCAGravityResizeAspect;
        _layer.backgroundColor = NSColor.blackColor.CGColor;
        _layer.hidden = YES;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device) {
            _context = [CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates:@NO}];
        } else {
            _context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
        }
    }
    return self;
}

- (void)dealloc { [self stop]; }
- (BOOL)running { return self.timer != nil; }

- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || CFGetTypeID(pixelBuffer) != CVPixelBufferGetTypeID()) return;
    self.layer.hidden = NO;
    
    // If no processor is active and buffer has a direct RGB IOSurface, display directly on layer.
    // Multi-planar YCbCr formats (e.g. '420v', '420f', NV12, P010) cannot be assigned directly
    // to CALayer.contents without RGB color conversion or they will produce washed-out white/ghost frames.
    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    BOOL isDirectRGB = (format == kCVPixelFormatType_32BGRA ||
                        format == kCVPixelFormatType_32ARGB ||
                        format == kCVPixelFormatType_32RGBA ||
                        format == kCVPixelFormatType_32ABGR);
    IOSurfaceRef sourceSurface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!self.processor && sourceSurface != NULL && isDirectRGB) {
        self.lastSource = [CIImage imageWithIOSurface:sourceSurface];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.layer.hidden = NO;
        self.layer.contents = (__bridge id)sourceSurface;
        [CATransaction commit];
        return;
    }
    
    CIImage *source = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!source) return;
    self.lastSource = source;
    
    CIImage *processed = self.processor ? self.processor(source) : source;
    if (!processed) processed = source;
    CGRect extent = processed.extent;
    size_t width = (size_t)ceil(extent.size.width), height = (size_t)ceil(extent.size.height);
    if (width == 0 || height == 0 || width > 16384 || height > 16384) return;
    
    if (!_pool || _poolWidth != width || _poolHeight != height) {
        if (_pool) {
            CVPixelBufferPoolRelease(_pool);
            _pool = NULL;
        }
        NSDictionary *poolAttributes = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @(6) };
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES
        };
        CVReturn poolRet = CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes, (__bridge CFDictionaryRef)pixelAttributes, &_pool);
        if (poolRet == kCVReturnSuccess) {
            _poolWidth = width;
            _poolHeight = height;
        } else {
            _pool = NULL;
        }
    }
    
    CVPixelBufferRef target = NULL;
    if (_pool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &target);
    }
    if (!target) {
        NSDictionary *attributes = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &target) != kCVReturnSuccess) return;
    }
    
    [self.context render:[processed imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)] toCVPixelBuffer:target];
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(target);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.hidden = NO;
    self.layer.contents = (__bridge id)surface;
    [CATransaction commit];
    CVPixelBufferRelease(target);
}

- (void)startWithItem:(AVPlayerItem *)item {
    [self stop];
    self.item = item;
    self.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}}];
    [item addOutput:self.output];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    self.layer.hidden = NO;
}

- (void)stop {
    [self.timer invalidate]; self.timer = nil;
    if (self.output) [self.item removeOutput:self.output];
    self.output = nil; self.item = nil; self.lastSource = nil;
    if (self.destination) { CVPixelBufferRelease(self.destination); self.destination = NULL; }
    if (self.pool) { CVPixelBufferPoolRelease(self.pool); self.pool = NULL; }
    self.poolWidth = 0; self.poolHeight = 0;
    self.layer.contents = nil;
    self.layer.hidden = YES;
}

- (void)setNeedsRedraw { self.dirty = YES; }

- (CIImage *)currentImage {
    id contents = self.layer.contents;
    if (!contents || CFGetTypeID((__bridge CFTypeRef)contents) != IOSurfaceGetTypeID()) return nil;
    return [CIImage imageWithIOSurface:(__bridge IOSurfaceRef)contents];
}

- (CIImage *)currentSourceImage {
    return self.lastSource;
}

- (void)tick {
    if (!self.output || !self.processor) return;
    CMTime itemTime = [self.output itemTimeForHostTime:CACurrentMediaTime()];
    BOOL fresh = [self.output hasNewPixelBufferForItemTime:itemTime];
    if (!fresh && !self.dirty) return;
    if (fresh) {
        CVPixelBufferRef buffer = [self.output copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
        if (buffer) { self.lastSource = [CIImage imageWithCVPixelBuffer:buffer]; CVPixelBufferRelease(buffer); }
    }
    self.dirty = NO;
    if (!self.lastSource) return;
    CIImage *processed = self.processor(self.lastSource);
    if (!processed) return;
    CGRect extent = processed.extent;
    size_t width = (size_t)ceil(extent.size.width), height = (size_t)ceil(extent.size.height);
    if (width == 0 || height == 0 || width > 16384 || height > 16384) return;

    // Render into a fresh IOSurface-backed buffer each frame so the layer never reads one that is being drawn.
    CVPixelBufferRef target = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &target) != kCVReturnSuccess) return;
    [self.context render:[processed imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)] toCVPixelBuffer:target];
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(target);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)surface;
    [CATransaction commit];
    CVPixelBufferRelease(target);   // the layer keeps the surface alive
}
@end
