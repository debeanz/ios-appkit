// CALayer autoresizing, which macOS has and iOS doesn't.
//
// On the Mac a layer whose superlayer changes size moves and stretches by its
// autoresizingMask (kCALayerWidthSizable and friends), as NSView autoresizing does. Mac code
// relies on it: Chromium builds its page view as root layer > flipped container > page
// picture, creates the container with the root's bounds while the view is still 0x0, and
// lets autoresizing grow it. iOS layers never resize their sublayers, so the container stayed
// 0x0 — and inside a zero-height flipped container the page is drawn entirely above the top
// of the screen, leaving only Chromium's black background. Here a layer's size change
// resizes its sublayers by their masks, as on the Mac.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

// macOS's CAAutoresizingMask values.
enum {
  AKLayerMinXMargin = 1 << 0,
  AKLayerWidthSizable = 1 << 1,
  AKLayerMaxXMargin = 1 << 2,
  AKLayerMinYMargin = 1 << 3,
  AKLayerHeightSizable = 1 << 4,
  AKLayerMaxYMargin = 1 << 5,
};

static IMP gSetBounds, gSetFrame;
static SEL gMaskGetter;
static __thread void *tLayerInSetFrame; // -setFrame: resizes sublayers itself, once

// Spread `delta` evenly over the flexible parts of one axis: the margin before, the size,
// and the margin after (whose share is simply not applied anywhere).
static void resizeAxis(CGFloat *origin, CGFloat *size, CGFloat delta, BOOL minFlex, BOOL sizeFlex, BOOL maxFlex) {
  int parts = minFlex + sizeFlex + maxFlex;
  if (!parts) return;
  CGFloat share = delta / parts;
  if (minFlex) *origin += share;
  if (sizeFlex) *size = MAX(0, *size + share);
}

static void resizeSublayers(CALayer *layer, CGSize old) {
  CGSize now = layer.bounds.size;
  if (CGSizeEqualToSize(old, now)) return;
  CGFloat dx = now.width - old.width, dy = now.height - old.height;
  for (CALayer *sub in layer.sublayers) {
    unsigned int mask = ((unsigned int (*)(id, SEL))objc_msgSend)(sub, gMaskGetter); // CAAutoresizingMask is 32-bit
    if (!mask || !CATransform3DIsIdentity(sub.transform)) continue;
    CGRect f = sub.frame;
    resizeAxis(&f.origin.x, &f.size.width, dx, mask & AKLayerMinXMargin, mask & AKLayerWidthSizable, mask & AKLayerMaxXMargin);
    resizeAxis(&f.origin.y, &f.size.height, dy, mask & AKLayerMinYMargin, mask & AKLayerHeightSizable, mask & AKLayerMaxYMargin);
    sub.frame = f; // cascades: the sublayer's own sublayers follow
  }
}

static void akSetBounds(CALayer *self, SEL cmd, CGRect bounds) {
  CGSize old = self.bounds.size;
  ((void (*)(id, SEL, CGRect))gSetBounds)(self, cmd, bounds);
  if (tLayerInSetFrame != (__bridge void *)self) resizeSublayers(self, old);
}

static void akSetFrame(CALayer *self, SEL cmd, CGRect frame) {
  CGSize old = self.bounds.size;
  void *outer = tLayerInSetFrame;
  tLayerInSetFrame = (__bridge void *)self;
  ((void (*)(id, SEL, CGRect))gSetFrame)(self, cmd, frame);
  tLayerInSetFrame = outer;
  resizeSublayers(self, old);
}

// Where iOS's CALayer has no autoresizingMask property at all, keep the value per layer.
static unsigned int maskGet(id self, SEL cmd) {
  return [objc_getAssociatedObject(self, @selector(autoresizingMask)) unsignedIntValue];
}
static void maskSet(id self, SEL cmd, unsigned int mask) {
  objc_setAssociatedObject(self, @selector(autoresizingMask), @(mask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor)) static void installLayerAutoresizing(void) {
  Class cls = CALayer.class;
  gMaskGetter = NSSelectorFromString(@"autoresizingMask");
  SEL setter = NSSelectorFromString(@"setAutoresizingMask:");
  if (![cls instancesRespondToSelector:gMaskGetter] || ![cls instancesRespondToSelector:setter]) {
    class_replaceMethod(cls, gMaskGetter, (IMP)maskGet, "I@:");
    class_replaceMethod(cls, setter, (IMP)maskSet, "v@:I");
  }
  gSetBounds = method_setImplementation(class_getInstanceMethod(cls, @selector(setBounds:)), (IMP)akSetBounds);
  gSetFrame = method_setImplementation(class_getInstanceMethod(cls, @selector(setFrame:)), (IMP)akSetFrame);
}
