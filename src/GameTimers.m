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

@interface AKGameTimer : NSObject {
@public
  id target;
  SEL selector;
  void (^block)(NSTimer *);
  NSTimeInterval interval;
  CFAbsoluteTime due;
}
@end

@implementation AKGameTimer
- (void)tick:(NSTimer *)timer {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  // The next tick one interval on — or from now, when a whole interval behind (the game was
  // stopped in a debugger or a dialog), rather than firing many to catch up.
  due = now - due > interval ? now + interval : due + interval;
  if (block) block(timer);
  else ((void (*)(id, SEL, id))objc_msgSend)(target, selector, timer);
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
