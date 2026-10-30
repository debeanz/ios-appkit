// NSOpenGLPixelFormat, NSOpenGLContext and NSOpenGLView for the Mac games Steam starts, over the
// CGL functions of AKOpenGL.framework (opengl/AKOpenGL.m: Mesa's OpenGL with the Zink driver on
// MoltenVK, native code throughout). The framework is loaded the first time a game asks for
// OpenGL; outside a game no pixel format is available, as before (Steam's interface doesn't
// draw with OpenGL).
#import "AKShimPrivate.h"
#import "AppKitShim/OpenGLMac.h"
#import <dlfcn.h>
#import <objc/runtime.h>

static struct {
  CGLError (*choose)(const int32_t *, CGLPixelFormatObj *, AKGLint *);
  CGLPixelFormatObj (*retainFormat)(CGLPixelFormatObj);
  void (*releaseFormat)(CGLPixelFormatObj);
  CGLError (*describe)(CGLPixelFormatObj, AKGLint, int32_t, AKGLint *);
  CGLError (*create)(CGLPixelFormatObj, CGLContextObj, CGLContextObj *);
  CGLContextObj (*retainContext)(CGLContextObj);
  void (*releaseContext)(CGLContextObj);
  CGLPixelFormatObj (*contextFormat)(CGLContextObj);
  CGLError (*setCurrent)(CGLContextObj);
  CGLContextObj (*current)(void);
  CGLError (*flush)(CGLContextObj);
  CGLError (*update)(CGLContextObj);
  CGLError (*setParameter)(CGLContextObj, int32_t, const AKGLint *);
  CGLError (*getParameter)(CGLContextObj, int32_t, AKGLint *);
  void (*setDrawable)(CGLContextObj, void *, double);
  void (*setOptions)(double, int, CFDictionaryRef);
} GL;

static BOOL loadGL(void) {
  static BOOL loaded;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Dl_info info;
    if (!dladdr((const void *)&loadGL, &info) || !info.dli_fname) return;
    NSString *frameworks = @(info.dli_fname).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *path = [frameworks stringByAppendingPathComponent:@"AKOpenGL.framework/AKOpenGL"];
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
      fprintf(stderr, "[AppKitShim] OpenGL: not available here: %s\n", dlerror());
      return;
    }
#define FN(field, name) GL.field = (__typeof__(GL.field))dlsym(h, #name)
    FN(choose, CGLChoosePixelFormat); FN(retainFormat, CGLRetainPixelFormat); FN(releaseFormat, CGLReleasePixelFormat);
    FN(describe, CGLDescribePixelFormat); FN(create, CGLCreateContext); FN(retainContext, CGLRetainContext);
    FN(releaseContext, CGLReleaseContext); FN(contextFormat, CGLGetPixelFormat); FN(setCurrent, CGLSetCurrentContext);
    FN(current, CGLGetCurrentContext); FN(flush, CGLFlushDrawable); FN(update, CGLUpdateContext);
    FN(setParameter, CGLSetParameter); FN(getParameter, CGLGetParameter); FN(setDrawable, AKGLSetDrawable);
    FN(setOptions, AKGLSetOptions);
#undef FN
    loaded = GL.choose && GL.create && GL.setCurrent && GL.flush && GL.setDrawable && GL.current;
    if (!loaded) fprintf(stderr, "[AppKitShim] OpenGL: AKOpenGL.framework lacks CGL functions\n");
    if (loaded) dispatch_async(dispatch_get_main_queue(), ^{ AKGameGLOptionsChanged(); });
  });
  return loaded;
}

// The running game's settings (GameProfiles.m): the pixels per point its frames are drawn at (0:
// the screen's), its frame rate limit and the Metal HUD's layer settings (none: no HUD).
void AKGameGLOptionsChanged(void) {
  if (!GL.setOptions) return;
  double fraction = AKGameRenderFraction();
  double scale = fraction < 1 ? MAX(1, UIScreen.mainScreen.scale * fraction) : 0;
  NSDictionary *hud = AKGameHUDShown() ? AKGameHUDProperties() : nil;
  GL.setOptions(scale, AKGameFrameLimit(), (__bridge CFDictionaryRef)hud);
}

#pragma mark Pixel formats

@implementation NSOpenGLPixelFormat {
  CGLPixelFormatObj _pix;
}

- (instancetype)initWithAttributes:(const uint32_t *)attribs {
  if (!AKGameIsRunning() || !loadGL() || !(self = [super init])) return nil;
  AKGameProfileNoteDraws(@"opengl");
  // NSOpenGLPFA* and kCGLPFA* are the same numbers.
  if (GL.choose((const int32_t *)attribs, &_pix, NULL) != kCGLNoError || !_pix) return nil;
  return self;
}

// From a nib: the attributes as archived (NSOpenGLPixelFormatAttribute values, 0-terminated).
- (instancetype)initWithCoder:(NSCoder *)coder {
  NSData *data = [coder decodeObjectForKey:@"NSPixelAttributes"];
  if (![data isKindOfClass:NSData.class] || data.length < sizeof(uint32_t)) return [self initWithAttributes:(const uint32_t[]){ 5, 12, 24, 0 }];
  NSMutableData *attribs = [data mutableCopy];
  [attribs increaseLengthBy:sizeof(uint32_t)];
  return [self initWithAttributes:attribs.bytes];
}

- (instancetype)initWithCGLPixelFormatObj:(void *)pix {
  if (!pix || !loadGL() || !(self = [super init])) return nil;
  _pix = GL.retainFormat ? GL.retainFormat(pix) : pix;
  return self;
}

- (void *)CGLPixelFormatObj { return _pix; }
- (int32_t)numberOfVirtualScreens { return 1; }

- (void)getValues:(int32_t *)vals forAttribute:(uint32_t)attrib forVirtualScreen:(int32_t)screen {
  if (vals && GL.describe) GL.describe(_pix, screen, (int32_t)attrib, vals);
}

- (void)dealloc { if (_pix && GL.releaseFormat) GL.releaseFormat(_pix); }

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Contexts

// Each CGL context's NSOpenGLContext, for +currentContext.
static NSMapTable<NSValue *, NSOpenGLContext *> *gContexts;

@implementation NSOpenGLContext {
  CGLContextObj _ctx;
  NSOpenGLPixelFormat *_format;
}

- (void)_ak_register {
  @synchronized (NSOpenGLContext.class) {
    if (!gContexts) gContexts = [NSMapTable strongToWeakObjectsMapTable];
    [gContexts setObject:self forKey:[NSValue valueWithPointer:_ctx]];
  }
}

- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share {
  if (!format.CGLPixelFormatObj || !loadGL() || !(self = [super init])) return nil;
  if (GL.create(format.CGLPixelFormatObj, share ? share->_ctx : NULL, &_ctx) != kCGLNoError || !_ctx) return nil;
  _format = format;
  [self _ak_register];
  return self;
}

- (instancetype)initWithCGLContextObj:(void *)ctx {
  if (!ctx || !loadGL() || !(self = [super init])) return nil;
  _ctx = GL.retainContext ? GL.retainContext(ctx) : ctx;
  if (GL.contextFormat) _format = [[NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:GL.contextFormat(_ctx)];
  [self _ak_register];
  return self;
}

- (void)dealloc {
  @synchronized (NSOpenGLContext.class) { [gContexts removeObjectForKey:[NSValue valueWithPointer:_ctx]]; }
  if (_ctx && GL.releaseContext) GL.releaseContext(_ctx);
}

- (void *)CGLContextObj { return _ctx; }
- (NSOpenGLPixelFormat *)pixelFormat { return _format; }

+ (NSOpenGLContext *)currentContext {
  if (!GL.current) return nil;
  CGLContextObj ctx = GL.current();
  if (!ctx) return nil;
  @synchronized (NSOpenGLContext.class) { return [gContexts objectForKey:[NSValue valueWithPointer:ctx]]; }
}

+ (void)clearCurrentContext { if (GL.setCurrent) GL.setCurrent(NULL); }
- (void)makeCurrentContext { GL.setCurrent(_ctx); }
- (void)flushBuffer { GL.flush(_ctx); }

// The view's backing UIView shows the frames, drawn in pixels when it wants the screen's
// resolution, else in points (as on a Mac).
- (void)_ak_attach {
  NSView *view = _view;
  CGFloat scale = 1;
  if (view.wantsBestResolutionOpenGLSurface) scale = view.window ? view.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
  GL.setDrawable(_ctx, (__bridge void *)view.backingView, scale);
}

- (void)setView:(NSView *)view {
  _view = view;
  [self _ak_attach];
}

- (void)update {
  if (_view) [self _ak_attach];
  else if (GL.update) GL.update(_ctx);
}

- (void)clearDrawable {
  _view = nil;
  GL.setDrawable(_ctx, NULL, 1);
}

- (void)setValues:(const int32_t *)vals forParameter:(NSInteger)param {
  if (GL.setParameter) GL.setParameter(_ctx, (int32_t)param, vals);
}

- (void)getValues:(int32_t *)vals forParameter:(NSInteger)param {
  if (GL.getParameter) GL.getParameter(_ctx, (int32_t)param, vals);
}

- (NSInteger)currentVirtualScreen { return 0; }
- (void)setCurrentVirtualScreen:(NSInteger)screen {}
- (void)setFullScreen {}
- (void)setOffScreen:(void *)baseaddr width:(int32_t)width height:(int32_t)height rowbytes:(int32_t)rowbytes {}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

#pragma mark Views

@implementation NSOpenGLView {
  BOOL _prepared;
}

@synthesize openGLContext = _openGLContext;

+ (NSOpenGLPixelFormat *)defaultPixelFormat {
  const uint32_t attribs[] = { 5 /* DoubleBuffer */, 12 /* DepthSize */, 24, 0 };
  return [[NSOpenGLPixelFormat alloc] initWithAttributes:attribs];
}

- (instancetype)initWithFrame:(NSRect)frame pixelFormat:(NSOpenGLPixelFormat *)format {
  if ((self = [super initWithFrame:frame])) _pixelFormat = format ?: [self.class defaultPixelFormat];
  return self;
}

// Not through -initWithFrame:pixelFormat:, which a game may override: a nib view is set up
// with this one (NSView's -initWithCoder:), then gets its archived pixel format.
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) _pixelFormat = [self.class defaultPixelFormat];
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if (!(self = [super initWithCoder:coder])) return nil;
  NSOpenGLPixelFormat *format = [coder decodeObjectForKey:@"NSPixelFormat"];
  if ([format isKindOfClass:NSOpenGLPixelFormat.class]) _pixelFormat = format;
  return self;
}

// As in AppKit: made when first asked for, then current, and -prepareOpenGL runs once.
- (NSOpenGLContext *)openGLContext {
  if (!_openGLContext && _pixelFormat) {
    _openGLContext = [[NSOpenGLContext alloc] initWithFormat:_pixelFormat shareContext:nil];
    [_openGLContext setView:self];
    if (_openGLContext && !_prepared) {
      _prepared = YES;
      [_openGLContext makeCurrentContext];
      [self prepareOpenGL];
    }
  }
  return _openGLContext;
}

- (void)setOpenGLContext:(NSOpenGLContext *)context {
  _openGLContext = context;
  [context setView:self];
}

- (void)prepareOpenGL {}
- (void)reshape {}
- (void)update { [_openGLContext update]; }
- (void)clearGLContext {
  [_openGLContext clearDrawable];
  _openGLContext = nil;
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [_openGLContext update];
  [self reshape];
}

- (BOOL)isOpaque { return YES; }

// As AppKit's -lockFocus on an OpenGL view: its context current for the drawing that follows.
- (void)lockFocus { [self.openGLContext makeCurrentContext]; }
- (void)unlockFocus {}

// AppKit's -display: drawn now, on the thread that owns the context (the game's main thread).
- (void)display { [self _ak_performOnOwnerThread:^{ [self _ak_display]; }]; }
- (void)displayIfNeeded { [self display]; }

- (void)_ak_display {
  [self.openGLContext makeCurrentContext];
  [self drawRect:self.bounds];
}

@end

static void collectOpenGLViews(NSView *view, NSMutableArray<NSOpenGLView *> *into) {
  if ([view isKindOfClass:NSOpenGLView.class]) [into addObject:(NSOpenGLView *)view];
  for (NSView *sub in view.subviews) collectOpenGLViews(sub, into);
}

void AKPrepareGameOpenGLViews(void) {
  NSMutableArray<NSOpenGLView *> *views = [NSMutableArray array];
  for (NSWindow *window in NSApp.windows) if (window._ak_gameWindow) collectOpenGLViews(window.contentView, views);
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSOpenGLView *view in views) {
    NSOpenGLContext *context = view.openGLContext;   // made, current and prepared if it had none
    [context makeCurrentContext];
    [view reshape];
    [names addObject:[NSString stringWithFormat:@"%s %.0fx%.0f%@", class_getName(view.class), view.bounds.size.width,
                                                view.bounds.size.height, context ? @"" : @" (no context: no pixel format)"]];
  }
  if (!views.count) fprintf(stderr, "[AppKitShim] OpenGL: no OpenGL view in its windows yet\n");
  else fprintf(stderr, "[AppKitShim] OpenGL: its views: %s; a context is %scurrent on its main thread\n",
               [names componentsJoinedByString:@", "].UTF8String, GL.current && GL.current() ? "" : "NOT ");
}
