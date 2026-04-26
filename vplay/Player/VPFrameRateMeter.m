#import "VPFrameRateMeter.h"
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

@interface VPFrameRateMeter ()
@property (nonatomic, strong) AVPlayerItem *item;
@property (nonatomic, strong) AVPlayerItemVideoOutput *output;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSUInteger frames;
@property (nonatomic) CFTimeInterval windowStart;
@property (nonatomic) CMTime lastFrameTime;
@end

@implementation VPFrameRateMeter

- (void)dealloc { [self stop]; }

- (void)startWithItem:(AVPlayerItem *)item {
    [self stop];
    self.item = item;
    // A tiny output keeps the per-frame copy cheap; only the frame cadence matters here.
    self.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @64, (id)kCVPixelBufferHeightKey: @36}];
    [item addOutput:self.output];
    self.frames = 0; self.windowStart = CACurrentMediaTime(); self.lastFrameTime = kCMTimeInvalid;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) { [weakSelf poll]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.timer invalidate]; self.timer = nil;
    if (self.output) [self.item removeOutput:self.output];
    self.output = nil; self.item = nil;
}

- (void)poll {
    CMTime itemTime = [self.output itemTimeForHostTime:CACurrentMediaTime()];
    if ([self.output hasNewPixelBufferForItemTime:itemTime]) {
        CMTime displayTime;
        CVPixelBufferRef buffer = [self.output copyPixelBufferForItemTime:itemTime itemTimeForDisplay:&displayTime];
        if (buffer) {
            CVPixelBufferRelease(buffer);
            if (!CMTIME_IS_VALID(self.lastFrameTime) || CMTimeCompare(displayTime, self.lastFrameTime) != 0) self.frames++;
            self.lastFrameTime = displayTime;
        }
    }
    CFTimeInterval now = CACurrentMediaTime(), elapsed = now - self.windowStart;
    if (elapsed >= 0.5) {
        double fps = self.frames / elapsed;
        self.frames = 0; self.windowStart = now;
        if (self.onUpdate) self.onUpdate(fps);
    }
}
@end
