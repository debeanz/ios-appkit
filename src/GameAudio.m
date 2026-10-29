// Sound for the Mac games Steam starts. A Mac game plays through the default output audio unit
// (or the system or HAL output unit); iOS has none of them, only RemoteIO, which plays to the
// speaker or headphones the same way for a game that only plays sound (GameMaker logged
// "AudioComponentFindNext unable to find a default audio output device" and stayed silent). So
// a game's own lookups of those units find RemoteIO, and the app's audio session becomes a
// playback one: it sounds with the ring switch on silent too, as a Mac has no such switch.
#import "AKShimPrivate.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>

// The Mac's output unit subtypes (not in the iOS SDK): 'def ', 'sys ', 'ahal'.
enum { kMacDefaultOutput = 0x64656620, kMacSystemOutput = 0x73797320, kMacHALOutput = 0x6168616c };

// Once per launch: a game's end turns the session off (AKGameAudioStop).
static BOOL gSessionStarted;

static void startPlaybackSession(void) {
  @synchronized (AVAudioSession.class) {
    if (gSessionStarted) return;
    gSessionStarted = YES;
    NSError *error;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error])
      fprintf(stderr, "[AppKitShim] game audio: the audio session didn't start: %s\n", error.localizedDescription.UTF8String);
  }
}

void AKGameAudioBegin(void) { startPlaybackSession(); }

static AudioComponent gameFindNext(AudioComponent after, const AudioComponentDescription *desc) {
  if (!desc || desc->componentType != kAudioUnitType_Output ||
      (desc->componentSubType != kMacDefaultOutput && desc->componentSubType != kMacSystemOutput &&
       desc->componentSubType != kMacHALOutput))
    return AudioComponentFindNext(after, desc);
  AudioComponentDescription io = *desc;
  io.componentSubType = kAudioUnitSubType_RemoteIO;
  io.componentManufacturer = kAudioUnitManufacturer_Apple;
  io.componentFlags = io.componentFlagsMask = 0;
  startPlaybackSession();
  AudioComponent found = AudioComponentFindNext(after, &io);
  static dispatch_once_t logged;
  dispatch_once(&logged, ^{
    fprintf(stderr, "[AppKitShim] game audio: its Mac output unit is iOS's RemoteIO%s\n", found ? "" : " (not found!)");
  });
  return found;
}

// The output units and audio queues the game made: when it ends they stop and go (they would
// otherwise go on pulling sound from its code). Sound it plays any other way (AVAudioEngine,
// OpenAL) stops with the audio session.
static NSMutableSet<NSValue *> *gUnits, *gQueues;
static pthread_mutex_t gUnitsLock = PTHREAD_MUTEX_INITIALIZER;

static void noteQueue(AudioQueueRef q) {
  pthread_mutex_lock(&gUnitsLock);
  if (!gQueues) gQueues = [NSMutableSet set];
  [gQueues addObject:[NSValue valueWithPointer:q]];
  pthread_mutex_unlock(&gUnitsLock);
}

static OSStatus gameQueueNewOutput(const AudioStreamBasicDescription *format, AudioQueueOutputCallback cb, void *data,
                                   CFRunLoopRef loop, CFStringRef mode, UInt32 flags, AudioQueueRef *out) {
  startPlaybackSession();
  OSStatus status = AudioQueueNewOutput(format, cb, data, loop, mode, flags, out);
  if (status == noErr && out && *out) noteQueue(*out);
  return status;
}

static OSStatus gameQueueNewInput(const AudioStreamBasicDescription *format, AudioQueueInputCallback cb, void *data,
                                  CFRunLoopRef loop, CFStringRef mode, UInt32 flags, AudioQueueRef *out) {
  OSStatus status = AudioQueueNewInput(format, cb, data, loop, mode, flags, out);
  if (status == noErr && out && *out) noteQueue(*out);
  return status;
}

static OSStatus gameQueueNewOutputBlock(AudioQueueRef *out, const AudioStreamBasicDescription *format, UInt32 flags,
                                        dispatch_queue_t queue, AudioQueueOutputCallbackBlock block) {
  startPlaybackSession();
  OSStatus status = AudioQueueNewOutputWithDispatchQueue(out, format, flags, queue, block);
  if (status == noErr && out && *out) noteQueue(*out);
  return status;
}

static OSStatus gameQueueDispose(AudioQueueRef q, Boolean immediate) {
  pthread_mutex_lock(&gUnitsLock);
  [gQueues removeObject:[NSValue valueWithPointer:q]];
  pthread_mutex_unlock(&gUnitsLock);
  return AudioQueueDispose(q, immediate);
}

static OSStatus gameInstanceNew(AudioComponent component, AudioComponentInstance *out) {
  OSStatus status = AudioComponentInstanceNew(component, out);
  if (status == noErr && out && *out) {
    pthread_mutex_lock(&gUnitsLock);
    if (!gUnits) gUnits = [NSMutableSet set];
    [gUnits addObject:[NSValue valueWithPointer:*out]];
    pthread_mutex_unlock(&gUnitsLock);
  }
  return status;
}

static OSStatus gameInstanceDispose(AudioComponentInstance unit) {
  pthread_mutex_lock(&gUnitsLock);
  [gUnits removeObject:[NSValue valueWithPointer:unit]];
  pthread_mutex_unlock(&gUnitsLock);
  return AudioComponentInstanceDispose(unit);
}

// Stopped first (its threads may still be running), released once they aren't (AKGameAudioRelease).
void AKGameAudioStop(void) {
  NSArray<NSValue *> *units, *queues;
  pthread_mutex_lock(&gUnitsLock);
  units = gUnits.allObjects;
  queues = gQueues.allObjects;
  pthread_mutex_unlock(&gUnitsLock);
  for (NSValue *v in units) AudioOutputUnitStop((AudioUnit)v.pointerValue);
  for (NSValue *v in queues) AudioQueueStop((AudioQueueRef)v.pointerValue, true);
  @synchronized (AVAudioSession.class) {
    gSessionStarted = NO;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
  }
  fprintf(stderr, "[AppKitShim] game audio: stopped (%lu output units, %lu queues, and the session)\n", (unsigned long)units.count,
          (unsigned long)queues.count);
}

void AKGameAudioRelease(void) {
  NSArray<NSValue *> *units, *queues;
  pthread_mutex_lock(&gUnitsLock);
  units = gUnits.allObjects;
  queues = gQueues.allObjects;
  [gUnits removeAllObjects];
  [gQueues removeAllObjects];
  pthread_mutex_unlock(&gUnitsLock);
  for (NSValue *v in units) AudioComponentInstanceDispose((AudioUnit)v.pointerValue);
  for (NSValue *v in queues) AudioQueueDispose((AudioQueueRef)v.pointerValue, true);
}

void AKGameBindAudio(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (strcmp(symbol, "_AudioComponentFindNext") == 0) return (void *)gameFindNext;
    if (strcmp(symbol, "_AudioComponentInstanceNew") == 0) return (void *)gameInstanceNew;
    if (strcmp(symbol, "_AudioComponentInstanceDispose") == 0) return (void *)gameInstanceDispose;
    if (strcmp(symbol, "_AudioQueueNewOutput") == 0) return (void *)gameQueueNewOutput;
    if (strcmp(symbol, "_AudioQueueNewInput") == 0) return (void *)gameQueueNewInput;
    if (strcmp(symbol, "_AudioQueueNewOutputWithDispatchQueue") == 0) return (void *)gameQueueNewOutputBlock;
    if (strcmp(symbol, "_AudioQueueDispose") == 0) return (void *)gameQueueDispose;
    return NULL;
  });
}
