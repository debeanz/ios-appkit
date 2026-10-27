// libSystem functions that exist on macOS but not iOS. The iOS libc headers already declare
// most of these (as unavailable), so each shim uses an AK-prefixed C name and exports the real
// symbol through an asm label, with plain types.
//
// The dynamic-loading group cannot work on iOS: every executable page must be backed by a
// signed file, so a Mach-O image can't be loaded from a memory buffer. The shim makes those
// calls fail, cleanly, so a client that tries degrades to "this isn't available" instead of
// crashing on a missing symbol. The rest (JIT write-protect, process responsibility, extended
// syslog) have simple honest behaviours.
#import <Foundation/Foundation.h>

// NSObjectFileImageReturnCode / result the Mac API uses; the shim only ever returns failure.
enum { AKNSObjectFileImageFailure = 0, AKNSObjectFileImageSuccess = 1, AKNSObjectFileImageInappropriateFile = 2 };

// Loading a Mach-O image from memory: refused on iOS (returns the "inappropriate file" code).
int AKNSCreateObjectFileImageFromMemory(const void *address, size_t size, void **objectFileImage)
    __asm__("_NSCreateObjectFileImageFromMemory");
bool AKNSDestroyObjectFileImage(void *objectFileImage) __asm__("_NSDestroyObjectFileImage");
void *AKNSLinkModule(void *objectFileImage, const char *moduleName, uint32_t options) __asm__("_NSLinkModule");
bool AKNSUnLinkModule(void *module, uint32_t options) __asm__("_NSUnLinkModule");
void *AKNSLookupSymbolInModule(void *module, const char *symbolName) __asm__("_NSLookupSymbolInModule");
void *AKNSAddressOfSymbol(void *symbol) __asm__("_NSAddressOfSymbol");

// JIT write-protection toggle (Apple-silicon macOS). Where it's needed, the host's JIT setup
// maps code memory as writable+executable at once, so toggling is a no-op.
void AKPthreadJitWriteProtectNp(int enabled) __asm__("_pthread_jit_write_protect_np");

// Process "responsibility" (privacy attribution of one process to another). Every iOS process
// is its own responsible process.
pid_t AKResponsibilityGetPidResponsibleForPid(pid_t pid) __asm__("_responsibility_get_pid_responsible_for_pid");
int AKResponsibilitySpawnattrsSetdisclaim(void *attrs, bool disclaim) __asm__("_responsibility_spawnattrs_setdisclaim");

// The extended-format variant of syslog; behaves like syslog.
void AKSyslogDarwinExtsn(int priority, const char *format, ...) __asm__("_syslog$DARWIN_EXTSN");

// The process's executable path, as a client loaded through this shim sees it. Mac apps find
// their own files next to their executable (Steam's tier0 loads filesystem_stdio.dylib,
// vgui2_s.dylib ... from the directory _NSGetExecutablePath names). Hosted on iOS — under
// LiveContainer the process's executable is LiveContainer itself — that is the wrong
// directory, so the host names the executable the client would have had on a Mac in the
// AK_EXECUTABLE_PATH environment variable and this answers with it. Without the variable it
// defers to the real call. Only clients bound through the shim see this; system frameworks
// keep the real answer.
int AKNSGetExecutablePath(char *buf, uint32_t *bufsize) __asm__("__NSGetExecutablePath");
