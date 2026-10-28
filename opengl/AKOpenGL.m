// AKOpenGL.framework: desktop OpenGL for the Mac games Steam starts (src/MacPrograms.m points
// their OpenGL.framework here). Done natively, no emulation and no JIT: Mesa's OpenGL (libOSMesa,
// re-exported by this framework, so a game's gl* calls go straight to Mesa) with the Zink driver
// turns GL into Vulkan, and MoltenVK turns Vulkan into Metal (tools/gl/build.sh builds both
// for iOS arm64). This file is the rest of OpenGL.framework: CGL (pixel formats, contexts,
// flushing), GLU, Apple's own GL extensions, and putting each frame on the screen.
//
// A context renders through Zink and OSMesa copies each finished frame into the buffer it is
// bound to: one of three IOSurfaces per context. Flushing shows that surface as the contents
// of a layer on the context's view and binds the next one, so the game draws one frame while
// Core Animation shows the last. OSMesa's framebuffers are single-buffered, so the back buffer
// a Mac game draws to is the front buffer here (glDrawBuffer/glReadBuffer below).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach/mach_time.h>
#import <math.h>
#import <pthread.h>

#pragma mark Mesa

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLboolean;
typedef unsigned char GLubyte;
typedef float GLfloat;
typedef double GLdouble;
typedef intptr_t GLintptr;
typedef intptr_t GLsizeiptr;
typedef struct __GLsync *GLsync;
typedef uint64_t GLuint64;

typedef struct osmesa_context *OSMesaContext;
extern OSMesaContext OSMesaCreateContextAttribs(const int *attribList, OSMesaContext sharelist);
extern void OSMesaDestroyContext(OSMesaContext ctx);
extern GLboolean OSMesaMakeCurrent(OSMesaContext ctx, void *buffer, GLenum type, GLsizei width, GLsizei height);
extern OSMesaContext OSMesaGetCurrentContext(void);
extern void OSMesaPixelStore(GLint pname, GLint value);
extern void *OSMesaGetProcAddress(const char *funcName);

enum {
  OSMESA_BGRA = 0x1, OSMESA_ROW_LENGTH = 0x10, OSMESA_Y_UP = 0x11, OSMESA_FORMAT = 0x22,
  OSMESA_DEPTH_BITS = 0x30, OSMESA_STENCIL_BITS = 0x31, OSMESA_ACCUM_BITS = 0x32, OSMESA_PROFILE = 0x33,
  OSMESA_CORE_PROFILE = 0x34, OSMESA_COMPAT_PROFILE = 0x35, OSMESA_CONTEXT_MAJOR_VERSION = 0x36,
  OSMESA_CONTEXT_MINOR_VERSION = 0x37,
};
enum {
  GL_NO_ERROR = 0, GL_UNSIGNED_BYTE = 0x1401, GL_VENDOR = 0x1F00, GL_RENDERER = 0x1F01, GL_VERSION = 0x1F02,
  GL_SHADING_LANGUAGE_VERSION = 0x8B8C, GL_FRONT_LEFT = 0x0400, GL_FRONT_RIGHT = 0x0401, GL_BACK_LEFT = 0x0402,
  GL_BACK_RIGHT = 0x0403, GL_FRONT = 0x0404, GL_BACK = 0x0405, GL_LEFT = 0x0406, GL_RIGHT = 0x0407,
  GL_DRAW_FRAMEBUFFER_BINDING = 0x8CA6, GL_READ_FRAMEBUFFER_BINDING = 0x8CAA,
  GL_SYNC_GPU_COMMANDS_COMPLETE = 0x9117, GL_SYNC_FLUSH_COMMANDS_BIT = 0x1, GL_ALREADY_SIGNALED = 0x911A,
  GL_CONDITION_SATISFIED = 0x911C, GL_INVALID_ENUM = 0x0500, GL_INVALID_VALUE = 0x0501,
  GL_INVALID_OPERATION = 0x0502, GL_STACK_OVERFLOW = 0x0503, GL_STACK_UNDERFLOW = 0x0504,
  GL_OUT_OF_MEMORY = 0x0505, GL_INVALID_FRAMEBUFFER_OPERATION = 0x0506,
};

extern void glFinish(void);
extern void glFlush(void);
extern const GLubyte *glGetString(GLenum name);
extern void glGetIntegerv(GLenum pname, GLint *data);
extern void glOrtho(GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f);
extern void glMultMatrixd(const GLdouble *m);
extern void glTranslated(GLdouble x, GLdouble y, GLdouble z);
extern void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
                         GLint border, GLenum format, GLenum type, const void *pixels);

// Mesa's own entry point for a function this file also defines (or that may not be exported).
#define MESA(type, name) ((type)OSMesaGetProcAddress(#name))

static void glLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void glLog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[AppKitShim] OpenGL: %s\n", line.UTF8String);
}

static NSString *frameworksDir(void) {
  Dl_info info;
  if (!dladdr((const void *)&frameworksDir, &info) || !info.dli_fname) return nil;
  return @(info.dli_fname).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
}

#pragma mark Vulkan, with each pipeline's shaders kept

// Zink reaches MoltenVK through this library (ZINK_VULKAN_LIBRARY names it), and every call
// goes straight on to MoltenVK — but each pipeline's SPIR-V shaders are first written to
// Documents/gl-shaders, so a shader whose conversion to Metal crashes MoltenVK is on disk
// afterwards: last-<stage>.spv is the pipeline being made, <hash>-<stage>.spv every shader
// once, and pipelines.txt lists each pipeline's shaders in order.
typedef void (*AKVkVoidFunction)(void);
typedef AKVkVoidFunction (*AKVkGetProcAddr)(void *handle, const char *name);
typedef int32_t (*AKVkCreateShaderModule)(void *device, const void *info, const void *allocator, uint64_t *module);
typedef void (*AKVkDestroyShaderModule)(void *device, uint64_t module, const void *allocator);
typedef int32_t (*AKVkCreateGraphicsPipelines)(void *device, uint64_t cache, uint32_t count, const void *infos,
                                               const void *allocator, uint64_t *pipelines);
typedef struct { uint32_t sType; const void *pNext; } AKVkHeader;
typedef struct { uint32_t sType; const void *pNext; uint32_t flags; size_t codeSize; const uint32_t *pCode; } AKVkShaderModuleInfo;
typedef struct { uint32_t sType; const void *pNext; uint32_t flags; uint32_t stage; uint64_t module; const char *pName;
                 const void *pSpecializationInfo; } AKVkStageInfo;
typedef struct { uint32_t sType; const void *pNext; uint32_t flags; uint32_t stageCount; const AKVkStageInfo *pStages;
                 uint8_t rest[112]; } AKVkPipelineInfo;
_Static_assert(sizeof(AKVkShaderModuleInfo) == 40, "VkShaderModuleCreateInfo");
_Static_assert(sizeof(AKVkStageInfo) == 48, "VkPipelineShaderStageCreateInfo");
_Static_assert(sizeof(AKVkPipelineInfo) == 144, "VkGraphicsPipelineCreateInfo");
enum { kVkShaderModuleCreateInfo = 16 };

static AKVkGetProcAddr gMvkInstanceProcAddr, gMvkDeviceProcAddr;
static AKVkCreateShaderModule gMvkCreateShaderModule;
static AKVkDestroyShaderModule gMvkDestroyShaderModule;
static AKVkCreateGraphicsPipelines gMvkCreateGraphicsPipelines;
static NSMutableDictionary<NSNumber *, NSData *> *gShaderCode;   // shader module -> its SPIR-V
static NSMutableSet<NSString *> *gShaderFiles;
static pthread_mutex_t gShaderLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *gShaderDir;
static unsigned gPipelines;

static BOOL loadMoltenVK(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *mvk = [frameworksDir() stringByAppendingPathComponent:@"libMoltenVK.dylib"];
    void *h = dlopen(mvk.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (h) gMvkInstanceProcAddr = (AKVkGetProcAddr)dlsym(h, "vkGetInstanceProcAddr");
    if (h) gMvkDeviceProcAddr = (AKVkGetProcAddr)dlsym(h, "vkGetDeviceProcAddr");
    if (!gMvkInstanceProcAddr) glLog(@"MoltenVK doesn't load: %s", dlerror());
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    gShaderDir = [docs stringByAppendingPathComponent:@"gl-shaders"];
    [NSFileManager.defaultManager removeItemAtPath:gShaderDir error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:gShaderDir withIntermediateDirectories:YES attributes:nil error:nil];
    gShaderCode = [NSMutableDictionary dictionary];
    gShaderFiles = [NSMutableSet set];
  });
  return gMvkInstanceProcAddr != NULL;
}

static int32_t akCreateShaderModule(void *device, const void *info, const void *allocator, uint64_t *module) {
  int32_t result = gMvkCreateShaderModule(device, info, allocator, module);
  const AKVkShaderModuleInfo *m = info;
  if (result == 0 && module && m && m->pCode && m->codeSize) {
    NSData *code = [NSData dataWithBytes:m->pCode length:m->codeSize];
    pthread_mutex_lock(&gShaderLock);
    gShaderCode[@(*module)] = code;
    pthread_mutex_unlock(&gShaderLock);
  }
  return result;
}

static void akDestroyShaderModule(void *device, uint64_t module, const void *allocator) {
  pthread_mutex_lock(&gShaderLock);
  [gShaderCode removeObjectForKey:@(module)];
  pthread_mutex_unlock(&gShaderLock);
  gMvkDestroyShaderModule(device, module, allocator);
}

static NSString *stageName(uint32_t stage) {
  switch (stage) {
    case 0x1: return @"vertex";
    case 0x2: return @"tesscontrol";
    case 0x4: return @"tesseval";
    case 0x8: return @"geometry";
    case 0x10: return @"fragment";
    default: return [NSString stringWithFormat:@"stage%x", stage];
  }
}

// A stage's SPIR-V: its module's, or given inline (VkShaderModuleCreateInfo in its pNext).
static NSData *stageCode(const AKVkStageInfo *stage) {
  if (stage->module) {
    pthread_mutex_lock(&gShaderLock);
    NSData *code = gShaderCode[@(stage->module)];
    pthread_mutex_unlock(&gShaderLock);
    return code;
  }
  for (const AKVkHeader *h = stage->pNext; h; h = h->pNext) {
    if (h->sType != kVkShaderModuleCreateInfo) continue;
    const AKVkShaderModuleInfo *m = (const void *)h;
    return m->pCode ? [NSData dataWithBytes:m->pCode length:m->codeSize] : nil;
  }
  return nil;
}

static void keepPipelineShaders(const AKVkPipelineInfo *pipeline) {
  unsigned n = __atomic_add_fetch(&gPipelines, 1, __ATOMIC_RELAXED);
  NSMutableString *line = [NSMutableString stringWithFormat:@"pipeline %u:", n];
  for (uint32_t i = 0; pipeline->pStages && i < pipeline->stageCount; i++) {
    const AKVkStageInfo *stage = &pipeline->pStages[i];
    NSData *code = stageCode(stage);
    NSString *name = stageName(stage->stage);
    if (!code) { [line appendFormat:@" %@ (no code seen)", name]; continue; }
    uint64_t hash = 1469598103934665603ull;   // FNV-1a
    const uint8_t *b = code.bytes;
    for (NSUInteger k = 0; k < code.length; k++) hash = (hash ^ b[k]) * 1099511628211ull;
    NSString *file = [NSString stringWithFormat:@"%016llx-%@.spv", hash, name];
    [code writeToFile:[gShaderDir stringByAppendingPathComponent:[NSString stringWithFormat:@"last-%@.spv", name]] atomically:NO];
    pthread_mutex_lock(&gShaderLock);
    BOOL fresh = ![gShaderFiles containsObject:file] && gShaderFiles.count < 500;
    if (fresh) [gShaderFiles addObject:file];
    pthread_mutex_unlock(&gShaderLock);
    if (fresh) [code writeToFile:[gShaderDir stringByAppendingPathComponent:file] atomically:NO];
    [line appendFormat:@" %@ %@ (%lu bytes, entry %s)", name, file, (unsigned long)code.length, stage->pName ?: "?"];
  }
  [line appendString:@"\n"];
  NSString *list = [gShaderDir stringByAppendingPathComponent:@"pipelines.txt"];
  int fd = open(list.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd >= 0) { const char *s = line.UTF8String; write(fd, s, strlen(s)); close(fd); }
  if (n <= 5 || n % 100 == 0) glLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
}

static int32_t akCreateGraphicsPipelines(void *device, uint64_t cache, uint32_t count, const void *infos,
                                         const void *allocator, uint64_t *pipelines) {
  @autoreleasepool {
    for (uint32_t i = 0; infos && i < count; i++) keepPipelineShaders(&((const AKVkPipelineInfo *)infos)[i]);
  }
  return gMvkCreateGraphicsPipelines(device, cache, count, infos, allocator, pipelines);
}

static AKVkVoidFunction recorded(const char *name, AKVkVoidFunction f) {
  if (!f || !name) return f;
  if (!strcmp(name, "vkCreateShaderModule")) { gMvkCreateShaderModule = (AKVkCreateShaderModule)f; return (AKVkVoidFunction)akCreateShaderModule; }
  if (!strcmp(name, "vkDestroyShaderModule")) { gMvkDestroyShaderModule = (AKVkDestroyShaderModule)f; return (AKVkVoidFunction)akDestroyShaderModule; }
  if (!strcmp(name, "vkCreateGraphicsPipelines")) {
    gMvkCreateGraphicsPipelines = (AKVkCreateGraphicsPipelines)f;
    return (AKVkVoidFunction)akCreateGraphicsPipelines;
  }
  return f;
}

AKVkVoidFunction vkGetDeviceProcAddr(void *device, const char *name);

__attribute__((visibility("default"))) AKVkVoidFunction vkGetInstanceProcAddr(void *instance, const char *name) {
  if (!loadMoltenVK()) return NULL;
  if (name && !strcmp(name, "vkGetInstanceProcAddr")) return (AKVkVoidFunction)vkGetInstanceProcAddr;
  if (name && !strcmp(name, "vkGetDeviceProcAddr")) {
    if (!gMvkDeviceProcAddr) gMvkDeviceProcAddr = (AKVkGetProcAddr)gMvkInstanceProcAddr(instance, name);
    return gMvkDeviceProcAddr ? (AKVkVoidFunction)vkGetDeviceProcAddr : NULL;
  }
  return recorded(name, gMvkInstanceProcAddr(instance, name));
}

__attribute__((visibility("default"))) AKVkVoidFunction vkGetDeviceProcAddr(void *device, const char *name) {
  if (!loadMoltenVK() || !gMvkDeviceProcAddr) return NULL;
  if (name && !strcmp(name, "vkGetDeviceProcAddr")) return (AKVkVoidFunction)vkGetDeviceProcAddr;
  return recorded(name, gMvkDeviceProcAddr(device, name));
}

// Zink is told where Vulkan is (this library, in front of MoltenVK) and to run as the driver.
// Read when the first context is made.
static void configureMesa(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *mvk = [frameworksDir() stringByAppendingPathComponent:@"libMoltenVK.dylib"];
    Dl_info me;
    BOOL recording = dladdr((const void *)&vkGetInstanceProcAddr, &me) && me.dli_fname;
    setenv("ZINK_VULKAN_LIBRARY", recording ? me.dli_fname : mvk.fileSystemRepresentation, 1);
    setenv("GALLIUM_DRIVER", "zink", 1);
    setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);   // MoltenVK: errors only
    // A Metal shader compile that never finishes would freeze the game: give up after 20 s.
    setenv("MVK_CONFIG_METAL_COMPILE_TIMEOUT", "20000000000", 0);
    // Metal has no geometry shaders, so Zink honestly reports OpenGL 3.1. Mac games target
    // what macOS has, 4.1 with GLSL 4.10: report that, and a game that never uses geometry
    // shaders (most) runs.
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 0);
    setenv("MESA_GLSL_VERSION_OVERRIDE", "410", 0);
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *cache = [caches stringByAppendingPathComponent:@"mesa-shader-cache"];
    [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("MESA_SHADER_CACHE_DIR", cache.fileSystemRepresentation, 0);
    glLog(@"Mesa (Zink) on MoltenVK: %@%s", mvk, recording ? "; each pipeline's shaders kept in Documents/gl-shaders" : "");
  });
}

#pragma mark CGL types

typedef struct _CGLPixelFormatObject *CGLPixelFormatObj;
typedef struct _CGLContextObject *CGLContextObj;
typedef struct _CGLShareGroupObject *CGLShareGroupObj;
typedef struct _CGLRendererInfoObject *CGLRendererInfoObj;
typedef int32_t CGLPixelFormatAttribute, CGLContextParameter, CGLContextEnable, CGLRendererProperty, CGLGlobalOption;
typedef int32_t CGLError;

enum {
  kCGLNoError = 0, kCGLBadAttribute = 10000, kCGLBadProperty = 10001, kCGLBadPixelFormat = 10002,
  kCGLBadRendererInfo = 10003, kCGLBadContext = 10004, kCGLBadDrawable = 10005, kCGLBadDisplay = 10006,
  kCGLBadState = 10007, kCGLBadValue = 10008, kCGLBadMatch = 10009, kCGLBadEnumeration = 10010,
  kCGLBadOffScreen = 10011, kCGLBadFullScreen = 10012, kCGLBadWindow = 10013, kCGLBadAddress = 10014,
  kCGLBadCodeModule = 10015, kCGLBadAlloc = 10016, kCGLBadConnection = 10017,
};
enum {   // pixel format attributes (NSOpenGLPFA* are the same numbers)
  kCGLPFADoubleBuffer = 5, kCGLPFAAuxBuffers = 7, kCGLPFAColorSize = 8, kCGLPFAAlphaSize = 11, kCGLPFADepthSize = 12,
  kCGLPFAStencilSize = 13, kCGLPFAAccumSize = 14, kCGLPFASampleBuffers = 55, kCGLPFASamples = 56,
  kCGLPFARendererID = 70, kCGLPFAAccelerated = 73, kCGLPFADisplayMask = 84, kCGLPFAOpenGLProfile = 99,
  kCGLPFAVirtualScreenCount = 128,
  kCGLOGLPVersion_Legacy = 0x1000, kCGLOGLPVersion_3_2_Core = 0x3200, kCGLOGLPVersion_GL4_Core = 0x4100,
};
enum {   // context parameters (NSOpenGLContextParameter* are the same numbers)
  kCGLCPSwapInterval = 222, kCGLCPSurfaceOrder = 235, kCGLCPSurfaceOpacity = 236, kCGLCPSurfaceBackingSize = 304,
  kCGLCPCurrentRendererID = 309, kCGLCPGPUVertexProcessing = 310, kCGLCPGPUFragmentProcessing = 311,
  kCGLCPHasDrawable = 314, kCGLCPMPSwapsInFlight = 315,
};
enum { kCGLRPRendererID = 70, kCGLRPAccelerated = 73, kCGLRPDisplayMask = 84, kCGLRPRendererCount = 128,
       kCGLRPOnline = 129, kCGLRPVideoMemoryMegabytes = 131, kCGLRPTextureMemoryMegabytes = 132,
       kCGLRPMajorGLVersion = 133 };
static const GLint kRendererID = 0x00024000;   // an Apple GPU's renderer ID class

#pragma mark Pixel formats

@interface AKGLPixelFormat : NSObject {
 @public
  int depth, stencil, profile, samples;
  BOOL doubleBuffer;
}
@end
@implementation AKGLPixelFormat
@end

static BOOL hasValue(CGLPixelFormatAttribute a) {
  switch (a) {
    case kCGLPFAAuxBuffers: case kCGLPFAColorSize: case kCGLPFAAlphaSize: case kCGLPFADepthSize:
    case kCGLPFAStencilSize: case kCGLPFAAccumSize: case kCGLPFASampleBuffers: case kCGLPFASamples:
    case kCGLPFARendererID: case kCGLPFADisplayMask: case kCGLPFAOpenGLProfile: case kCGLPFAVirtualScreenCount:
      return YES;
    default:
      return NO;
  }
}

CGLError CGLChoosePixelFormat(const CGLPixelFormatAttribute *attribs, CGLPixelFormatObj *pix, GLint *npix) {
  if (!pix) return kCGLBadAddress;
  AKGLPixelFormat *f = [AKGLPixelFormat new];
  f->depth = 24; f->stencil = 8; f->profile = kCGLOGLPVersion_Legacy;
  for (const CGLPixelFormatAttribute *a = attribs; a && *a; a++) {
    CGLPixelFormatAttribute name = *a;
    int value = hasValue(name) ? *++a : 1;
    switch (name) {
      case kCGLPFADepthSize: f->depth = value; break;
      case kCGLPFAStencilSize: f->stencil = value; break;
      case kCGLPFAOpenGLProfile: f->profile = value; break;
      case kCGLPFASamples: f->samples = value; break;
      case kCGLPFADoubleBuffer: f->doubleBuffer = YES; break;
    }
  }
  *pix = (CGLPixelFormatObj)CFBridgingRetain(f);
  if (npix) *npix = 1;
  return kCGLNoError;
}

static AKGLPixelFormat *format(CGLPixelFormatObj pix) { return (__bridge AKGLPixelFormat *)(void *)pix; }

CGLPixelFormatObj CGLRetainPixelFormat(CGLPixelFormatObj pix) { if (pix) CFRetain(pix); return pix; }
void CGLReleasePixelFormat(CGLPixelFormatObj pix) { if (pix) CFRelease(pix); }
CGLError CGLDestroyPixelFormat(CGLPixelFormatObj pix) { CGLReleasePixelFormat(pix); return kCGLNoError; }
GLuint CGLGetPixelFormatRetainCount(CGLPixelFormatObj pix) { return pix ? (GLuint)CFGetRetainCount(pix) : 0; }

CGLError CGLDescribePixelFormat(CGLPixelFormatObj pix, GLint index, CGLPixelFormatAttribute attrib, GLint *value) {
  if (!pix || !value) return kCGLBadAddress;
  AKGLPixelFormat *f = format(pix);
  switch (attrib) {
    case kCGLPFADepthSize: *value = f->depth; break;
    case kCGLPFAStencilSize: *value = f->stencil; break;
    case kCGLPFAColorSize: *value = 32; break;
    case kCGLPFAAlphaSize: *value = 8; break;
    case kCGLPFADoubleBuffer: *value = f->doubleBuffer; break;
    case kCGLPFAAccelerated: *value = 1; break;
    case kCGLPFAOpenGLProfile: *value = f->profile; break;
    case kCGLPFASamples: *value = f->samples; break;
    case kCGLPFASampleBuffers: *value = f->samples > 0; break;
    case kCGLPFARendererID: *value = kRendererID; break;
    case kCGLPFAVirtualScreenCount: *value = 1; break;
    case kCGLPFADisplayMask: *value = 1; break;
    default: *value = 0;
  }
  return kCGLNoError;
}

#pragma mark Contexts

@interface AKGLContext : NSObject {
 @public
  OSMesaContext mesa;
  AKGLPixelFormat *format;
  pthread_mutex_t lock;
  GLint swapInterval, opacity;
  // Where frames go: the view's layer, and the size in pixels the frames are drawn at.
  CALayer *layer;
  __weak UIView *view;
  double scale;
  volatile int wantedWidth, wantedHeight;   // set on the main thread, read when drawing
  volatile BOOL measuring;                  // a measure queued on the main thread
  // The IOSurfaces frames are drawn into, and the one bound now.
  IOSurfaceRef surfaces[3];
  int slot, width, height, rowPixels;
  BOOL bound;
  // Pacing and the frame-rate line in the log.
  uint64_t lastPresent;
  unsigned frames, framesSinceLog;
  CFTimeInterval logStart;
}
@end

@implementation AKGLContext
- (void)dealloc {
  if (mesa) OSMesaDestroyContext(mesa);
  for (int i = 0; i < 3; i++) if (surfaces[i]) CFRelease(surfaces[i]);
  CALayer *l = layer;
  if (l) dispatch_async(dispatch_get_main_queue(), ^{ [l removeFromSuperlayer]; });
  pthread_mutex_destroy(&lock);
}
@end

static AKGLContext *context(CGLContextObj ctx) { return (__bridge AKGLContext *)(void *)ctx; }
static __thread void *tCurrent;   // this thread's current context (unretained)

static void onMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_sync(dispatch_get_main_queue(), block);
}

CGLError CGLCreateContext(CGLPixelFormatObj pix, CGLContextObj share, CGLContextObj *ctx) {
  if (!pix || !ctx) return kCGLBadAddress;
  configureMesa();
  AKGLPixelFormat *f = format(pix);
  BOOL core = f->profile == kCGLOGLPVersion_3_2_Core || f->profile == kCGLOGLPVersion_GL4_Core;
  int attribs[20], n = 0;
  attribs[n++] = OSMESA_FORMAT;      attribs[n++] = OSMESA_BGRA;
  attribs[n++] = OSMESA_DEPTH_BITS;  attribs[n++] = f->depth;
  attribs[n++] = OSMESA_STENCIL_BITS; attribs[n++] = f->stencil;
  attribs[n++] = OSMESA_ACCUM_BITS;  attribs[n++] = 0;
  attribs[n++] = OSMESA_PROFILE;     attribs[n++] = core ? OSMESA_CORE_PROFILE : OSMESA_COMPAT_PROFILE;
  if (core) {
    attribs[n++] = OSMESA_CONTEXT_MAJOR_VERSION; attribs[n++] = f->profile == kCGLOGLPVersion_GL4_Core ? 4 : 3;
    attribs[n++] = OSMESA_CONTEXT_MINOR_VERSION; attribs[n++] = f->profile == kCGLOGLPVersion_GL4_Core ? 1 : 2;
  }
  attribs[n] = 0;
  OSMesaContext mesa = OSMesaCreateContextAttribs(attribs, share ? context(share)->mesa : NULL);
  if (!mesa) {
    glLog(@"no context for a %@ request", core ? @"core profile" : @"legacy profile");
    *ctx = NULL;
    return kCGLBadPixelFormat;
  }
  AKGLContext *c = [AKGLContext new];
  c->mesa = mesa;
  c->format = f;
  c->swapInterval = 1;
  c->opacity = 1;
  c->scale = 1;
  pthread_mutex_init(&c->lock, NULL);
  *ctx = (CGLContextObj)CFBridgingRetain(c);
  glLog(@"context %p (%@ profile, depth %d, stencil %d)", *ctx, core ? @"core" : @"legacy", f->depth, f->stencil);
  return kCGLNoError;
}

CGLContextObj CGLRetainContext(CGLContextObj ctx) { if (ctx) CFRetain(ctx); return ctx; }
void CGLReleaseContext(CGLContextObj ctx) {
  if (!ctx) return;
  if (tCurrent == ctx && CFGetRetainCount(ctx) == 1) {
    OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
    tCurrent = NULL;
  }
  CFRelease(ctx);
}
CGLError CGLDestroyContext(CGLContextObj ctx) { CGLReleaseContext(ctx); return kCGLNoError; }
GLuint CGLGetContextRetainCount(CGLContextObj ctx) { return ctx ? (GLuint)CFGetRetainCount(ctx) : 0; }
CGLPixelFormatObj CGLGetPixelFormat(CGLContextObj ctx) {
  return ctx ? (__bridge CGLPixelFormatObj)context(ctx)->format : NULL;
}

#pragma mark Drawing into IOSurfaces

static IOSurfaceRef makeSurface(int width, int height) {
  size_t row = ((size_t)width * 4 + 63) & ~(size_t)63;
  NSDictionary *props = @{
    (__bridge NSString *)kIOSurfaceWidth: @(width), (__bridge NSString *)kIOSurfaceHeight: @(height),
    (__bridge NSString *)kIOSurfaceBytesPerElement: @4, (__bridge NSString *)kIOSurfaceBytesPerRow: @(row),
    (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241),   // 'BGRA'
  };
  return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static void unbind(AKGLContext *c) {
  if (!c->bound) return;
  IOSurfaceUnlock(c->surfaces[c->slot], 0, NULL);
  c->bound = NO;
}

// The surfaces at the size the view wants (a placeholder until there's a view).
static void sizeSurfaces(AKGLContext *c) {
  int w = c->wantedWidth, h = c->wantedHeight;
  if (w <= 0 || h <= 0) { w = 64; h = 64; }
  if (w == c->width && h == c->height && c->surfaces[0]) return;
  unbind(c);
  for (int i = 0; i < 3; i++) {
    if (c->surfaces[i]) CFRelease(c->surfaces[i]);
    c->surfaces[i] = makeSurface(w, h);
  }
  c->width = w;
  c->height = h;
  c->rowPixels = (int)(IOSurfaceGetBytesPerRow(c->surfaces[0]) / 4);
  c->slot = 0;
  glLog(@"context %p draws %dx%d", c, w, h);
}

static BOOL bind(AKGLContext *c) {
  sizeSurfaces(c);
  IOSurfaceRef s = c->surfaces[c->slot];
  if (!s) return NO;
  if (!c->bound) {
    IOSurfaceLock(s, 0, NULL);
    c->bound = YES;
  }
  if (!OSMesaMakeCurrent(c->mesa, IOSurfaceGetBaseAddress(s), GL_UNSIGNED_BYTE, c->width, c->height)) return NO;
  OSMesaPixelStore(OSMESA_ROW_LENGTH, c->rowPixels);
  OSMesaPixelStore(OSMESA_Y_UP, 0);   // row 0 at the top, as the layer shows it
  return YES;
}

CGLError CGLSetCurrentContext(CGLContextObj ctx) {
  AKGLContext *previous = tCurrent ? context(tCurrent) : nil;
  if (!ctx) {
    if (previous) unbind(previous);
    OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
    tCurrent = NULL;
    return kCGLNoError;
  }
  AKGLContext *c = context(ctx);
  if (previous && previous != c) unbind(previous);
  if (!bind(c)) return kCGLBadContext;
  tCurrent = ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *renderer = (const char *)glGetString(GL_RENDERER), *version = (const char *)glGetString(GL_VERSION);
    const char *glsl = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
    glLog(@"renderer %s, OpenGL %s, GLSL %s", renderer ?: "?", version ?: "?", glsl ?: "?");
    if (renderer && !strstr(renderer, "zink"))
      glLog(@"Zink didn't start (no MoltenVK or Vulkan device?): this is Mesa's software renderer, which is slow");
  });
  return kCGLNoError;
}

CGLContextObj CGLGetCurrentContext(void) { return tCurrent; }

CGLError CGLLockContext(CGLContextObj ctx) { if (ctx) pthread_mutex_lock(&context(ctx)->lock); return kCGLNoError; }
CGLError CGLUnlockContext(CGLContextObj ctx) { if (ctx) pthread_mutex_unlock(&context(ctx)->lock); return kCGLNoError; }

// Where the context's frames are shown: `view` (a UIView; nil: nowhere), drawn at `scale`
// pixels per point. The shim's NSOpenGLContext calls this for -setView: and -update.
static void measure(AKGLContext *c) {
  UIView *view = c->view;
  CALayer *layer = c->layer;
  if (!view || !layer) return;
  CGRect bounds = view.bounds;
  if (!CGRectEqualToRect(layer.frame, bounds)) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.frame = bounds;
    [CATransaction commit];
  }
  c->wantedWidth = (int)lround(bounds.size.width * c->scale);
  c->wantedHeight = (int)lround(bounds.size.height * c->scale);
}

// Measured again on the main thread, without waiting for it: a game may ask every frame
// (-[NSOpenGLContext update]), and waiting on Steam's busy main thread each time cost frames.
static void measureLater(AKGLContext *c) {
  if (c->measuring) return;
  c->measuring = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    c->measuring = NO;
    measure(c);
  });
}

void AKGLSetDrawable(CGLContextObj ctx, void *uiView, double scale) {
  if (!ctx) return;
  AKGLContext *c = context(ctx);
  UIView *view = (__bridge UIView *)uiView;
  double s = scale > 0 ? scale : 1;
  if (view && view == c->view && s == c->scale && c->layer) { measureLater(c); return; }
  c->scale = s;
  onMain(^{
    if (c->view != view) {
      [c->layer removeFromSuperlayer];
      c->layer = nil;
      c->view = view;
      if (view) {
        CALayer *layer = [CALayer layer];
        layer.opaque = c->opacity != 0;
        layer.contentsGravity = kCAGravityResize;
        layer.contentsScale = c->scale;
        layer.backgroundColor = UIColor.blackColor.CGColor;
        [view.layer addSublayer:layer];
        c->layer = layer;
      }
    }
    measure(c);
  });
  glLog(@"context %p shows in a %dx%d view (%.0fx)", ctx, c->wantedWidth, c->wantedHeight, c->scale);
}

CGLError CGLUpdateContext(CGLContextObj ctx) {
  if (!ctx) return kCGLBadContext;
  measureLater(context(ctx));
  return kCGLNoError;
}

CGLError CGLClearDrawable(CGLContextObj ctx) { AKGLSetDrawable(ctx, NULL, 1); return kCGLNoError; }

// The frame just drawn goes on screen and the next surface is bound. With a swap interval
// the call waits for the next 60 Hz refresh, as a Mac's vsync would.
CGLError CGLFlushDrawable(CGLContextObj ctx) {
  if (!ctx) return kCGLBadContext;
  AKGLContext *c = context(ctx);
  if (!c->bound || tCurrent != ctx) { glFlush(); return kCGLNoError; }
  glFinish();   // OSMesa copies the finished frame into the bound surface
  IOSurfaceRef shown = c->surfaces[c->slot];
  unbind(c);
  CALayer *layer = c->layer;
  if (layer) {
    CFRetain(shown);
    dispatch_async(dispatch_get_main_queue(), ^{
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      layer.contents = (__bridge id)shown;
      [CATransaction commit];
      CFRelease(shown);
    });
  }
  c->slot = (c->slot + 1) % 3;
  // Now and then, follow the view's size (rotation, a window resized).
  if (++c->frames % 30 == 0) dispatch_async(dispatch_get_main_queue(), ^{ measure(c); });
  bind(c);

  if (c->swapInterval > 0) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    uint64_t period = 1000000000ull / 60 * tb.denom / tb.numer;
    uint64_t now = mach_absolute_time();
    if (c->lastPresent && now < c->lastPresent + period) mach_wait_until(c->lastPresent + period);
    c->lastPresent = mach_absolute_time();
  }
  CFTimeInterval t = CACurrentMediaTime();
  if (!c->logStart) c->logStart = t;
  c->framesSinceLog++;
  if (c->frames == 1) glLog(@"context %p: first frame on screen", ctx);
  if (t - c->logStart >= 10) {
    glLog(@"context %p: %.1f frames/s at %dx%d", ctx, c->framesSinceLog / (t - c->logStart), c->width, c->height);
    c->logStart = t;
    c->framesSinceLog = 0;
  }
  return kCGLNoError;
}

#pragma mark Parameters

CGLError CGLSetParameter(CGLContextObj ctx, CGLContextParameter pname, const GLint *params) {
  if (!ctx) return kCGLBadContext;
  if (!params) return kCGLBadAddress;
  AKGLContext *c = context(ctx);
  switch (pname) {
    case kCGLCPSwapInterval: c->swapInterval = params[0]; break;
    case kCGLCPSurfaceOpacity: {
      c->opacity = params[0];
      CALayer *layer = c->layer;
      BOOL opaque = params[0] != 0;
      dispatch_async(dispatch_get_main_queue(), ^{ layer.opaque = opaque; });
      break;
    }
    default: break;
  }
  return kCGLNoError;
}

CGLError CGLGetParameter(CGLContextObj ctx, CGLContextParameter pname, GLint *params) {
  if (!ctx) return kCGLBadContext;
  if (!params) return kCGLBadAddress;
  AKGLContext *c = context(ctx);
  switch (pname) {
    case kCGLCPSwapInterval: params[0] = c->swapInterval; break;
    case kCGLCPSurfaceOpacity: params[0] = c->opacity; break;
    case kCGLCPSurfaceBackingSize: params[0] = c->width; params[1] = c->height; break;
    case kCGLCPCurrentRendererID: params[0] = kRendererID; break;
    case kCGLCPGPUVertexProcessing: case kCGLCPGPUFragmentProcessing: params[0] = 1; break;
    case kCGLCPHasDrawable: params[0] = c->view != nil; break;
    case kCGLCPMPSwapsInFlight: params[0] = 2; break;
    default: params[0] = 0;
  }
  return kCGLNoError;
}

CGLError CGLEnable(CGLContextObj ctx, CGLContextEnable pname) { return ctx ? kCGLNoError : kCGLBadContext; }
CGLError CGLDisable(CGLContextObj ctx, CGLContextEnable pname) { return ctx ? kCGLNoError : kCGLBadContext; }
CGLError CGLIsEnabled(CGLContextObj ctx, CGLContextEnable pname, GLint *enable) {
  if (enable) *enable = 0;
  return ctx ? kCGLNoError : kCGLBadContext;
}
CGLError CGLSetVirtualScreen(CGLContextObj ctx, GLint screen) { return ctx ? kCGLNoError : kCGLBadContext; }
CGLError CGLGetVirtualScreen(CGLContextObj ctx, GLint *screen) {
  if (screen) *screen = 0;
  return ctx ? kCGLNoError : kCGLBadContext;
}
CGLShareGroupObj CGLGetShareGroup(CGLContextObj ctx) { return (CGLShareGroupObj)ctx; }
CGLError CGLSetGlobalOption(CGLGlobalOption pname, const GLint *params) { return kCGLNoError; }
CGLError CGLGetGlobalOption(CGLGlobalOption pname, GLint *params) { if (params) *params = 0; return kCGLNoError; }
void CGLGetVersion(GLint *major, GLint *minor) { if (major) *major = 1; if (minor) *minor = 2; }

const char *CGLErrorString(CGLError error) {
  switch (error) {
    case kCGLNoError: return "no error";
    case kCGLBadAttribute: return "invalid pixel format attribute";
    case kCGLBadPixelFormat: return "invalid pixel format";
    case kCGLBadContext: return "invalid context";
    case kCGLBadDrawable: return "invalid drawable";
    case kCGLBadValue: return "invalid numerical value";
    case kCGLBadAddress: return "invalid pointer";
    case kCGLBadAlloc: return "invalid memory allocation";
    default: return "error";
  }
}

#pragma mark Renderer info

// One renderer: the iPhone's GPU, through Zink and Metal.
CGLError CGLQueryRendererInfo(GLuint displayMask, CGLRendererInfoObj *rend, GLint *nrend) {
  if (!rend) return kCGLBadAddress;
  *rend = (CGLRendererInfoObj)CFBridgingRetain([NSObject new]);
  if (nrend) *nrend = 1;
  return kCGLNoError;
}
CGLError CGLDestroyRendererInfo(CGLRendererInfoObj rend) { if (rend) CFRelease(rend); return kCGLNoError; }
CGLError CGLDescribeRenderer(CGLRendererInfoObj rend, GLint index, CGLRendererProperty prop, GLint *value) {
  if (!value) return kCGLBadAddress;
  if (index != 0) return kCGLBadValue;
  switch (prop) {
    case kCGLRPRendererID: *value = kRendererID; break;
    case kCGLRPAccelerated: case kCGLRPOnline: *value = 1; break;
    case kCGLRPRendererCount: *value = 1; break;
    case kCGLRPDisplayMask: *value = 1; break;
    case kCGLRPVideoMemoryMegabytes: case kCGLRPTextureMemoryMegabytes:
      *value = (GLint)(NSProcessInfo.processInfo.physicalMemory / 4 / (1024 * 1024));
      break;
    case kCGLRPMajorGLVersion: *value = 4; break;
    default: *value = 0;
  }
  return kCGLNoError;
}

#pragma mark Front and back buffers

// OSMesa's framebuffers are single-buffered: the back buffer a Mac game draws to is the front.
static GLenum toFront(GLenum buffer) {
  switch (buffer) {
    case GL_BACK: return GL_FRONT;
    case GL_BACK_LEFT: return GL_FRONT_LEFT;
    case GL_BACK_RIGHT: return GL_FRONT_RIGHT;
    default: return buffer;
  }
}

void glDrawBuffer(GLenum buffer) {
  GLint fbo = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
  MESA(void (*)(GLenum), glDrawBuffer)(fbo ? buffer : toFront(buffer));
}

void glReadBuffer(GLenum buffer) {
  GLint fbo = 0;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &fbo);
  MESA(void (*)(GLenum), glReadBuffer)(fbo ? buffer : toFront(buffer));
}

#pragma mark Apple's extensions

// GL_APPLE_vertex_array_object: the core vertex array objects.
void glGenVertexArraysAPPLE(GLsizei n, GLuint *arrays) { MESA(void (*)(GLsizei, GLuint *), glGenVertexArrays)(n, arrays); }
void glBindVertexArrayAPPLE(GLuint array) { MESA(void (*)(GLuint), glBindVertexArray)(array); }
void glDeleteVertexArraysAPPLE(GLsizei n, const GLuint *arrays) {
  MESA(void (*)(GLsizei, const GLuint *), glDeleteVertexArrays)(n, arrays);
}
GLboolean glIsVertexArrayAPPLE(GLuint array) { return MESA(GLboolean (*)(GLuint), glIsVertexArray)(array); }

// GL_APPLE_flush_render, GL_APPLE_flush_buffer_range and the hints that have no counterpart.
void glFlushRenderAPPLE(void) { glFlush(); }
void glFinishRenderAPPLE(void) { glFinish(); }
void glSwapAPPLE(void) { CGLFlushDrawable(CGLGetCurrentContext()); }
void glFlushMappedBufferRangeAPPLE(GLenum target, GLintptr offset, GLsizeiptr size) {
  MESA(void (*)(GLenum, GLintptr, GLsizeiptr), glFlushMappedBufferRange)(target, offset, size);
}
void glBufferParameteriAPPLE(GLenum target, GLenum pname, GLint param) {}
void glTextureRangeAPPLE(GLenum target, GLsizei length, const void *pointer) {}
void glVertexArrayRangeAPPLE(GLsizei length, void *pointer) {}
void glFlushVertexArrayRangeAPPLE(GLsizei length, void *pointer) {}
void glVertexArrayParameteriAPPLE(GLenum pname, GLint param) {}

// GL_APPLE_fence over sync objects.
static NSMutableDictionary<NSNumber *, NSValue *> *gFences;
static GLuint gNextFence = 1;

void glGenFencesAPPLE(GLsizei n, GLuint *fences) {
  @synchronized (NSNull.null) {
    if (!gFences) gFences = [NSMutableDictionary dictionary];
    for (GLsizei i = 0; i < n; i++) { fences[i] = gNextFence++; gFences[@(fences[i])] = [NSValue valueWithPointer:NULL]; }
  }
}
static GLsync fenceSync(GLuint fence) {
  @synchronized (NSNull.null) { return (GLsync)gFences[@(fence)].pointerValue; }
}
static void setFenceSync(GLuint fence, GLsync sync) {
  GLsync old = fenceSync(fence);
  if (old) MESA(void (*)(GLsync), glDeleteSync)(old);
  @synchronized (NSNull.null) { gFences[@(fence)] = [NSValue valueWithPointer:sync]; }
}
void glDeleteFencesAPPLE(GLsizei n, const GLuint *fences) {
  for (GLsizei i = 0; i < n; i++) {
    setFenceSync(fences[i], NULL);
    @synchronized (NSNull.null) { [gFences removeObjectForKey:@(fences[i])]; }
  }
}
void glSetFenceAPPLE(GLuint fence) {
  setFenceSync(fence, MESA(GLsync (*)(GLenum, GLuint), glFenceSync)(GL_SYNC_GPU_COMMANDS_COMPLETE, 0));
}
GLboolean glIsFenceAPPLE(GLuint fence) { @synchronized (NSNull.null) { return gFences[@(fence)] != nil; } }
GLboolean glTestFenceAPPLE(GLuint fence) {
  GLsync sync = fenceSync(fence);
  if (!sync) return 1;
  GLenum r = MESA(GLenum (*)(GLsync, GLuint, GLuint64), glClientWaitSync)(sync, 0, 0);
  return r == GL_ALREADY_SIGNALED || r == GL_CONDITION_SATISFIED;
}
void glFinishFenceAPPLE(GLuint fence) {
  GLsync sync = fenceSync(fence);
  if (sync) MESA(GLenum (*)(GLsync, GLuint, GLuint64), glClientWaitSync)(sync, GL_SYNC_FLUSH_COMMANDS_BIT, UINT64_MAX);
}
GLboolean glTestObjectAPPLE(GLenum object, GLuint name) { glFinish(); return 1; }
void glFinishObjectAPPLE(GLenum object, GLint name) { glFinish(); }

#pragma mark GLU

void gluOrtho2D(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top) {
  glOrtho(left, right, bottom, top, -1, 1);
}

void gluPerspective(GLdouble fovy, GLdouble aspect, GLdouble zNear, GLdouble zFar) {
  GLdouble f = 1.0 / tan(fovy * M_PI / 360.0);
  GLdouble m[16] = { f / aspect, 0, 0, 0,  0, f, 0, 0,
                     0, 0, (zFar + zNear) / (zNear - zFar), -1,  0, 0, 2 * zFar * zNear / (zNear - zFar), 0 };
  glMultMatrixd(m);
}

void gluLookAt(GLdouble ex, GLdouble ey, GLdouble ez, GLdouble cx, GLdouble cy, GLdouble cz,
               GLdouble ux, GLdouble uy, GLdouble uz) {
  GLdouble f[3] = { cx - ex, cy - ey, cz - ez };
  GLdouble fl = sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
  if (fl == 0) return;
  for (int i = 0; i < 3; i++) f[i] /= fl;
  GLdouble s[3] = { f[1] * uz - f[2] * uy, f[2] * ux - f[0] * uz, f[0] * uy - f[1] * ux };
  GLdouble sl = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
  if (sl == 0) return;
  for (int i = 0; i < 3; i++) s[i] /= sl;
  GLdouble u[3] = { s[1] * f[2] - s[2] * f[1], s[2] * f[0] - s[0] * f[2], s[0] * f[1] - s[1] * f[0] };
  GLdouble m[16] = { s[0], u[0], -f[0], 0,  s[1], u[1], -f[1], 0,  s[2], u[2], -f[2], 0,  0, 0, 0, 1 };
  glMultMatrixd(m);
  glTranslated(-ex, -ey, -ez);
}

const GLubyte *gluErrorString(GLenum error) {
  switch (error) {
    case GL_NO_ERROR: return (const GLubyte *)"no error";
    case GL_INVALID_ENUM: return (const GLubyte *)"invalid enumerant";
    case GL_INVALID_VALUE: return (const GLubyte *)"invalid value";
    case GL_INVALID_OPERATION: return (const GLubyte *)"invalid operation";
    case GL_STACK_OVERFLOW: return (const GLubyte *)"stack overflow";
    case GL_STACK_UNDERFLOW: return (const GLubyte *)"stack underflow";
    case GL_OUT_OF_MEMORY: return (const GLubyte *)"out of memory";
    case GL_INVALID_FRAMEBUFFER_OPERATION: return (const GLubyte *)"invalid framebuffer operation";
    default: return NULL;
  }
}

const GLubyte *gluGetString(GLenum name) {
  if (name == 100800) return (const GLubyte *)"1.3";   // GLU_VERSION
  if (name == 100801) return (const GLubyte *)"";      // GLU_EXTENSIONS
  return NULL;
}

GLboolean gluCheckExtension(const GLubyte *extName, const GLubyte *extString) {
  if (!extName || !extString) return 0;
  size_t n = strlen((const char *)extName);
  for (const char *p = (const char *)extString; (p = strstr(p, (const char *)extName)); p += n)
    if ((p == (const char *)extString || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0')) return 1;
  return 0;
}

GLint gluBuild2DMipmaps(GLenum target, GLint internalFormat, GLsizei width, GLsizei height, GLenum format,
                        GLenum type, const void *data) {
  glTexImage2D(target, 0, internalFormat, width, height, 0, format, type, data);
  MESA(void (*)(GLenum), glGenerateMipmap)(target);
  return 0;
}
