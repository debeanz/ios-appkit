// Steam's shared-memory command streams, as the client and its web helper use them.
// Reimplemented from Steam Helper's arm64 code (CSharedMemStream, IPC::PosixMutex,
// IPC::PosixEvent, IPC::BinarySemaphore), so this side of a stream behaves the way Steam's
// own side expects. See SteamIPC.m for the layout and semantics.
#import <stdbool.h>
#import <stdint.h>

typedef struct AKSteamEvent AKSteamEvent;
typedef struct AKSteamStream AKSteamStream;

// How a stream attaches to its shared objects (CSharedMemStream's last constructor argument).
enum {
  AKSteamStreamOpenOrCreate = 0,
  AKSteamStreamForceCreate = 1,   // remove any leftover objects of that name first
  AKSteamStreamOpenExisting = 2,  // fail if the stream doesn't exist yet
};

// Steam names its semaphores and shared memory after the CRC32 of the object's name.
uint32_t AKSteamCRC32(const char *s);

// An auto- or manual-reset event shared by name. timeoutMs < 0 waits forever.
AKSteamEvent *AKSteamEventCreate(const char *name, bool manualReset, bool initialState, bool force);
bool AKSteamEventWait(AKSteamEvent *e, int timeoutMs);
void AKSteamEventSet(AKSteamEvent *e);
void AKSteamEventFree(AKSteamEvent *e);

// A byte stream through a ring buffer in shared memory, guarded by a named mutex, with
// "written" and "avail" events. Put blocks (up to the stream's timeout per chunk) while the
// ring is full; Get blocks while it holds fewer bytes than asked for. Both return the number
// of bytes moved.
AKSteamStream *AKSteamStreamOpen(const char *name, uint32_t size, int timeoutMs, int mode);
bool AKSteamStreamCreated(AKSteamStream *s);
uint32_t AKSteamStreamAvailable(AKSteamStream *s);
uint32_t AKSteamStreamPut(AKSteamStream *s, const void *data, uint32_t len);
uint32_t AKSteamStreamGet(AKSteamStream *s, void *buf, uint32_t len);
void AKSteamStreamClose(AKSteamStream *s);
