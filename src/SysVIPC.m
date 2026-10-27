// System V semaphores, in process.
//
// The macOS Steam client builds its named mutexes and semaphores on System V IPC
// (semget/semop/semctl in libtier0_s's SteamThreadTools). Those exist to coordinate
// Steam's several processes. On iOS the client runs as one process and these particular
// system calls aren't permitted — the kernel ends the process with SIGSYS the first time
// libtier0_s creates a mutex — so the shim provides the same API backed by ordinary
// in-process state. With a single process there is no cross-process coordination to do,
// so one lock and one condition variable reproduce the behaviour a client that shares
// these objects only with itself depends on. libSystem is routed through the shim umbrella
// (which lists this code before the real libSystem), so the client binds to these.
//
// Semantics recovered from libtier0_s's arm64 code: a set holds one semaphore; Acquire is
// semop sem_op=-1, Release is sem_op=+1; sem_flg carries IPC_NOWAIT (0x800) and SEM_UNDO
// (0x1000, irrelevant in one process); CreateSemaphoreInternal does semget(key,1,0600|IPC_CREAT
// |IPC_EXCL) then semctl SETVAL, and the orphan check reads GETNCNT/GETZCNT/GETPID (all of
// which, for a live single process, say "not orphaned").
#import <errno.h>
#import <pthread.h>
#import <stdarg.h>
#import <string.h>
#import <sys/types.h>
#import <unistd.h>

// <sys/ipc.h>/<sys/sem.h> mark these unavailable on iOS, so don't include them; define the
// constants and the sembuf layout (ABI-identical to the caller's) here instead.
#define AK_IPC_CREAT  001000   // 0x200
#define AK_IPC_EXCL   002000   // 0x400
#define AK_IPC_NOWAIT 004000   // 0x800
#define AK_IPC_PRIVATE 0

enum { AK_IPC_RMID = 0, AK_IPC_SET = 1, AK_IPC_STAT = 2, AK_GETNCNT = 3, AK_GETPID = 4,
       AK_GETVAL = 5, AK_GETALL = 6, AK_GETZCNT = 7, AK_SETVAL = 8, AK_SETALL = 9 };

struct ak_sembuf { unsigned short sem_num; short sem_op; short sem_flg; };

#define AK_MAX_SETS 512
#define AK_MAX_SEMS 8

typedef struct {
  int inUse;
  int key;                 // the System V key, or IPC_PRIVATE for an anonymous set
  int nsems;
  int val[AK_MAX_SEMS];
} ak_semset;

static ak_semset gSets[AK_MAX_SETS];
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  gCond = PTHREAD_COND_INITIALIZER;

int semget(key_t key, int nsems, int semflg);
int semop(int semid, struct ak_sembuf *sops, size_t nsops);
int semctl(int semid, int semnum, int cmd, ...);

int semget(key_t key, int nsems, int semflg) {
  if (nsems < 0 || nsems > AK_MAX_SEMS) { errno = EINVAL; return -1; }
  pthread_mutex_lock(&gLock);

  int found = -1;
  if (key != AK_IPC_PRIVATE) {
    for (int i = 0; i < AK_MAX_SETS; i++)
      if (gSets[i].inUse && gSets[i].key == (int)key) { found = i; break; }
  }
  if (found >= 0) {
    int rc = found;
    if ((semflg & AK_IPC_CREAT) && (semflg & AK_IPC_EXCL)) { errno = EEXIST; rc = -1; }
    pthread_mutex_unlock(&gLock);
    return rc;
  }
  if (!(semflg & AK_IPC_CREAT)) { pthread_mutex_unlock(&gLock); errno = ENOENT; return -1; }

  for (int i = 0; i < AK_MAX_SETS; i++) {
    if (!gSets[i].inUse) {
      gSets[i].inUse = 1;
      gSets[i].key = (int)key;
      gSets[i].nsems = nsems > 0 ? nsems : 1;
      memset(gSets[i].val, 0, sizeof gSets[i].val);
      pthread_mutex_unlock(&gLock);
      return i;
    }
  }
  pthread_mutex_unlock(&gLock);
  errno = ENOSPC;
  return -1;
}

static int validSet(int semid) {
  return semid >= 0 && semid < AK_MAX_SETS && gSets[semid].inUse;
}

// Steam only ever passes nsops == 1, so applying the ops in order (blocking on a wait)
// matches what it needs; true multi-op atomicity isn't exercised.
int semop(int semid, struct ak_sembuf *sops, size_t nsops) {
  pthread_mutex_lock(&gLock);
  if (!validSet(semid)) { pthread_mutex_unlock(&gLock); errno = EINVAL; return -1; }

  for (size_t i = 0; i < nsops; i++) {
    struct ak_sembuf *op = &sops[i];
    int n = op->sem_num;
    if (n < 0 || n >= gSets[semid].nsems) { pthread_mutex_unlock(&gLock); errno = EFBIG; return -1; }

    if (op->sem_op < 0) {                     // wait until the count can absorb the decrement
      while (gSets[semid].val[n] + op->sem_op < 0) {
        if (op->sem_flg & AK_IPC_NOWAIT) { pthread_mutex_unlock(&gLock); errno = EAGAIN; return -1; }
        pthread_cond_wait(&gCond, &gLock);
        if (!validSet(semid)) { pthread_mutex_unlock(&gLock); errno = EIDRM; return -1; }
      }
      gSets[semid].val[n] += op->sem_op;
    } else if (op->sem_op > 0) {              // post
      gSets[semid].val[n] += op->sem_op;
      pthread_cond_broadcast(&gCond);
    } else {                                  // wait for zero
      while (gSets[semid].val[n] != 0) {
        if (op->sem_flg & AK_IPC_NOWAIT) { pthread_mutex_unlock(&gLock); errno = EAGAIN; return -1; }
        pthread_cond_wait(&gCond, &gLock);
        if (!validSet(semid)) { pthread_mutex_unlock(&gLock); errno = EIDRM; return -1; }
      }
    }
  }
  pthread_mutex_unlock(&gLock);
  return 0;
}

int semctl(int semid, int semnum, int cmd, ...) {
  pthread_mutex_lock(&gLock);
  if (cmd != AK_IPC_RMID && !validSet(semid)) { pthread_mutex_unlock(&gLock); errno = EINVAL; return -1; }
  int ret = 0;

  switch (cmd) {
    case AK_GETVAL:
      if (semnum >= 0 && semnum < gSets[semid].nsems) ret = gSets[semid].val[semnum];
      else { errno = EINVAL; ret = -1; }
      break;
    case AK_SETVAL: {
      va_list ap; va_start(ap, cmd); int v = va_arg(ap, int); va_end(ap);
      if (semnum >= 0 && semnum < gSets[semid].nsems) { gSets[semid].val[semnum] = v; pthread_cond_broadcast(&gCond); }
      else { errno = EINVAL; ret = -1; }
      break;
    }
    case AK_GETPID:  ret = getpid(); break;   // this live process holds it: never orphaned
    case AK_GETNCNT: ret = 0; break;          // no other process is waiting on it
    case AK_GETZCNT: ret = 0; break;
    case AK_IPC_STAT: ret = 0; break;         // no cross-process status to report
    case AK_IPC_SET:  ret = 0; break;
    case AK_IPC_RMID:
      if (validSet(semid)) { gSets[semid].inUse = 0; pthread_cond_broadcast(&gCond); }
      ret = 0;
      break;
    default: ret = 0; break;
  }
  pthread_mutex_unlock(&gLock);
  return ret;
}
