// CVDisplayLink over CADisplayLink. See CoreVideoMac.h.
#import "AKShimPrivate.h"
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

// Timestamps use microseconds for video time and mach ticks for host time, like macOS.
static const int32_t AKVideoTimeScale = 1000000;

static uint64_t AKHostTimeFromSeconds(CFTimeInterval seconds) {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (uint64_t)(seconds * 1e9 * tb.denom / tb.numer);
}

@interface AKDisplayLink : NSObject
@property (atomic) CVDisplayLinkOutputCallback callback;
@property (atomic) void *userInfo;
@property (atomic) CGDirectDisplayID display;
@property (atomic, readonly) BOOL running;
// References held by callers through Create/Retain/Release. The worker thread keeps its
// own reference while it runs, so the CF retain count can't tell us when callers are done.
@property (atomic) NSInteger callerRefs;
- (void)start;
- (void)stop;
- (CVTimeStamp)timeStampForTime:(CFTimeInterval)t period:(CFTimeInterval)period;
- (NSInteger)framesPerSecond;
@end

@implementation AKDisplayLink {
  NSThread *_thread;
  CADisplayLink *_link; // touched only on _thread
}

- (NSInteger)framesPerSecond { return AKDisplayRefreshRate(AKScreenForDisplayID(self.display)); }

- (CVTimeStamp)timeStampForTime:(CFTimeInterval)t period:(CFTimeInterval)period {
  CVTimeStamp ts = {0};
  ts.version = 0;
  ts.videoTimeScale = AKVideoTimeScale;
  ts.videoTime = (int64_t)(t * AKVideoTimeScale);
  ts.hostTime = AKHostTimeFromSeconds(t);
  ts.rateScalar = 1.0;
  ts.videoRefreshPeriod = (int64_t)(period * AKVideoTimeScale);
  ts.flags = kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid |
             kCVTimeStampRateScalarValid | kCVTimeStampVideoRefreshPeriodValid;
  return ts;
}

// Like macOS, callbacks arrive on a dedicated thread, never the main thread.
- (void)start {
  @synchronized (self) {
    if (_thread) return;
    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
    _thread.name = @"CVDisplayLink";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_thread start];
  }
}

- (void)threadMain {
  @autoreleasepool {
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    float fps = (float)[self framesPerSecond];
    link.preferredFrameRateRange = CAFrameRateRangeMake(fps / 2, fps, fps);
    _link = link;
    [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    while (self.running) {
      @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
    }
    [link invalidate];
    _link = nil;
  }
}

- (void)tick:(CADisplayLink *)link {
  CVDisplayLinkOutputCallback cb = self.callback;
  if (!cb || !self.running) return;
  CFTimeInterval period = link.targetTimestamp - link.timestamp;
  if (period <= 0) period = 1.0 / [self framesPerSecond];
  CVTimeStamp now = [self timeStampForTime:CACurrentMediaTime() period:period];
  CVTimeStamp out = [self timeStampForTime:link.targetTimestamp period:period];
  CVOptionFlags flagsOut = 0;
  cb((__bridge CVDisplayLinkRef)self, &now, &out, 0, &flagsOut, self.userInfo);
}

- (void)stop {
  @synchronized (self) {
    _running = NO; // the thread notices within one run-loop pass and exits
    _thread = nil;
  }
}

- (void)dealloc { _running = NO; }

@end

// The refresh rate every display query answers with: the screen's, at most 60 Hz - or 120 on a
// ProMotion screen while a game runs that was started at 120 (its frame rate limit is 120 or Off:
// GameProfiles.m). An app gets 120 Hz ticks only when its Info.plist asks (LiveContainer's and
// the app's do), and the rate said must be the rate frames go out at (AKOpenGL.m paces to it):
// saying 120 while delivering 60 halved a game that counts refreshes (DELTARUNE ran at half
// speed). 60 otherwise also spares the CPU.
NSInteger AKDisplayRefreshRate(UIScreen *screen) {
  NSInteger fps = screen.maximumFramesPerSecond;
  return fps > 0 ? MIN(fps, AKGameDisplayHz()) : 60;
}

static AKDisplayLink *AKLink(CVDisplayLinkRef ref) { return (__bridge AKDisplayLink *)(void *)ref; }

CVReturn CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID displayID, CVDisplayLinkRef *out) {
  if (!out) return kCVReturnInvalidArgument;
  if (!AKScreenForDisplayID(displayID)) return kCVReturnInvalidDisplay;
  AKDisplayLink *link = [AKDisplayLink new];
  link.display = displayID;
  link.callerRefs = 1;
  *out = (CVDisplayLinkRef)CFBridgingRetain(link);
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *out) {
  return CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), out);
}

CVDisplayLinkRef CVDisplayLinkRetain(CVDisplayLinkRef link) {
  if (!link) return NULL;
  @synchronized (AKLink(link)) { AKLink(link).callerRefs++; }
  CFRetain(link);
  return link;
}

void CVDisplayLinkRelease(CVDisplayLinkRef link) {
  if (!link) return;
  AKDisplayLink *l = AKLink(link);
  BOOL last;
  @synchronized (l) { last = (--l.callerRefs == 0); }
  if (last) [l stop]; // callers are done: let the thread exit and drop its reference
  CFRelease(link);
}

// Links calling a game's code: they stop when it ends (GameTeardown.m).
static NSHashTable<AKDisplayLink *> *gGameLinks;

static void noteGameLink(AKDisplayLink *l) {
  @synchronized (AKDisplayLink.class) {
    if (!gGameLinks) gGameLinks = [NSHashTable weakObjectsHashTable];
    [gGameLinks addObject:l];
  }
}

CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link, CVDisplayLinkOutputCallback callback, void *userInfo) {
  if (!link) return kCVReturnInvalidArgument;
  AKLink(link).callback = callback;
  AKLink(link).userInfo = userInfo;
  if (callback && AKAddressIsInGame((const void *)callback)) noteGameLink(AKLink(link));
  return kCVReturnSuccess;
}

// The block form: kept on the link for as long as it is set, and called through a trampoline.
// A link whose block is a game's code stops with the game like one with a game's callback.
static const char kHandlerKey = 0;

static CVReturn callHandler(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *outputTime, CVOptionFlags flagsIn,
                            CVOptionFlags *flagsOut, void *context) {
  CVDisplayLinkOutputHandler handler = (__bridge CVDisplayLinkOutputHandler)context;
  return handler ? handler(link, now, outputTime, flagsIn, flagsOut) : kCVReturnSuccess;
}

CVReturn CVDisplayLinkSetOutputHandler(CVDisplayLinkRef link, CVDisplayLinkOutputHandler handler) {
  if (!link) return kCVReturnInvalidArgument;
  AKDisplayLink *l = AKLink(link);
  objc_setAssociatedObject(l, &kHandlerKey, handler, OBJC_ASSOCIATION_COPY);
  id kept = objc_getAssociatedObject(l, &kHandlerKey);
  CVReturn r = CVDisplayLinkSetOutputCallback(link, kept ? callHandler : NULL, (__bridge void *)kept);
  // A block's code pointer sits after its isa, flags and reserved words.
  struct { void *isa; int flags, reserved; void *invoke; } *block = (__bridge void *)kept;
  if (block && AKAddressIsInGame(block->invoke)) noteGameLink(l);
  return r;
}

void AKGameDisplayLinksStop(void) {
  NSArray<AKDisplayLink *> *links;
  @synchronized (AKDisplayLink.class) {
    links = gGameLinks.allObjects;
    [gGameLinks removeAllObjects];
  }
  for (AKDisplayLink *l in links) {
    [l stop];
    l.callback = NULL;
    l.userInfo = NULL;
    objc_setAssociatedObject(l, &kHandlerKey, nil, OBJC_ASSOCIATION_COPY);
  }
}

CVReturn CVDisplayLinkStart(CVDisplayLinkRef link) {
  if (!link) return kCVReturnInvalidArgument;
  if (!AKLink(link).callback) return kCVReturnError; // macOS refuses to start without a callback
  [AKLink(link) start];
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkStop(CVDisplayLinkRef link) {
  if (!link) return kCVReturnInvalidArgument;
  [AKLink(link) stop];
  return kCVReturnSuccess;
}

Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef link) { return link && AKLink(link).running; }

// Seconds per refresh of the link's display, as it ticks.
double CVDisplayLinkGetActualOutputVideoRefreshPeriod(CVDisplayLinkRef link) {
  UIScreen *screen = link ? AKScreenForDisplayID(AKLink(link).display) : nil;
  return 1.0 / AKDisplayRefreshRate(screen ?: UIScreen.mainScreen);
}

CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef link) { return link ? AKLink(link).display : kCGNullDirectDisplay; }

CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef link, CGDirectDisplayID displayID) {
  if (!link) return kCVReturnInvalidArgument;
  if (!AKScreenForDisplayID(displayID)) return kCVReturnInvalidDisplay;
  AKLink(link).display = displayID;
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(CVDisplayLinkRef link, void *cglContext, void *cglPixelFormat) {
  return link ? kCVReturnSuccess : kCVReturnInvalidArgument;
}

CVReturn CVDisplayLinkGetCurrentTime(CVDisplayLinkRef link, CVTimeStamp *outTime) {
  if (!link || !outTime) return kCVReturnInvalidArgument;
  AKDisplayLink *l = AKLink(link);
  *outTime = [l timeStampForTime:CACurrentMediaTime() period:1.0 / [l framesPerSecond]];
  return kCVReturnSuccess;
}

CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef link) {
  NSInteger fps = link ? [AKLink(link) framesPerSecond] : 60;
  return (CVTime){ .timeValue = 1, .timeScale = (int32_t)fps, .flags = 0 };
}

#pragma mark OpenGL texture caches (CoreVideoMac.h)

CVReturn CVOpenGLTextureCacheCreate(CFAllocatorRef allocator, CFDictionaryRef cacheAttributes, void *cglContext,
                                    void *cglPixelFormat, CFDictionaryRef textureAttributes, CVOpenGLTextureCacheRef *cacheOut) {
  if (cacheOut) *cacheOut = NULL;
  return kCVReturnUnsupported;
}

CVReturn CVOpenGLTextureCacheCreateTextureFromImage(CFAllocatorRef allocator, CVOpenGLTextureCacheRef cache, CVImageBufferRef image,
                                                    CFDictionaryRef attributes, CVOpenGLTextureRef *textureOut) {
  if (textureOut) *textureOut = NULL;
  return kCVReturnUnsupported;
}

void CVOpenGLTextureCacheFlush(CVOpenGLTextureCacheRef cache, CVOptionFlags options) {}
void CVOpenGLTextureCacheRelease(CVOpenGLTextureCacheRef cache) {}
uint32_t CVOpenGLTextureGetName(CVOpenGLTextureRef texture) { return 0; }
uint32_t CVOpenGLTextureGetTarget(CVOpenGLTextureRef texture) { return 0; }
