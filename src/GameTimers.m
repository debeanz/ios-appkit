// Frame timers for the Mac games Steam starts. A game that steps from a repeating NSTimer
// (GameMaker: -[Mac_RunnerAppDelegate timerFunc:] every frame) and spends each step waiting for
// its next frame time ends a step a little after the timer's next fire date — and a repeating
// timer that's late skips that tick altogether, halving the frame rate (DELTARUNE ran at 15
// frames/s for its 30). A repeating timer made on the game's main thread keeps its own time
// instead: it fires every interval, and a tick that came due during the last one fires as soon as
// that returns.
#import "AKShimPrivate.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <sys/time.h>

@interface AKGameTimer : NSObject {
@public
  id target;
  SEL selector;
  void (^block)(NSTimer *);
  NSTimeInterval interval;
  CFAbsoluteTime due;
  BOOL frameTimer;   // one that steps the game (every 0.1 s or more often)
  int launch;        // the game launch it was made in
}
@end

// The game's frame timers still scheduled, and when one last began and ended a tick. A keeper
// goes when its timer is invalidated (the timer held it), so a game that left its main loop
// has none (MacPrograms.m watches this). Counted per launch: a game ended for Steam can leave
// its timers behind.
static int gFrameTimers, gLaunch;
static CFAbsoluteTime gTickBegan, gTickEnded;

void AKGameFrameTimerState(int *count, CFAbsoluteTime *began, CFAbsoluteTime *ended) {
  *count = __atomic_load_n(&gFrameTimers, __ATOMIC_RELAXED);
  *began = gTickBegan;
  *ended = gTickEnded;
}

@implementation AKGameTimer
- (void)dealloc {
  if (frameTimer && launch == gLaunch) __atomic_sub_fetch(&gFrameTimers, 1, __ATOMIC_RELAXED);
}

- (void)tick:(NSTimer *)timer {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  BOOL frame = frameTimer;   // a timer the game invalidates in its own tick takes this keeper with it
  if (frame) gTickBegan = now;
  // The next tick one interval on — or from now, when a whole interval behind (the game was
  // stopped in a debugger or a dialog), rather than firing many to catch up.
  due = now - due > interval ? now + interval : due + interval;
  if (block) block(timer);
  else ((void (*)(id, SEL, id))objc_msgSend)(target, selector, timer);
  if (frame) gTickEnded = CFAbsoluteTimeGetCurrent();
  if (timer.isValid) timer.fireDate = [NSDate dateWithTimeIntervalSinceReferenceDate:MAX(due, CFAbsoluteTimeGetCurrent())];
}
@end

static IMP gTimerWithTarget, gScheduledWithTarget, gTimerWithBlock, gScheduledWithBlock;

static NSTimer *gameTimer(NSTimeInterval interval, id target, SEL selector, id userInfo, void (^block)(NSTimer *), BOOL schedule) {
  AKGameTimer *keeper = [AKGameTimer new];
  keeper->target = target;
  keeper->selector = selector;
  keeper->block = block;
  keeper->interval = MAX(interval, 0.0001);
  keeper->due = CFAbsoluteTimeGetCurrent() + keeper->interval;
  keeper->frameTimer = interval <= 0.1;
  keeper->launch = gLaunch;
  if (keeper->frameTimer) __atomic_add_fetch(&gFrameTimers, 1, __ATOMIC_RELAXED);
  NSTimer *timer = ((NSTimer * (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))gTimerWithTarget)(
      NSTimer.class, @selector(timerWithTimeInterval:target:selector:userInfo:repeats:), interval, keeper,
      @selector(tick:), userInfo, YES);
  if (schedule) [NSRunLoop.currentRunLoop addTimer:timer forMode:NSDefaultRunLoopMode];
  static int logged;
  if (logged++ < 3)
    fprintf(stderr, "[AppKitShim] game: its timer every %.1f ms fires late rather than skipping a tick\n", interval * 1000);
  return timer;
}

static NSTimer *timerWithTarget(id self, SEL _cmd, NSTimeInterval i, id target, SEL sel, id info, BOOL repeats) {
  if (repeats && AKIsGameThread()) return gameTimer(i, target, sel, info, nil, NO);
  return ((NSTimer * (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))gTimerWithTarget)(self, _cmd, i, target, sel, info, repeats);
}

static NSTimer *scheduledWithTarget(id self, SEL _cmd, NSTimeInterval i, id target, SEL sel, id info, BOOL repeats) {
  if (repeats && AKIsGameThread()) return gameTimer(i, target, sel, info, nil, YES);
  return ((NSTimer * (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))gScheduledWithTarget)(self, _cmd, i, target, sel, info, repeats);
}

static NSTimer *timerWithBlock(id self, SEL _cmd, NSTimeInterval i, BOOL repeats, void (^block)(NSTimer *)) {
  if (repeats && AKIsGameThread()) return gameTimer(i, nil, NULL, nil, block, NO);
  return ((NSTimer * (*)(id, SEL, NSTimeInterval, BOOL, id))gTimerWithBlock)(self, _cmd, i, repeats, block);
}

static NSTimer *scheduledWithBlock(id self, SEL _cmd, NSTimeInterval i, BOOL repeats, void (^block)(NSTimer *)) {
  if (repeats && AKIsGameThread()) return gameTimer(i, nil, NULL, nil, block, YES);
  return ((NSTimer * (*)(id, SEL, NSTimeInterval, BOOL, id))gScheduledWithBlock)(self, _cmd, i, repeats, block);
}

void AKGameInstallTimers(void) {
  gLaunch++;
  __atomic_store_n(&gFrameTimers, 0, __ATOMIC_RELAXED);
  gTickBegan = gTickEnded = 0;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class meta = object_getClass(NSTimer.class);
    gTimerWithTarget = method_setImplementation(
        class_getInstanceMethod(meta, @selector(timerWithTimeInterval:target:selector:userInfo:repeats:)), (IMP)timerWithTarget);
    gScheduledWithTarget = method_setImplementation(
        class_getInstanceMethod(meta, @selector(scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:)),
        (IMP)scheduledWithTarget);
    gTimerWithBlock = method_setImplementation(
        class_getInstanceMethod(meta, @selector(timerWithTimeInterval:repeats:block:)), (IMP)timerWithBlock);
    gScheduledWithBlock = method_setImplementation(
        class_getInstanceMethod(meta, @selector(scheduledTimerWithTimeInterval:repeats:block:)), (IMP)scheduledWithBlock);
  });
}

#pragma mark Busy waits

// A game's frame limiter that spins on the clock until its next frame (GameMaker's
// WaitForVBlank, polling Timing_Time) keeps a core at full speed between frames, which heats a
// phone. When a game's own code reads the clock back to back with next to nothing between — over
// a thousand times in a row — each read waits 0.15 ms asleep first: the loop still sees the time
// pass, to within that, but the core rests. Code doing real work between reads never trips it.
static uint64_t gSpinGap;   // mach ticks: reads closer than this are a spin

static void restIfSpinning(void) {
  static __thread uint64_t last;
  static __thread unsigned streak;
  uint64_t now = mach_absolute_time();
  if (now - last < gSpinGap) {
    if (++streak > 1000) {
      usleep(150);
      now = mach_absolute_time();
    }
  } else {
    streak = 0;
  }
  last = now;
}

// A game Steam already ended for good (it didn't quit when asked) stops at its next clock read.
static uint64_t gameMachAbsoluteTime(void) {
  AKInProcessExitIfEnded();
  restIfSpinning();
  return mach_absolute_time();
}

static int gameGettimeofday(struct timeval *tv, void *tz) {
  AKInProcessExitIfEnded();
  restIfSpinning();
  return gettimeofday(tv, tz);
}

void AKGameBindClock(const struct mach_header *header, intptr_t slide) {
  if (!gSpinGap) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gSpinGap = 2000ull * tb.denom / tb.numer;   // 2 µs
  }
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (strcmp(symbol, "_mach_absolute_time") == 0) return (void *)gameMachAbsoluteTime;
    if (strcmp(symbol, "_gettimeofday") == 0) return (void *)gameGettimeofday;
    return NULL;
  });
}
