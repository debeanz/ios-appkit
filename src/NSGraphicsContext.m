#import "AKShimPrivate.h"
#import "AppKitShim/NSGraphics.h"

// A thread-local stack of graphics contexts, as AppKit keeps.
static NSString *const AKContextStackKey = @"AKGraphicsContextStack";
static NSMutableArray<NSGraphicsContext *> *AKContextStack(void) {
  NSMutableDictionary *tls = NSThread.currentThread.threadDictionary;
  NSMutableArray *stack = tls[AKContextStackKey];
  if (!stack) tls[AKContextStackKey] = stack = [NSMutableArray array];
  return stack;
}

@implementation NSGraphicsContext {
  CGContextRef _cg;
  BOOL _flipped;
}

+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)ctx flipped:(BOOL)flipped {
  NSGraphicsContext *gc = [NSGraphicsContext new];
  gc->_cg = CGContextRetain(ctx);
  gc->_flipped = flipped;
  gc->_shouldAntialias = YES;
  return gc;
}

- (void)dealloc { if (_cg) CGContextRelease(_cg); }

// The current context: the top of the stack, or a context wrapping the UIKit context that a
// UIKit draw has made current (so AppKit drawing code works inside -drawRect:).
+ (NSGraphicsContext *)currentContext {
  NSGraphicsContext *top = AKContextStack().lastObject;
  if (top) return top;
  CGContextRef ui = UIGraphicsGetCurrentContext();
  return ui ? [self graphicsContextWithCGContext:ui flipped:YES] : nil;
}

+ (void)setCurrentContext:(NSGraphicsContext *)context {
  NSMutableArray *stack = AKContextStack();
  if (stack.count) [stack removeLastObject];
  if (context) [stack addObject:context];
}

- (CGContextRef)CGContext { return _cg; }
- (BOOL)isFlipped { return _flipped; }

+ (void)saveGraphicsState  { [self.currentContext saveGraphicsState]; }
+ (void)restoreGraphicsState { [self.currentContext restoreGraphicsState]; }
- (void)saveGraphicsState    { if (_cg) CGContextSaveGState(_cg); }
- (void)restoreGraphicsState { if (_cg) CGContextRestoreGState(_cg); }
- (void)flushGraphics        { if (_cg) CGContextFlush(_cg); }

- (void)setShouldAntialias:(BOOL)shouldAntialias {
  _shouldAntialias = shouldAntialias;
  if (_cg) CGContextSetShouldAntialias(_cg, shouldAntialias);
}

@end

@implementation NSColorSpace {
  CGColorSpaceRef _cg;
}

- (instancetype)initWithCGColorSpace:(CGColorSpaceRef)cg {
  if ((self = [super init])) _cg = CGColorSpaceRetain(cg);
  return self;
}

- (void)dealloc { if (_cg) CGColorSpaceRelease(_cg); }

static NSColorSpace *AKColorSpaceNamed(CFStringRef name) {
  CGColorSpaceRef cg = CGColorSpaceCreateWithName(name);
  NSColorSpace *space = [[NSColorSpace alloc] initWithCGColorSpace:cg];
  CGColorSpaceRelease(cg);
  return space;
}

+ (NSColorSpace *)sRGBColorSpace     { static NSColorSpace *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = AKColorSpaceNamed(kCGColorSpaceSRGB); }); return s; }
+ (NSColorSpace *)genericRGBColorSpace { return self.sRGBColorSpace; }
+ (NSColorSpace *)deviceRGBColorSpace  { return self.sRGBColorSpace; }
+ (NSColorSpace *)displayP3ColorSpace { static NSColorSpace *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = AKColorSpaceNamed(kCGColorSpaceDisplayP3); }); return s; }
+ (NSColorSpace *)genericGrayColorSpace { static NSColorSpace *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = AKColorSpaceNamed(kCGColorSpaceLinearGray); }); return s; }

- (CGColorSpaceRef)CGColorSpace { return _cg; }

- (NSColorSpaceModel)colorSpaceModel {
  switch (CGColorSpaceGetModel(_cg)) {
    case kCGColorSpaceModelMonochrome: return NSColorSpaceModelGray;
    case kCGColorSpaceModelRGB: return NSColorSpaceModelRGB;
    case kCGColorSpaceModelCMYK: return NSColorSpaceModelCMYK;
    case kCGColorSpaceModelLab: return NSColorSpaceModelLAB;
    case kCGColorSpaceModelIndexed: return NSColorSpaceModelIndexed;
    default: return NSColorSpaceModelUnknown;
  }
}

- (NSInteger)numberOfColorComponents { return CGColorSpaceGetNumberOfComponents(_cg); }
- (NSString *)localizedName { return (__bridge_transfer NSString *)CGColorSpaceCopyName(_cg) ?: @"Color Space"; }

@end
