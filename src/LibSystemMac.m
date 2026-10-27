// See LibSystemMac.h.
#import "AKShimPrivate.h"
#import "AppKitShim/LibSystemMac.h"
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
