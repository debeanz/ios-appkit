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
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <string.h>
#import "SDLMetalShaders.h"

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
