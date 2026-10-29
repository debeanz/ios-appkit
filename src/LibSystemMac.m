// See LibSystemMac.h.
#import "AKShimPrivate.h"
#import "AppKitShim/LibSystemMac.h"
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <syslog.h>
#import <stdarg.h>

#pragma mark Dynamic loading — refused on iOS

// iOS will not create executable memory from an arbitrary buffer: code must come from a signed
// file. So there is no way to honour these, and the honest result is failure. Nothing is loaded,
// linked or executed; callers fall back to their "can't load this" path.
int AKNSCreateObjectFileImageFromMemory(const void *address, size_t size, void **objectFileImage) {
  if (objectFileImage) *objectFileImage = NULL;
  return AKNSObjectFileImageInappropriateFile;
}
bool AKNSDestroyObjectFileImage(void *objectFileImage) { return true; }
void *AKNSLinkModule(void *objectFileImage, const char *moduleName, uint32_t options) { return NULL; }
bool AKNSUnLinkModule(void *module, uint32_t options) { return true; }
void *AKNSLookupSymbolInModule(void *module, const char *symbolName) { return NULL; }
void *AKNSAddressOfSymbol(void *symbol) { return NULL; }

#pragma mark JIT write-protection

void AKPthreadJitWriteProtectNp(int enabled) { /* RWX JIT memory: nothing to toggle */ }

void AKClearCache(void *start, void *end) {
  if (end > start) sys_icache_invalidate(start, (size_t)((char *)end - (char *)start));
}

#pragma mark Process responsibility

pid_t AKResponsibilityGetPidResponsibleForPid(pid_t pid) { return pid; }
int AKResponsibilitySpawnattrsSetdisclaim(void *attrs, bool disclaim) { return 0; }

#pragma mark syslog

void AKSyslogDarwinExtsn(int priority, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  vsyslog(priority, format, ap);
  va_end(ap);
}

#pragma mark Executable path

// Same contract as dyld's: copy the path and return 0, or, when the buffer is too small,
// store the size needed in *bufsize and return -1.
int AKNSGetExecutablePath(char *buf, uint32_t *bufsize) {
  const char *path = getenv("AK_EXECUTABLE_PATH");
  if (!path || !*path) {
    // Not configured: the real answer. This file's own symbol shadows the name, so look the
    // real one up in libSystem.
    static int (*real)(char *, uint32_t *);
    if (!real) {
      void *libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
      real = libSystem ? (int (*)(char *, uint32_t *))dlsym(libSystem, "_NSGetExecutablePath") : NULL;
    }
    return real ? real(buf, bufsize) : -1;
  }
  uint32_t need = (uint32_t)strlen(path) + 1;
  if (!bufsize || *bufsize < need) {
    if (bufsize) *bufsize = need;
    return -1;
  }
  memcpy(buf, path, need);
  return 0;
}
