// POSIX shared memory, in process.
//
// The macOS Steam client's CSharedMemStream / shmemdrop (Steam Input's SteamController_*_mem,
// the web helper's GPUProcPIDStream, ...) back their buffers with shm_open + ftruncate + mmap.
// iOS's app sandbox refuses shm_open, so every one of those buffers failed to be created
// ("Failed creating file mapping ..."). As with the System V semaphores (SysVIPC.m), the
// client runs as one process here, so the objects only need to be shared with itself: the
// shim keeps a table of names, each backed by an unlinked temporary file, and hands out a
// fresh descriptor to it on every open. mmap(MAP_SHARED) of those descriptors gives every
// opener the same pages, which is what the client relies on. libSystem is routed through the
// shim umbrella (which lists this code before the real libSystem), so the client binds here.
//
// Usage recovered from steamui's arm64 code (the same code is in steamclient and chromehtml):
// shm_open(name, O_CREAT|O_EXCL|O_RDWR, 0777); on EEXIST, shm_open(name, O_RDWR) to attach;
// the creator ftruncates to the page-rounded size; a "force create" first calls shm_unlink.
// Names are "/Shm/<hash>", well under PSHMNAMLEN.
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#define AK_SHM_NAMELEN 64
#define AK_SHM_MAX 256

typedef struct {
  int inUse;
  int fd;                        // the table's own descriptor; openers get a dup of it
  char name[AK_SHM_NAMELEN];
} ak_shm;

static ak_shm gShm[AK_SHM_MAX];
static pthread_mutex_t gShmLock = PTHREAD_MUTEX_INITIALIZER;

int shm_open(const char *name, int oflag, ...);
int shm_unlink(const char *name);

static int findShm(const char *name) {
  for (int i = 0; i < AK_SHM_MAX; i++)
    if (gShm[i].inUse && strcmp(gShm[i].name, name) == 0) return i;
  return -1;
}

// An anonymous file in the app's temporary directory: created, then unlinked at once, so it
// lives exactly as long as the table entry and the mappings made from it.
static int makeBackingFile(void) {
  const char *dir = getenv("TMPDIR");
  if (!dir || !*dir) dir = "/tmp";
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s%sakshm.XXXXXX", dir, dir[strlen(dir) - 1] == '/' ? "" : "/");
  int fd = mkstemp(path);
  if (fd < 0) return -1;
  unlink(path);
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
}

int shm_open(const char *name, int oflag, ...) {
  if (!name || !*name) { errno = EINVAL; return -1; }
  if (strlen(name) >= AK_SHM_NAMELEN) { errno = ENAMETOOLONG; return -1; }

  pthread_mutex_lock(&gShmLock);
  int i = findShm(name);
  if (i >= 0) {
    if ((oflag & O_CREAT) && (oflag & O_EXCL)) { pthread_mutex_unlock(&gShmLock); errno = EEXIST; return -1; }
  } else {
    if (!(oflag & O_CREAT)) { pthread_mutex_unlock(&gShmLock); errno = ENOENT; return -1; }
    for (int j = 0; j < AK_SHM_MAX; j++) if (!gShm[j].inUse) { i = j; break; }
    if (i < 0) { pthread_mutex_unlock(&gShmLock); errno = ENFILE; return -1; }
    int fd = makeBackingFile();
    if (fd < 0) { int e = errno; pthread_mutex_unlock(&gShmLock); errno = e; return -1; }
    gShm[i].inUse = 1;
    gShm[i].fd = fd;
    strlcpy(gShm[i].name, name, sizeof gShm[i].name);
  }

  // The backing file is always read-write, so a read-only opener can still map it PROT_READ.
  if ((oflag & O_TRUNC) && (oflag & O_ACCMODE) != O_RDONLY) ftruncate(gShm[i].fd, 0);
  int fd = dup(gShm[i].fd);
  int e = errno;
  pthread_mutex_unlock(&gShmLock);
  if (fd < 0) { errno = e; return -1; }
  if (oflag & O_CLOEXEC) fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
}

int shm_unlink(const char *name) {
  if (!name) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&gShmLock);
  int i = findShm(name);
  if (i < 0) { pthread_mutex_unlock(&gShmLock); errno = ENOENT; return -1; }
  close(gShm[i].fd);             // existing descriptors and mappings keep the pages alive
  gShm[i].inUse = 0;
  pthread_mutex_unlock(&gShmLock);
  return 0;
}
