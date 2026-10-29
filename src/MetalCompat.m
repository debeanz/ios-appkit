// Metal code built for the Mac, running on an iPhone.
//
// SDL's Metal renderer (which the web helper's Big Picture window presents through) carries
// its shaders as a precompiled .metallib, and the Mac build carries the macOS one. iOS's Metal
// opens that library but hands back no functions from it, so the first pipeline SDL builds
// aborts with "vertexFunction must not be nil". When a library that is SDL's fails that way,
// the shim compiles SDL's own shader source (SDLMetalShaders.h, same SDL commit) for this
// device instead and returns that.
//
// The same renderer also sets CAMetalLayer.displaySyncEnabled, a macOS-only property; iOS
// layers get a stand-in that remembers the value (iOS always syncs to the display).
//
// And what Mac games' own Metal code needs (AKGameMetalPrepare, at the end).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import "SDLMetalShaders.h"
#import "AKShimPrivate.h"

static IMP gNewLibraryWithData;

static BOOL dataNamesSDLShaders(dispatch_data_t data) {
  const void *bytes = NULL;
  size_t size = 0;
  dispatch_data_t flat = dispatch_data_create_map(data, &bytes, &size);
  BOOL found = flat && memmem(bytes, size, "SDL_Copy_vertex", 15) != NULL;
  (void)flat; // keeps the mapping alive until here
  return found;
}

static id<MTLLibrary> sdlLibraryForDevice(id<MTLDevice> device, NSError **error) {
  static NSMapTable *compiled; // device -> library
  @synchronized([NSObject class]) {
    if (!compiled) compiled = [NSMapTable weakToStrongObjectsMapTable];
    id<MTLLibrary> lib = [compiled objectForKey:device];
    if (lib) return lib;
    NSError *err = nil;
    lib = [device newLibraryWithSource:@(kSDLMetalShaderSource) options:[MTLCompileOptions new] error:&err];
    if (lib) {
      [compiled setObject:lib forKey:device];
      fprintf(stderr, "[AppKitShim] SDL's macOS Metal shaders don't load on iOS; compiled SDL's shader source for this device instead\n");
    } else {
      fprintf(stderr, "[AppKitShim] compiling SDL's Metal shader source failed: %s\n", err.localizedDescription.UTF8String ?: "?");
      if (error) *error = err;
    }
    return lib;
  }
}

static id akNewLibraryWithData(id self, SEL _cmd, dispatch_data_t data, NSError **error) {
  id<MTLLibrary> lib = ((id (*)(id, SEL, dispatch_data_t, NSError **))gNewLibraryWithData)(self, _cmd, data, error);
  if (lib && [lib newFunctionWithName:@"SDL_Copy_vertex"]) return lib;
  if (!data || !dataNamesSDLShaders(data)) return lib;
  id<MTLLibrary> replacement = sdlLibraryForDevice(self, error);
  if (!replacement) return lib;
  if (error) *error = nil;
  return replacement;
}

static BOOL displaySyncEnabledGet(id self, SEL _cmd) {
  NSNumber *v = objc_getAssociatedObject(self, @selector(displaySyncEnabled));
  return v ? v.boolValue : YES;
}

static void displaySyncEnabledSet(id self, SEL _cmd, BOOL value) {
  objc_setAssociatedObject(self, @selector(displaySyncEnabled), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor)) static void installMetalCompat(void) {
  @autoreleasepool {
    Class layer = [CAMetalLayer class];
    SEL get = NSSelectorFromString(@"displaySyncEnabled"), set = NSSelectorFromString(@"setDisplaySyncEnabled:");
    if (![layer instancesRespondToSelector:get]) class_addMethod(layer, get, (IMP)displaySyncEnabledGet, "B@:");
    if (![layer instancesRespondToSelector:set]) class_addMethod(layer, set, (IMP)displaySyncEnabledSet, "v@:B");

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    Method m = class_getInstanceMethod([device class], @selector(newLibraryWithData:error:));
    if (!m) return;
    // Replace on the device's own class so only that class changes even when the method is
    // inherited.
    gNewLibraryWithData = method_getImplementation(m);
    if (!class_addMethod([device class], @selector(newLibraryWithData:error:), (IMP)akNewLibraryWithData, method_getTypeEncoding(m)))
      method_setImplementation(m, (IMP)akNewLibraryWithData);
  }
}

#pragma mark Metal as a Mac game uses it

// What a Mac game's Metal code asks of a Mac GPU that the same Apple GPU answers differently on
// iOS, learned running Tunic's Mac build (debeanz/tunic-ios-port); prepared before a game's
// first launch (AKGameMetalPrepare):
// - Managed storage (a CPU and a GPU copy kept in sync) is macOS-only; iOS memory is shared by
//   both. Buffers, textures and heap resources asked for as Managed are made Shared.
// - What syncs managed memory (didModifyRange:, synchronizeResource:,
//   synchronizeTexture:slice:level:) then has nothing to do, and textureBarrier becomes the
//   iOS barrier between fragment passes. A class lacking one gets it; one that has it (iOS 27's
//   driver classes implement them only to abort, "not supported on this platform") gets it
//   replaced.
// - A Mac player checks the macOS feature sets and Mac GPU families before it makes its Metal
//   device (Unity's falls back to drawing nothing). Asked from a game's own code, those answer
//   YES; anyone else gets the GPU's real answer.
// - Device properties only Macs have (headless, low power, removable, location, D24S8 depth)
//   answer as for a Mac's built-in GPU.

static IMP gBufLen, gBufBytes, gBufNoCopy, gDevTex, gBufTex, gHeapBuf, gHeapTex, gFeatureSet, gFamily;
static _Atomic int gManagedSeen;

enum { kStorageManaged = 1 };   // MTLStorageModeManaged, which iOS's headers don't declare

static NSUInteger sharedOptions(NSUInteger o, const char *what) {
  if (((o & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift) != kStorageManaged) return o;
  if (gManagedSeen++ < 3) fprintf(stderr, "[AppKitShim] Metal: a %s asked for Managed storage (macOS only): made Shared\n", what);
  return (o & ~MTLResourceStorageModeMask) | MTLResourceStorageModeShared;
}

static void sharedDescriptor(MTLTextureDescriptor *d, const char *what) {
  if (!d || (NSUInteger)d.storageMode != kStorageManaged) return;
  if (gManagedSeen++ < 3) fprintf(stderr, "[AppKitShim] Metal: a %s asked for Managed storage (macOS only): made Shared\n", what);
  d.storageMode = MTLStorageModeShared;
}

static id akBufLen(id self, SEL c, NSUInteger len, NSUInteger o) {
  return ((id (*)(id, SEL, NSUInteger, NSUInteger))gBufLen)(self, c, len, sharedOptions(o, "buffer"));
}
static id akBufBytes(id self, SEL c, const void *p, NSUInteger len, NSUInteger o) {
  return ((id (*)(id, SEL, const void *, NSUInteger, NSUInteger))gBufBytes)(self, c, p, len, sharedOptions(o, "buffer"));
}
static id akBufNoCopy(id self, SEL c, void *p, NSUInteger len, NSUInteger o, id deallocator) {
  return ((id (*)(id, SEL, void *, NSUInteger, NSUInteger, id))gBufNoCopy)(self, c, p, len, sharedOptions(o, "buffer"), deallocator);
}
static id akDevTex(id self, SEL c, MTLTextureDescriptor *d) {
  sharedDescriptor(d, "texture");
  return ((id (*)(id, SEL, id))gDevTex)(self, c, d);
}
static id akBufTex(id self, SEL c, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bytesPerRow) {
  sharedDescriptor(d, "texture over a buffer");
  return ((id (*)(id, SEL, id, NSUInteger, NSUInteger))gBufTex)(self, c, d, offset, bytesPerRow);
}
static id akHeapBuf(id self, SEL c, NSUInteger len, NSUInteger o) {
  return ((id (*)(id, SEL, NSUInteger, NSUInteger))gHeapBuf)(self, c, len, sharedOptions(o, "heap buffer"));
}
static id akHeapTex(id self, SEL c, MTLTextureDescriptor *d) {
  sharedDescriptor(d, "heap texture");
  return ((id (*)(id, SEL, id))gHeapTex)(self, c, d);
}

static void macNoop1(id self, SEL _cmd, id a) {}
static void macNoopSync3(id self, SEL _cmd, id texture, NSUInteger slice, NSUInteger level) {}
static void macNoopRange(id self, SEL _cmd, NSRange range) {}
static void macTextureBarrier(id self, SEL _cmd) {
  ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(memoryBarrierWithScope:afterStages:beforeStages:),
      MTLBarrierScopeTextures, MTLRenderStageFragment, MTLRenderStageFragment);
}
static BOOL macNo(id self, SEL _cmd) { return NO; }
static NSUInteger macZero(id self, SEL _cmd) { return 0; }
static uint32_t macZero32(id self, SEL _cmd) { return 0; }
static uint32_t macOne32(id self, SEL _cmd) { return 1; }
static uint64_t macZero64(id self, SEL _cmd) { return 0; }

static BOOL akSupportsFeatureSet(id self, SEL _cmd, NSUInteger set) {
  if (set >= 10000 && set < 11000 && AKAddressIsInGame(__builtin_return_address(0))) return YES;   // MTLFeatureSet_macOS_*
  return ((BOOL (*)(id, SEL, NSUInteger))gFeatureSet)(self, _cmd, set);
}
static BOOL akSupportsFamily(id self, SEL _cmd, NSInteger family) {
  BOOL mac = family == 2001 || family == 2002 || family == 4001 || family == 4002;   // Mac1, Mac2, MacCatalyst1, MacCatalyst2
  if (mac && AKAddressIsInGame(__builtin_return_address(0))) return YES;
  return ((BOOL (*)(id, SEL, NSInteger))gFamily)(self, _cmd, family);
}

static IMP swapIn(Class c, SEL s, IMP imp) {
  Method m = c ? class_getInstanceMethod(c, s) : NULL;
  if (!m) return NULL;
  IMP old = method_getImplementation(m);
  // Replaced on the class itself even when it inherits the method, so only it changes.
  if (!class_addMethod(c, s, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
  return old;
}

static void addIfMissing(Class c, SEL s, IMP imp, const char *types) {
  if (c && !class_respondsToSelector(c, s)) class_addMethod(c, s, imp, types);
}

void AKGameMetalPrepare(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    Class D = object_getClass(dev);
    gBufLen = swapIn(D, @selector(newBufferWithLength:options:), (IMP)akBufLen);
    gBufBytes = swapIn(D, @selector(newBufferWithBytes:length:options:), (IMP)akBufBytes);
    gBufNoCopy = swapIn(D, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), (IMP)akBufNoCopy);
    gDevTex = swapIn(D, @selector(newTextureWithDescriptor:), (IMP)akDevTex);
    gFeatureSet = swapIn(D, NSSelectorFromString(@"supportsFeatureSet:"), (IMP)akSupportsFeatureSet);
    gFamily = swapIn(D, @selector(supportsFamily:), (IMP)akSupportsFamily);
    id<MTLBuffer> buffer = [dev newBufferWithLength:16384 options:MTLResourceStorageModeShared];
    gBufTex = swapIn(object_getClass(buffer), @selector(newTextureWithDescriptor:offset:bytesPerRow:), (IMP)akBufTex);
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
    hd.size = 1 << 16;
    hd.storageMode = MTLStorageModePrivate;
    id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
    if (heap) {
      gHeapBuf = swapIn(object_getClass(heap), @selector(newBufferWithLength:options:), (IMP)akHeapBuf);
      gHeapTex = swapIn(object_getClass(heap), @selector(newTextureWithDescriptor:), (IMP)akHeapTex);
    }

    // The concrete classes a game's calls land on, made once: a buffer, a blit encoder, a render
    // encoder and a parallel encoder's sub-encoder.
    addIfMissing(object_getClass(buffer), @selector(didModifyRange:), (IMP)macNoopRange, "v@:{_NSRange=QQ}");
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    addIfMissing(object_getClass(blit), NSSelectorFromString(@"synchronizeResource:"), (IMP)macNoop1, "v@:@");
    addIfMissing(object_getClass(blit), NSSelectorFromString(@"synchronizeTexture:slice:level:"), (IMP)macNoopSync3, "v@:@QQ");
    [blit endEncoding];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    id<MTLRenderCommandEncoder> render = [cb renderCommandEncoderWithDescriptor:pass];
    if (render) {
      addIfMissing(object_getClass(render), NSSelectorFromString(@"textureBarrier"), (IMP)macTextureBarrier, "v@:");
      [render endEncoding];
    }
    id<MTLParallelRenderCommandEncoder> parallel = [cb parallelRenderCommandEncoderWithDescriptor:pass];
    if (parallel) {
      id<MTLRenderCommandEncoder> sub = [parallel renderCommandEncoder];
      if (sub) {
        addIfMissing(object_getClass(sub), NSSelectorFromString(@"textureBarrier"), (IMP)macTextureBarrier, "v@:");
        [sub endEncoding];
      }
      [parallel endEncoding];
    }
    [cb commit];

    // Every class that implements one of them itself (iOS's own, which abort) gets the safe one.
    struct { SEL sel; IMP imp; } safe[] = {
      { NSSelectorFromString(@"synchronizeResource:"), (IMP)macNoop1 },
      { NSSelectorFromString(@"synchronizeTexture:slice:level:"), (IMP)macNoopSync3 },
      { NSSelectorFromString(@"didModifyRange:"), (IMP)macNoopRange },
      { NSSelectorFromString(@"textureBarrier"), (IMP)macTextureBarrier },
    };
    int replaced = 0, count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
      const char *name = class_getName(classes[i]);
      if (!strstr(name, "MTL") && !strstr(name, "AGX") && !strstr(name, "IOGPU") && !strstr(name, "Encoder") && !strstr(name, "Buffer")) continue;
      unsigned n = 0;
      Method *methods = class_copyMethodList(classes[i], &n);   // only what the class defines itself
      for (unsigned j = 0; j < n; j++)
        for (size_t k = 0; k < sizeof safe / sizeof safe[0]; k++)
          if (method_getName(methods[j]) == safe[k].sel && method_getImplementation(methods[j]) != safe[k].imp) {
            method_setImplementation(methods[j], safe[k].imp);
            replaced++;
          }
      free(methods);
    }
    free(classes);

    addIfMissing(D, NSSelectorFromString(@"isHeadless"), (IMP)macNo, "B@:");
    addIfMissing(D, NSSelectorFromString(@"isLowPower"), (IMP)macNo, "B@:");
    addIfMissing(D, NSSelectorFromString(@"isRemovable"), (IMP)macNo, "B@:");
    addIfMissing(D, NSSelectorFromString(@"isDepth24Stencil8PixelFormatSupported"), (IMP)macNo, "B@:");
    addIfMissing(D, NSSelectorFromString(@"depth24Stencil8PixelFormatSupported"), (IMP)macNo, "B@:");
    addIfMissing(D, NSSelectorFromString(@"location"), (IMP)macZero, "Q@:");          // MTLDeviceLocationBuiltIn
    addIfMissing(D, NSSelectorFromString(@"locationNumber"), (IMP)macZero, "Q@:");
    addIfMissing(D, NSSelectorFromString(@"maxTransferRate"), (IMP)macZero64, "Q@:");
    addIfMissing(D, NSSelectorFromString(@"peerGroupID"), (IMP)macZero64, "Q@:");
    addIfMissing(D, NSSelectorFromString(@"peerIndex"), (IMP)macZero32, "I@:");
    addIfMissing(D, NSSelectorFromString(@"peerCount"), (IMP)macOne32, "I@:");
    SEL bcSel = NSSelectorFromString(@"supportsBCTextureCompression");   // iOS 16.4
    BOOL bc = [dev respondsToSelector:bcSel] && ((BOOL (*)(id, SEL))objc_msgSend)(dev, bcSel);
    fprintf(stderr, "[AppKitShim] Metal for Mac games on %s: Managed storage made Shared, %d macOS-only calls made safe, "
            "Mac feature sets and GPU families answered for games; BC textures %s\n", dev.name.UTF8String, replaced,
            bc ? "supported" : "not supported");
  }});
}
