// In-process child processes.
//
// A Mac app launches the helper programs it ships (posix_spawn, or fork + exec); iOS won't
// start a process at all. For a helper that ships inside the app, the shim does the next best
// thing: it loads the helper's executable into this process as a library (the packager turns
// it into one, the way LiveContainer loads app executables), runs its main() on a thread of
// its own, and hands the caller a stand-in pid that kill/waitpid/waitid answer for. The helper
// then runs much as its own process would, minus the isolation: it shares this address space,
// the environment and every library both of them load.
//
// Runnable in-process means: an MH_DYLIB that still carries LC_MAIN, i.e. an executable the
// packager converted. posix_spawn/posix_spawnp of one runs it here; anything else goes to the
// real call (which iOS refuses). Code that launches by fork + exec (Valve's tier0) can't be
// emulated at that level, so the host rebinds its launcher with AKRebindSymbol and calls
// AKSpawnInProcess itself. libSystem is routed through the shim umbrella (which lists this
// code before the real libSystem), so the client's process calls bind here.
#import <Foundation/Foundation.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <pthread.h>
#import <signal.h>
#import <spawn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/wait.h>
#import <unistd.h>

// Above PID_MAX (99999), so a stand-in never collides with a real process.
#define AK_VPID_BASE 100000
#define AK_VPROC_MAX 64
#define AK_MAX_EXTRA 64

typedef struct {
  int inUse;
  pid_t pid;
  int running;
  int status;                    // main()'s return value or exit() code, once finished
  pthread_t thread;
  char path[PATH_MAX];
  char cwd[PATH_MAX];
  int argc;
  char **argv;
  char **envp;
  int (*entry)(int, char **, char **, char **);
} ak_vproc;

static ak_vproc gProcs[AK_VPROC_MAX];
static pid_t gNextPid = AK_VPID_BASE;
static pthread_mutex_t gProcLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gProcExited = PTHREAD_COND_INITIALIZER;
static __thread ak_vproc *tCurrentProc;     // set on a stand-in process's main thread

// Extra arguments appended for an executable, by file name (AKInProcessSetExtraArgs).
static struct { char name[256]; char *args[AK_MAX_EXTRA]; int count; } gExtra[8];
static int gExtraCount;

pid_t AKSpawnInProcess(const char *path, char *const argv[], char *const envp[], const char *cwd);
int AKIsInProcessExecutable(const char *path);
void AKInProcessSetExtraArgs(const char *name, const char *const *args);
int AKRebindSymbol(const char *pathPrefix, const char *symbol, void *replacement);

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr, char *const argv[], char *const envp[]);
int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[]);
int kill(pid_t pid, int sig);
pid_t waitpid(pid_t pid, int *status, int options);
int waitid(idtype_t idtype, id_t id, siginfo_t *info, int options);
void exit(int status);
void _exit(int status);

#pragma mark Real libSystem

// This file's own definitions shadow these names for every image routed through the shim,
// this one included, so the real calls are looked up in libSystem.
static void *realSym(const char *name) {
  static void *libSystem;
  if (!libSystem) libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
  return libSystem ? dlsym(libSystem, name) : NULL;
}
#define REAL(type, name) ((type)realSym(#name))

static void shimLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void shimLog(const char *fmt, ...) {
  char line[2048];
  va_list ap; va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  fprintf(stderr, "[AppKitShim] %s\n", line);
}

static const char *baseName(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

#pragma mark Which files run in-process

// A thin arm64 MH_DYLIB with LC_MAIN: an executable the packager made loadable. Returns the
// LC_MAIN entry offset, or 0.
static uint64_t loadableEntryOffset(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 0;
  struct mach_header_64 mh;
  uint64_t entry = 0;
  if (pread(fd, &mh, sizeof mh, 0) == sizeof mh && mh.magic == MH_MAGIC_64 && mh.filetype == MH_DYLIB &&
      mh.sizeofcmds < 16 * 1024 * 1024) {
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (cmds && pread(fd, cmds, mh.sizeofcmds, sizeof mh) == (ssize_t)mh.sizeofcmds) {
      uint32_t off = 0;
      for (uint32_t i = 0; i < mh.ncmds && off + sizeof(struct load_command) <= mh.sizeofcmds; i++) {
        struct load_command *lc = (struct load_command *)(cmds + off);
        if (lc->cmd == LC_MAIN) entry = ((struct entry_point_command *)lc)->entryoff;
        if (lc->cmdsize == 0) break;
        off += lc->cmdsize;
      }
    }
    free(cmds);
  }
  close(fd);
  return entry;
}

int AKIsInProcessExecutable(const char *path) {
  return path && loadableEntryOffset(path) != 0;
}

void AKInProcessSetExtraArgs(const char *name, const char *const *args) {
  pthread_mutex_lock(&gProcLock);
  int slot = -1;
  for (int i = 0; i < gExtraCount; i++) if (strcmp(gExtra[i].name, name) == 0) slot = i;
  if (slot < 0 && gExtraCount < (int)(sizeof gExtra / sizeof gExtra[0])) slot = gExtraCount++;
  if (slot >= 0) {
    strlcpy(gExtra[slot].name, name, sizeof gExtra[slot].name);
    for (int i = 0; i < gExtra[slot].count; i++) free(gExtra[slot].args[i]);
    gExtra[slot].count = 0;
    for (int i = 0; args && args[i] && i < AK_MAX_EXTRA; i++) gExtra[slot].args[gExtra[slot].count++] = strdup(args[i]);
  }
  pthread_mutex_unlock(&gProcLock);
}

#pragma mark Running one

static const struct mach_header_64 *loadedHeader(const char *path) {
  char want[PATH_MAX];
  if (!realpath(path, want)) strlcpy(want, path, sizeof want);
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    char got[PATH_MAX];
    if (name && realpath(name, got) && strcmp(got, want) == 0)
      return (const struct mach_header_64 *)_dyld_get_image_header(i);
  }
  return NULL;
}

static void finishProc(ak_vproc *p, int status) {
  pthread_mutex_lock(&gProcLock);
  p->status = status;
  p->running = 0;
  pthread_cond_broadcast(&gProcExited);
  pthread_mutex_unlock(&gProcLock);
  shimLog("in-process %s (pid %d) exited with %d", baseName(p->path), p->pid, status);
}

static void *procMain(void *arg) {
  ak_vproc *p = arg;
  tCurrentProc = p;
  pthread_setname_np(baseName(p->path));
  // The working directory the launcher asked for, for this thread only (a process-wide
  // chdir would move the client too).
  if (p->cwd[0]) {
    int (*threadChdir)(const char *) = (int (*)(const char *))dlsym(RTLD_DEFAULT, "pthread_chdir_np");
    if (!threadChdir) threadChdir = (int (*)(const char *))dlsym(RTLD_DEFAULT, "__pthread_chdir");
    int rc = threadChdir ? threadChdir(p->cwd) : -1;
    shimLog("in-process pid %d: working directory %s %s", p->pid, p->cwd,
            rc == 0 ? "(this thread)" : threadChdir ? strerror(errno) : "(no per-thread chdir; using the app's)");
  }
  char execPath[PATH_MAX + 32];
  snprintf(execPath, sizeof execPath, "executable_path=%s", p->path);
  char *apple[] = { execPath, NULL };
  int status;
  @autoreleasepool {
    status = p->entry(p->argc, p->argv, p->envp, apple);
  }
  finishProc(p, status);
  return NULL;
}

pid_t AKSpawnInProcess(const char *path, char *const argv[], char *const envp[], const char *cwd) {
  uint64_t entryoff = loadableEntryOffset(path);
  if (!entryoff) { errno = ENOEXEC; return -1; }
  const char *name = baseName(path);

  // A Chromium subprocess (renderer, GPU, utility) needs a process of its own; CEF has to
  // run single-process here, so refuse rather than start a second engine in this one.
  for (int i = 0; argv && argv[i]; i++) {
    if (strncmp(argv[i], "--type=", 7) == 0) {
      shimLog("refusing in-process %s %s: Chromium subprocesses need --single-process", name, argv[i]);
      errno = EPERM;
      return -1;
    }
  }

  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) { shimLog("in-process %s: dlopen failed: %s", name, dlerror()); errno = ENOEXEC; return -1; }
  const struct mach_header_64 *mh = loadedHeader(path);
  if (!mh) { shimLog("in-process %s: loaded but its image isn't listed", name); errno = ENOEXEC; return -1; }

  pthread_mutex_lock(&gProcLock);
  ak_vproc *p = NULL;
  for (int i = 0; i < AK_VPROC_MAX; i++) if (!gProcs[i].inUse) { p = &gProcs[i]; break; }
  if (!p) { pthread_mutex_unlock(&gProcLock); errno = EAGAIN; return -1; }
  memset(p, 0, sizeof *p);
  p->inUse = 1;
  p->running = 1;
  p->pid = gNextPid++;
  strlcpy(p->path, path, sizeof p->path);
  if (cwd) strlcpy(p->cwd, cwd, sizeof p->cwd);
  p->entry = (int (*)(int, char **, char **, char **))((const char *)mh + entryoff);

  // argv (plus any extra arguments registered for this executable), copied: the caller's
  // arrays don't outlive the call.
  int argc = 0;
  while (argv && argv[argc]) argc++;
  int extra = 0;
  char **extraArgs = NULL;
  for (int i = 0; i < gExtraCount; i++)
    if (strcmp(gExtra[i].name, name) == 0) { extra = gExtra[i].count; extraArgs = gExtra[i].args; }
  p->argv = calloc(argc + extra + 2, sizeof(char *));
  p->argv[0] = strdup(argc ? argv[0] : path);
  for (int i = 1; i < argc; i++) p->argv[i] = strdup(argv[i]);
  for (int i = 0; i < extra; i++) p->argv[(argc ? argc : 1) + i] = strdup(extraArgs[i]);
  p->argc = (argc ? argc : 1) + extra;
  pthread_mutex_unlock(&gProcLock);

  // There is one environment per process. Give the helper the variables it was meant to get
  // without overriding any the app already has.
  int envCount = 0;
  for (int i = 0; envp && envp[i]; i++) {
    const char *eq = strchr(envp[i], '=');
    if (!eq || eq == envp[i]) continue;
    char key[256];
    size_t klen = (size_t)(eq - envp[i]);
    if (klen >= sizeof key) continue;
    memcpy(key, envp[i], klen); key[klen] = 0;
    if (!getenv(key)) { setenv(key, eq + 1, 0); envCount++; }
  }
  p->envp = *_NSGetEnviron();

  NSMutableString *cmdline = [NSMutableString string];
  for (int i = 0; i < p->argc; i++) [cmdline appendFormat:@"%s%s", i ? " " : "", p->argv[i]];
  shimLog("in-process %s started as pid %d (%d new environment variables): %s", name, p->pid, envCount, cmdline.UTF8String);

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);   // a main thread's worth (8 MB) and then some
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&p->thread, &attr, procMain, p);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    pthread_mutex_lock(&gProcLock);
    p->inUse = 0;
    pthread_mutex_unlock(&gProcLock);
    errno = rc;
    return -1;
  }
  return p->pid;
}

static ak_vproc *findProc(pid_t pid) {
  for (int i = 0; i < AK_VPROC_MAX; i++) if (gProcs[i].inUse && gProcs[i].pid == pid) return &gProcs[i];
  return NULL;
}

#pragma mark Process calls

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  if (AKIsInProcessExecutable(path)) {
    pid_t p = AKSpawnInProcess(path, argv, envp, NULL);
    if (p < 0) return errno;
    if (pid) *pid = p;
    return 0;
  }
  int rc = REAL(int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                        char *const[], char *const[]), posix_spawn)(pid, path, fa, attr, argv, envp);
  if (rc != 0) shimLog("posix_spawn %s: %s", path, strerror(rc));
  return rc;
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
  if (strchr(file, '/')) return posix_spawn(pid, file, fa, attr, argv, envp);
  int rc = REAL(int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                        char *const[], char *const[]), posix_spawnp)(pid, file, fa, attr, argv, envp);
  if (rc != 0) shimLog("posix_spawnp %s: %s", file, strerror(rc));
  return rc;
}

int kill(pid_t pid, int sig) {
  pid_t target = pid < 0 ? -pid : pid;          // a process group is the process itself here
  if (target < AK_VPID_BASE) return REAL(int (*)(pid_t, int), kill)(pid, sig);
  pthread_mutex_lock(&gProcLock);
  ak_vproc *p = findProc(target);
  pthread_mutex_unlock(&gProcLock);
  if (!p) { errno = ESRCH; return -1; }
  // Signal 0 asks "does it exist": yes, until it is reaped. A thread can't be stopped from
  // outside the way a process can, so other signals are noted and otherwise ignored.
  if (sig != 0) shimLog("signal %d to in-process pid %d ignored (it can't be stopped from outside)", sig, target);
  return 0;
}

// Wait for a stand-in to finish (or not, with WNOHANG). Returns 1 when it has finished, 0 when
// it is still running, -1 for no such process. Reaps it unless keep is set.
static int waitProc(pid_t pid, int nohang, int keep, int *statusOut) {
  pthread_mutex_lock(&gProcLock);
  ak_vproc *p = findProc(pid);
  if (!p) { pthread_mutex_unlock(&gProcLock); return -1; }
  while (p->running && !nohang) pthread_cond_wait(&gProcExited, &gProcLock);
  if (p->running) { pthread_mutex_unlock(&gProcLock); return 0; }
  if (statusOut) *statusOut = p->status;
  if (!keep) p->inUse = 0;
  pthread_mutex_unlock(&gProcLock);
  return 1;
}

pid_t waitpid(pid_t pid, int *status, int options) {
  if (pid < AK_VPID_BASE) return REAL(pid_t (*)(pid_t, int *, int), waitpid)(pid, status, options);
  int code = 0;
  int r = waitProc(pid, options & WNOHANG, 0, &code);
  if (r < 0) { errno = ECHILD; return -1; }
  if (r == 0) return 0;
  if (status) *status = (code & 0xff) << 8;      // WIFEXITED, WEXITSTATUS == code
  return pid;
}

int waitid(idtype_t idtype, id_t id, siginfo_t *info, int options) {
  if (idtype != P_PID || id < AK_VPID_BASE)
    return REAL(int (*)(idtype_t, id_t, siginfo_t *, int), waitid)(idtype, id, info, options);
  int code = 0;
  int r = waitProc((pid_t)id, options & WNOHANG, options & WNOWAIT, &code);
  if (r < 0) { errno = ECHILD; return -1; }
  if (info) {
    memset(info, 0, sizeof *info);
    if (r == 1) {
      info->si_signo = SIGCHLD;
      info->si_code = CLD_EXITED;
      info->si_pid = (pid_t)id;
      info->si_status = code;
    }
  }
  return 0;
}

// exit() on a stand-in's main thread ends that "process", not the app.
void exit(int status) {
  ak_vproc *p = tCurrentProc;
  if (p) { finishProc(p, status); pthread_exit(NULL); }
  REAL(void (*)(int), exit)(status);
  abort();
}

void _exit(int status) {
  ak_vproc *p = tCurrentProc;
  if (p) { finishProc(p, status); pthread_exit(NULL); }
  REAL(void (*)(int), _exit)(status);
  abort();
}

#pragma mark Rebinding a library's imports

// Point every import of `symbol` in the images whose path starts with pathPrefix at
// `replacement` — the indirect-symbol walk fishhook does: each lazy and non-lazy symbol
// pointer section names, through the indirect symbol table, the symbol each slot binds to.
// Returns how many slots were changed.
int AKRebindSymbol(const char *pathPrefix, const char *symbol, void *replacement) {
  char mangled[512];
  snprintf(mangled, sizeof mangled, "_%s", symbol);
  int changed = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name || strncmp(name, pathPrefix, strlen(pathPrefix)) != 0) continue;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    if (!mh || mh->magic != MH_MAGIC_64) continue;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const uint8_t *lc = (const uint8_t *)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++, lc += ((const struct load_command *)lc)->cmdsize) {
      const struct load_command *l = (const struct load_command *)lc;
      if (l->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)l)->segname, SEG_LINKEDIT) == 0)
        linkedit = (const struct segment_command_64 *)l;
      else if (l->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)l;
      else if (l->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)l;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) continue;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    lc = (const uint8_t *)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++, lc += ((const struct load_command *)lc)->cmdsize) {
      const struct load_command *l = (const struct load_command *)lc;
      if (l->cmd != LC_SEGMENT_64) continue;
      const struct segment_command_64 *seg = (const struct segment_command_64 *)l;
      const struct section_64 *sect = (const struct section_64 *)(seg + 1);
      for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
        uint32_t type = sect->flags & SECTION_TYPE;
        if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
        void **slots = (void **)((uintptr_t)slide + sect->addr);
        uint32_t count = (uint32_t)(sect->size / sizeof(void *));
        for (uint32_t k = 0; k < count; k++) {
          uint32_t idx = indirect[sect->reserved1 + k];
          if (idx == INDIRECT_SYMBOL_ABS || idx == INDIRECT_SYMBOL_LOCAL ||
              idx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) || idx >= symtab->nsyms) continue;
          if (strcmp(strs + syms[idx].n_un.n_strx, mangled) != 0) continue;
          // __DATA_CONST is read-only once dyld is done with it: open the page up briefly.
          uintptr_t page = (uintptr_t)&slots[k] & ~(uintptr_t)(PAGE_SIZE - 1);
          int ro = seg->initprot == VM_PROT_READ || strcmp(seg->segname, "__DATA_CONST") == 0 ||
                   strcmp(seg->segname, "__AUTH_CONST") == 0;
          if (ro && mprotect((void *)page, PAGE_SIZE, PROT_READ | PROT_WRITE) != 0 &&
              vm_protect(mach_task_self(), page, PAGE_SIZE, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
            shimLog("rebind %s in %s: can't make the slot writable", symbol, baseName(name));
            continue;
          }
          slots[k] = replacement;
          if (ro) mprotect((void *)page, PAGE_SIZE, PROT_READ);
          changed++;
        }
      }
    }
  }
  return changed;
}
