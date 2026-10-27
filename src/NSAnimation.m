#import "AKShimPrivate.h"
#import "AppKitShim/NSAnimation.h"

@implementation NSAnimationContext {
  void (^_completionHandler)(void);
}

// AppKit keeps a stack of contexts; the current one is the top of the stack, and the
// outermost maps to a CATransaction so implicit animations group as they do on the Mac.
static NSMutableArray<NSAnimationContext *> *AKContextStack(void) {
  static NSMutableArray *stack;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ stack = [NSMutableArray array]; });
  return stack;
}

- (instancetype)init {
  if ((self = [super init])) { _duration = 0.25; _allowsImplicitAnimation = YES; }
  return self;
}

+ (NSAnimationContext *)currentContext {
  NSAnimationContext *top = AKContextStack().lastObject;
  if (!top) { top = [NSAnimationContext new]; [AKContextStack() addObject:top]; }
  return top;
}

+ (void)beginGrouping {
  [CATransaction begin];
  [AKContextStack() addObject:[NSAnimationContext new]];
}

+ (void)endGrouping {
  NSAnimationContext *ctx = AKContextStack().lastObject;
  if (ctx) [AKContextStack() removeLastObject];
  void (^completion)(void) = ctx.completionHandler;
  if (completion) [CATransaction setCompletionBlock:completion];
  [CATransaction commit];
}

- (void)setDuration:(NSTimeInterval)duration {
  _duration = duration;
  [CATransaction setAnimationDuration:duration];
}

- (void)setTimingFunction:(CAMediaTimingFunction *)timingFunction {
  _timingFunction = timingFunction;
  [CATransaction setAnimationTimingFunction:timingFunction];
}

- (void)setCompletionHandler:(void (^)(void))completionHandler { _completionHandler = [completionHandler copy]; }
- (void (^)(void))completionHandler { return _completionHandler; }

+ (void)runAnimationGroup:(void (^)(NSAnimationContext *))changes completionHandler:(void (^)(void))completionHandler {
  [self beginGrouping];
  NSAnimationContext *ctx = self.currentContext;
  if (completionHandler) ctx.completionHandler = completionHandler;
  if (changes) changes(ctx);
  [self endGrouping];
}

+ (void)runAnimationGroup:(void (^)(NSAnimationContext *))changes { [self runAnimationGroup:changes completionHandler:nil]; }

@end

@implementation NSAnimation {
  CADisplayLink *_link;
  CFTimeInterval _startTime;
}

- (instancetype)initWithDuration:(NSTimeInterval)duration animationCurve:(NSAnimationCurve)curve {
  if ((self = [super init])) {
    _duration = duration;
    _animationCurve = curve;
    _frameRate = 60;
  }
  return self;
}

- (BOOL)isAnimating { return _link != nil; }

- (void)startAnimation {
  if (_link) return;
  if ([_delegate respondsToSelector:@selector(animationShouldStart:)] && ![_delegate animationShouldStart:self]) return;
  if (_duration <= 0) { _currentProgress = 1.0; [self _finish:YES]; return; }
  _startTime = CACurrentMediaTime();
  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(_tick:)];
  if (_frameRate > 0) _link.preferredFramesPerSecond = (NSInteger)_frameRate;
  [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)_tick:(CADisplayLink *)link {
  NSAnimationProgress p = (NSAnimationProgress)MIN(1.0, (CACurrentMediaTime() - _startTime) / _duration);
  self.currentProgress = p; // the setter is the subclass override point
  if (p >= 1.0) [self _finish:YES];
}

- (void)stopAnimation { [self _finish:NO]; }

- (void)_finish:(BOOL)reachedEnd {
  [_link invalidate];
  _link = nil;
  if (reachedEnd && [_delegate respondsToSelector:@selector(animationDidEnd:)]) [_delegate animationDidEnd:self];
  else if (!reachedEnd && [_delegate respondsToSelector:@selector(animationDidStop:)]) [_delegate animationDidStop:self];
}

// currentValue applies the curve (or the delegate's override) to currentProgress.
- (float)currentValue {
  float p = _currentProgress;
  if ([_delegate respondsToSelector:@selector(animation:valueForProgress:)]) return [_delegate animation:self valueForProgress:p];
  switch (_animationCurve) {
    case NSAnimationEaseIn:  return p * p;
    case NSAnimationEaseOut: return p * (2 - p);
    case NSAnimationLinear:  return p;
    case NSAnimationEaseInOut:
    default: return p < 0.5 ? 2 * p * p : -1 + (4 - 2 * p) * p;
  }
}

@end
