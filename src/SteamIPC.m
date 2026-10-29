// Steam's shared-memory streams (SteamIPC.h), reimplemented from Steam Helper's arm64 code
// (src/overlay/common/shmemstream.cpp and the IPC:: primitives under it) so that this end of
// a stream interoperates with the client's own copy of that code in chromehtml.dylib.
//
// Names. Every object is named after the CRC32 of a string. A stream "S" is the mutex
// "S_mutex", the events "S_written" and "S_avail", and the shared memory "S_mem":
//   mutex "X"            semaphores /MTX/<crc X> (1 = free) and /MTX/<crc X>.2 (recursion depth)
//   event "X"            semaphore /Evt/<crc X> (one token per waiter) and the binary
//                        semaphore "X.BinSemLock"
//   binary semaphore "Y" semaphores /BSem/<crc Y> (1 = signaled) and /BSem/<crc Y>.2 (1 = taken)
//   shared memory "X"    shm /Shm/<crc X> of (size & ~0x3fff) + 0x4000 bytes
// The shared memory starts with four u32s - read offset, write offset, ring size, bytes in
// use - and the ring follows. A writer waits on "avail" while the ring is too full, takes the
// mutex, copies (wrapping at the end), bumps the write offset and the count, and sets
// "written"; a reader does the mirror image. A new stream's creator holds the mutex while it
// sets the header up; anyone attaching takes it, so they wait for that.
//
// iOS has no sem_timedwait; like Steam, a wait with a timeout polls every 10 ms, and a wait
// without one blocks in sem_wait. The shared memory comes from the shim's in-process
// shm_open (PosixShm.m): the client and this helper are one process here.
#import "SteamIPC.h"
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <pthread.h>
#import <semaphore.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <time.h>
#import <unistd.h>

int shm_open(const char *name, int oflag, ...);   // the shim's (PosixShm.m)
int shm_unlink(const char *name);
kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);   // the shim's (MachBootstrap.m)

static void ipcLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void ipcLog(const char *fmt, ...) {
  char line[1024];
  va_list ap; va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  fprintf(stderr, "[WebHelper] %s\n", line);
}

uint32_t AKSteamCRC32(const char *s) {
  uint32_t c = 0xffffffffu;
  for (; *s; s++) {
    c ^= (uint8_t)*s;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
  }
  return ~c;
}

#pragma mark Semaphores

static uint64_t nowMs(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

// sem_trywait, retried when interrupted. True if a token was taken.
static bool semTry(sem_t *s) {
  for (;;) {
    if (sem_trywait(s) == 0) return true;
    if (errno != EINTR) return false;
  }
}

// Take a token within timeoutMs (< 0: however long it takes; 0: only if one is there now).
static bool semTake(sem_t *s, int timeoutMs) {
  if (timeoutMs < 0) {
    while (sem_wait(s) != 0)
      if (errno != EINTR) return false;
    return true;
  }
  if (semTry(s)) return true;
  if (timeoutMs == 0) return false;
  uint64_t start = nowMs();
  while (nowMs() - start < (uint64_t)timeoutMs) {
    usleep(10000);
    if (semTry(s)) return true;
  }
  return false;
}

// Steam's objects are pairs of semaphores. Create both (a with value va, b with vb), or, if a
// already exists, attach to both - b can lag a moment behind a, as its creator makes it next.
static bool semPairOpen(const char *a, const char *b, unsigned va, unsigned vb, bool force,
                        sem_t **sa, sem_t **sb, bool *created) {
  if (force) { sem_unlink(a); sem_unlink(b); }
  *created = false;
  *sb = SEM_FAILED;
  *sa = sem_open(a, O_CREAT | O_EXCL, 0777, va);
  if (*sa != SEM_FAILED) {
    *sb = sem_open(b, O_CREAT | O_EXCL, 0777, vb);
    *created = *sb != SEM_FAILED;
    return *created;
  }
  if (errno != EEXIST) return false;
  *sa = sem_open(a, 0);
  if (*sa == SEM_FAILED) return false;
  for (int i = 0; i < 200; i++) {
    *sb = sem_open(b, 0);
    if (*sb != SEM_FAILED) return true;
    usleep(10000);
  }
  return false;
}

static void semPairClose(sem_t *a, sem_t *b) {
  if (a && a != SEM_FAILED) sem_close(a);
  if (b && b != SEM_FAILED) sem_close(b);
}

#pragma mark IPC::PosixMutex

// The lock is the floor semaphore; the ceiling counts re-entries by the owning thread. Who
// owns it is known only to the object that took it, as in Steam.
typedef struct {
  sem_t *floor, *ceiling;
  bool owned;
  pthread_t owner;
} AKSteamMutex;

static void mutexFree(AKSteamMutex *m) {
  if (!m) return;
  semPairClose(m->floor, m->ceiling);
  free(m);
}

// A mutex its creator holds from the start (every stream's is made that way).
static AKSteamMutex *mutexCreate(const char *name, bool *created, bool force) {
  char a[32], b[40];
  snprintf(a, sizeof a, "/MTX/%x", AKSteamCRC32(name));
  snprintf(b, sizeof b, "%s.2", a);
  AKSteamMutex *m = calloc(1, sizeof *m);
  if (!semPairOpen(a, b, 0, 0, force, &m->floor, &m->ceiling, created)) {
    ipcLog("can't create mutex %s (%s): %s", name, a, strerror(errno));
    mutexFree(m);
    return NULL;
  }
  if (*created) { m->owned = true; m->owner = pthread_self(); }
  return m;
}

static bool mutexLock(AKSteamMutex *m, int timeoutMs) {
  if (m->owned && pthread_equal(m->owner, pthread_self())) {
    sem_post(m->ceiling);
    return true;
  }
  if (!semTake(m->floor, timeoutMs)) return false;
  m->owned = true;
  m->owner = pthread_self();
  return true;
}

static void mutexUnlock(AKSteamMutex *m) {
  if (!m->owned || !pthread_equal(m->owner, pthread_self())) {
    ipcLog("mutex released by a thread that doesn't hold it");
    return;
  }
  if (semTry(m->ceiling)) return;   // one re-entry undone; still held
  m->owned = false;
  sem_post(m->floor);
}

#pragma mark ipcserver

// Steam's ipcserver (the Mach service com.valvesoftware.steam.ipctool; an in-process program
// here) notes who holds each binary semaphore, to free it if that process dies, and Steam's
// side tells it of every take (op 10) and every release (op 11). An event's binary semaphore
// is taken by its waiter and released by whoever sets it, so with this end setting events
// Steam waits on and saying nothing, ipcserver saw Steam take a lock it still held - "Error:
// ClaimLock by [pid] on already claimed lock" about once a second. This end reports its
// releases as Steam's own helper does. The message is Steam's: {header, op, pid, the
// semaphore's /BSem name, a label}, msgh_id 0x68, sent with a 2 s timeout and no reply.
typedef struct {
  mach_msg_header_t header;
  int32_t op, pid;
  char name[32], label[256];
} AKIPCServerMessage;

static mach_port_t ipcServerPort(void) {
  static mach_port_t server;
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&lock);
  if (!server && bootstrap_look_up(bootstrap_port, "com.valvesoftware.steam.ipctool", &server) != KERN_SUCCESS)
    server = MACH_PORT_NULL;   // not running yet: asked again next time
  mach_port_t port = server;
  pthread_mutex_unlock(&lock);
  return port;
}

static void tellIPCServer(int32_t op, const char *name) {
  mach_port_t port = ipcServerPort();
  if (!port) return;
  AKIPCServerMessage m = { 0 };
  m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
  m.header.msgh_size = sizeof m;
  m.header.msgh_remote_port = port;
  m.header.msgh_id = 0x68;
  m.op = op;
  m.pid = getpid();
  strncpy(m.name, name, sizeof m.name - 1);
  mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
}

// Which Steam is running, for ipcserver to tell games: on a Mac steam_osx sends it (op 13) once
// ipcserver runs, with its pid and its executable's path, whose folder holds steamclient.dylib.
// A game's SteamAPI_Init asks for it (op 14) and gives up without it ("[S_API FAIL]
// SteamAPI_Init() failed; ipcserver GetSteamPath failed"). The host stands in for steam_osx, so
// it says it here. steam_osx's message: {header, op, pid, char path[512]}, msgh_id 0x68, no
// reply. ipcserver checks in its service on its own thread, so this waits up to 5 s for it.
typedef struct {
  mach_msg_header_t header;
  int32_t op, pid;
  char path[512];
} AKIPCServerSteamMessage;

void AKSteamRegisterRunningSteam(const char *executable) {
  char *path = strdup(executable);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    mach_port_t port = MACH_PORT_NULL;
    for (int i = 0; i < 250 && !(port = ipcServerPort()); i++) usleep(20000);
    if (!port) {
      fprintf(stderr, "[AppKitShim] Steamworks: ipcserver never answered; games can't find Steam\n");
      free(path);
      return;
    }
    AKIPCServerSteamMessage m = { 0 };
    m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.header.msgh_size = sizeof m;
    m.header.msgh_remote_port = port;
    m.header.msgh_id = 0x68;
    m.op = 13;
    m.pid = getpid();
    strncpy(m.path, path, sizeof m.path - 1);
    kern_return_t sent = mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    fprintf(stderr, "[AppKitShim] Steamworks: ipcserver told Steam is pid %d at %s%s\n", m.pid, path,
            sent == KERN_SUCCESS ? "" : " (the message didn't go)");
    free(path);
  });
}

#pragma mark IPC::BinarySemaphore and IPC::PosixEvent

typedef struct {
  sem_t *floor, *ceiling;
  char name[32];   // the floor's, /BSem/<crc>: how ipcserver knows it
} AKSteamBinSem;

static bool binsemTake(AKSteamBinSem *s, int timeoutMs) {
  if (!semTake(s->floor, timeoutMs)) return false;
  sem_post(s->ceiling);
  return true;
}

static void binsemRelease(AKSteamBinSem *s) {
  if (!semTry(s->ceiling)) return;   // not taken: already signaled
  sem_post(s->floor);
  tellIPCServer(11, s->name);
}

struct AKSteamEvent {
  AKSteamBinSem lock;   // signaled = free
  sem_t *pending;       // a token per thread waiting, so a wake-up can be passed on
  bool manualReset;
};

void AKSteamEventFree(AKSteamEvent *e) {
  if (!e) return;
  semPairClose(e->lock.floor, e->lock.ceiling);
  if (e->pending && e->pending != SEM_FAILED) sem_close(e->pending);
  free(e);
}

AKSteamEvent *AKSteamEventCreate(const char *name, bool manualReset, bool initialState, bool force) {
  char lockName[320], a[32], b[40], pendingName[32];
  snprintf(lockName, sizeof lockName, "%s.BinSemLock", name);
  snprintf(a, sizeof a, "/BSem/%x", AKSteamCRC32(lockName));
  snprintf(b, sizeof b, "%s.2", a);
  snprintf(pendingName, sizeof pendingName, "/Evt/%x", AKSteamCRC32(name));
  AKSteamEvent *e = calloc(1, sizeof *e);
  e->manualReset = manualReset;
  snprintf(e->lock.name, sizeof e->lock.name, "%s", a);
  e->pending = SEM_FAILED;
  if (force) sem_unlink(pendingName);
  bool created;
  // The binary semaphore starts taken unless the event starts signaled.
  if (!semPairOpen(a, b, initialState ? 1 : 0, initialState ? 0 : 1, force, &e->lock.floor, &e->lock.ceiling, &created)) {
    ipcLog("can't create event %s (%s): %s", name, a, strerror(errno));
    AKSteamEventFree(e);
    return NULL;
  }
  if (created) {
    e->pending = sem_open(pendingName, O_CREAT | O_EXCL, 0777, 0);
    if (e->pending == SEM_FAILED && errno == EEXIST) e->pending = sem_open(pendingName, 0);
  } else {
    for (int i = 0; i < 200 && e->pending == SEM_FAILED; i++) {
      e->pending = sem_open(pendingName, 0);
      if (e->pending == SEM_FAILED) usleep(10000);
    }
  }
  if (e->pending == SEM_FAILED) {
    ipcLog("can't create event %s (%s): %s", name, pendingName, strerror(errno));
    AKSteamEventFree(e);
    return NULL;
  }
  return e;
}

bool AKSteamEventWait(AKSteamEvent *e, int timeoutMs) {
  sem_post(e->pending);
  bool got = binsemTake(&e->lock, timeoutMs);
  semTry(e->pending);   // withdraw this waiter's token
  if (got) {
    if (semTry(e->pending)) {
      // Others are waiting too: leave the event signaled so they wake as well.
      sem_post(e->pending);
      binsemRelease(&e->lock);
    } else if (e->manualReset) {
      binsemRelease(&e->lock);
    }
  }
  return got;
}

void AKSteamEventSet(AKSteamEvent *e) { binsemRelease(&e->lock); }

#pragma mark A game's overlay event

// When kill(pid, 0) says a game Steam started is gone, Steam asks whether its overlay still
// runs before it lets the game go (steamclient's game list, every 250 ms): it opens the event
// "SteamOverlayRunning_<game id>", making it if it isn't there, and a game it didn't have to
// make it for is still running. It never removes what it made (its events and binary
// semaphores only sem_close), so from its second look on it finds its own and the game never
// ends ("Stopping" for good). On a Mac the game's overlay renderer holds that name; no overlay
// renderer runs here, so semaphores made under it lose their names at once, and every look
// finds none. Named semaphores outlive the app (until the phone restarts), so ones an earlier
// run left under the game's names are removed when it starts, and any found there later is
// replaced. libSystem is routed through the shim umbrella, so the client's sem_open is this.
static uint32_t gOverlayLock, gOverlayEvent;   // CRC32s: the event's binary semaphore, and the event
static unsigned gOverlayLooks;                 // Steam's looks logged for this game

void AKSteamNoteGameID(uint64_t gameID) {
  char name[64], lock[80], path[48];
  snprintf(name, sizeof name, "SteamOverlayRunning_%llu", (unsigned long long)gameID);
  snprintf(lock, sizeof lock, "%s.BinSemLock", name);
  gOverlayLock = AKSteamCRC32(lock);
  gOverlayEvent = AKSteamCRC32(name);
  gOverlayLooks = 0;
  int removed = 0;
  snprintf(path, sizeof path, "/BSem/%x", gOverlayLock);
  removed += sem_unlink(path) == 0;
  snprintf(path, sizeof path, "/BSem/%x.2", gOverlayLock);
  removed += sem_unlink(path) == 0;
  snprintf(path, sizeof path, "/Evt/%x", gOverlayEvent);
  removed += sem_unlink(path) == 0;
  fprintf(stderr, "[AppKitShim] game: Steam's overlay check for it: %s (%d left from an earlier run removed)\n", name, removed);
}

// /BSem/<crc>, /BSem/<crc>.2 (the binary semaphore's pair) or /Evt/<crc> (the event's own).
static bool isOverlayName(const char *name) {
  if (!gOverlayEvent || !name) return false;
  char probe[48];
  snprintf(probe, sizeof probe, "/BSem/%x", gOverlayLock);
  size_t n = strlen(probe);
  if (strncmp(name, probe, n) == 0 && (!name[n] || strcmp(name + n, ".2") == 0)) return true;
  snprintf(probe, sizeof probe, "/Evt/%x", gOverlayEvent);
  return strcmp(name, probe) == 0;
}

sem_t *sem_open(const char *name, int oflag, ...) {
  static sem_t *(*real)(const char *, int, ...);
  if (!real) real = (sem_t *(*)(const char *, int, ...))dlsym(dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD), "sem_open");
  if (!(oflag & O_CREAT)) return real(name, oflag);
  va_list ap;
  va_start(ap, oflag);
  int mode = va_arg(ap, int);
  unsigned value = va_arg(ap, unsigned);
  va_end(ap);
  sem_t *s = real(name, oflag, mode, value);
  if (!isOverlayName(name)) return s;
  bool leftover = s == SEM_FAILED && errno == EEXIST;
  if (leftover) {
    sem_unlink(name);
    s = real(name, oflag, mode, value);
  }
  if (s != SEM_FAILED) sem_unlink(name);
  if (++gOverlayLooks <= 6)
    fprintf(stderr, "[AppKitShim] game: Steam looks for its overlay (%s): none%s\n", name, leftover ? " (an old one replaced)" : "");
  return s;
}

#pragma mark CSharedMemStream

struct AKSteamStream {
  char name[256];
  AKSteamMutex *mutex;
  AKSteamEvent *written, *avail;
  uint8_t *map;
  size_t mapLen;
  volatile uint32_t *hdr;   // [0] read offset, [1] write offset, [2] ring size, [3] bytes in use
  uint8_t *ring;
  uint32_t size, chunk;
  int timeoutMs;
  bool created;
  pthread_mutex_t local;    // this process's own users of the stream take turns
};

static void *shmMap(const char *name, uint32_t bytes, bool force, bool *created, size_t *mapLen) {
  char shmName[32];
  snprintf(shmName, sizeof shmName, "/Shm/%x", AKSteamCRC32(name));
  if (force) shm_unlink(shmName);
  size_t len = (bytes & ~0x3fffu) + 0x4000;
  *created = false;
  int fd = shm_open(shmName, O_CREAT | O_EXCL | O_RDWR, 0777);
  if (fd >= 0) {
    if (ftruncate(fd, (off_t)len) != 0) { close(fd); return NULL; }
    *created = true;   // a new file reads as zeros: no need to clear it
  } else if (errno == EEXIST) {
    fd = shm_open(shmName, O_RDWR);
  }
  if (fd < 0) return NULL;
  void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (p == MAP_FAILED) return NULL;
  *mapLen = len;
  return p;
}

void AKSteamStreamClose(AKSteamStream *s) {
  if (!s) return;
  if (s->map) munmap(s->map, s->mapLen);
  AKSteamEventFree(s->written);
  AKSteamEventFree(s->avail);
  mutexFree(s->mutex);
  pthread_mutex_destroy(&s->local);
  free(s);
}

AKSteamStream *AKSteamStreamOpen(const char *name, uint32_t size, int timeoutMs, int mode) {
  if (size < 0x201) size = 0x200;
  bool force = mode == AKSteamStreamForceCreate;
  AKSteamStream *s = calloc(1, sizeof *s);
  strlcpy(s->name, name, sizeof s->name);
  s->size = size;
  s->chunk = size / 25;
  s->timeoutMs = timeoutMs;
  pthread_mutex_init(&s->local, NULL);

  char n[320];
  bool mutexCreated = false, shmCreated = false;
  snprintf(n, sizeof n, "%s_mutex", name);
  if (!(s->mutex = mutexCreate(n, &mutexCreated, force))) goto fail;
  if (!mutexCreated && !mutexLock(s->mutex, -1)) goto fail;
  snprintf(n, sizeof n, "%s_written", name);
  s->written = AKSteamEventCreate(n, false, false, force);
  snprintf(n, sizeof n, "%s_avail", name);
  s->avail = AKSteamEventCreate(n, false, false, force);
  snprintf(n, sizeof n, "%s_mem", name);
  if (s->written && s->avail) s->map = shmMap(n, size + 0x10, force, &shmCreated, &s->mapLen);
  if (!s->map) {
    ipcLog("stream %s: can't set up its %s", name, !s->written || !s->avail ? "events" : "shared memory");
    mutexUnlock(s->mutex);
    goto fail;
  }
  s->hdr = (volatile uint32_t *)s->map;
  s->ring = s->map + 16;
  if (shmCreated) {
    s->hdr[0] = s->hdr[1] = s->hdr[3] = 0;
    s->hdr[2] = size;
    if (mode == AKSteamStreamOpenExisting) {
      ipcLog("stream %s doesn't exist", name);
      mutexUnlock(s->mutex);
      goto fail;
    }
  } else if (s->hdr[2] != size) {
    ipcLog("stream %s: its ring is %u bytes, not %u", name, s->hdr[2], size);
    if (s->hdr[2] + 16 > s->mapLen) { mutexUnlock(s->mutex); goto fail; }
    s->size = s->hdr[2];
  }
  s->created = shmCreated;
  mutexUnlock(s->mutex);
  return s;

fail:
  AKSteamStreamClose(s);
  return NULL;
}

bool AKSteamStreamCreated(AKSteamStream *s) { return s->created; }

uint32_t AKSteamStreamAvailable(AKSteamStream *s) { return s->hdr[3]; }

static uint32_t putInternal(AKSteamStream *s, const uint8_t *p, uint32_t n) {
  for (;;) {
    while (s->size - s->hdr[3] < n) {
      if (!AKSteamEventWait(s->avail, s->timeoutMs)) {
        ipcLog("stream %s: no room for %u bytes after %d ms (%u of %u in use)", s->name, n, s->timeoutMs, s->hdr[3], s->size);
        return 0;
      }
    }
    if (!mutexLock(s->mutex, -1)) return 0;
    uint32_t w = s->hdr[1], used = s->hdr[3];
    if (w > s->size) {
      mutexUnlock(s->mutex);
      ipcLog("stream %s: header is corrupt (write offset %u)", s->name, w);
      return 0;
    }
    if (n <= s->size - used) {
      if (w + n > s->size) {
        uint32_t first = s->size - w;
        memcpy(s->ring + w, p, first);
        memcpy(s->ring, p + first, n - first);
        s->hdr[1] = n - first;
      } else {
        memcpy(s->ring + w, p, n);
        s->hdr[1] = w + n;
      }
      s->hdr[3] = used + n;
      AKSteamEventSet(s->written);
      mutexUnlock(s->mutex);
      return n;
    }
    mutexUnlock(s->mutex);
  }
}

static uint32_t getInternal(AKSteamStream *s, uint8_t *p, uint32_t n) {
  for (;;) {
    while (s->hdr[3] < n)
      if (!AKSteamEventWait(s->written, s->timeoutMs)) return 0;
    if (!mutexLock(s->mutex, -1)) return 0;
    uint32_t r = s->hdr[0], used = s->hdr[3];
    if (r > s->size) {
      mutexUnlock(s->mutex);
      ipcLog("stream %s: header is corrupt (read offset %u)", s->name, r);
      return 0;
    }
    if (n <= used) {
      if (r + n > s->size) {
        uint32_t first = s->size - r;
        memcpy(p, s->ring + r, first);
        memcpy(p + first, s->ring, n - first);
        s->hdr[0] = n - first;
      } else {
        memcpy(p, s->ring + r, n);
        s->hdr[0] = r + n;
      }
      s->hdr[3] = used - n;
      AKSteamEventSet(s->avail);
      mutexUnlock(s->mutex);
      return n;
    }
    mutexUnlock(s->mutex);
  }
}

// Both move at most a chunk (a 25th of the ring) per turn of the mutex, as Steam's do, so a
// large message never needs the whole ring free at once.
uint32_t AKSteamStreamPut(AKSteamStream *s, const void *data, uint32_t len) {
  pthread_mutex_lock(&s->local);
  uint32_t done = 0;
  while (done < len) {
    uint32_t n = len - done < s->chunk ? len - done : s->chunk;
    if (putInternal(s, (const uint8_t *)data + done, n) != n) break;
    done += n;
  }
  pthread_mutex_unlock(&s->local);
  return done;
}

uint32_t AKSteamStreamGet(AKSteamStream *s, void *buf, uint32_t len) {
  pthread_mutex_lock(&s->local);
  uint32_t done = 0;
  while (done < len) {
    uint32_t n = len - done < s->chunk ? len - done : s->chunk;
    if (getInternal(s, (uint8_t *)buf + done, n) != n) break;
    done += n;
  }
  pthread_mutex_unlock(&s->local);
  return done;
}
