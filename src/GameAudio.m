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

static void startPlaybackSession(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSError *error;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error])
      fprintf(stderr, "[AppKitShim] game audio: the audio session didn't start: %s\n", error.localizedDescription.UTF8String);
  });
}

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

// The output units the game made: a game Steam ends without its asking stops sounding with it
// (its units would otherwise go on pulling sound from its code).
static NSMutableSet<NSValue *> *gUnits;
static pthread_mutex_t gUnitsLock = PTHREAD_MUTEX_INITIALIZER;

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

void AKGameAudioStop(void) {
  NSArray<NSValue *> *units;
  pthread_mutex_lock(&gUnitsLock);
  units = gUnits.allObjects;
  [gUnits removeAllObjects];
  pthread_mutex_unlock(&gUnitsLock);
  for (NSValue *v in units) AudioOutputUnitStop((AudioUnit)v.pointerValue);
  if (units.count) fprintf(stderr, "[AppKitShim] game audio: %lu output units stopped\n", (unsigned long)units.count);
}

void AKGameBindAudio(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (strcmp(symbol, "_AudioComponentFindNext") == 0) return (void *)gameFindNext;
    if (strcmp(symbol, "_AudioComponentInstanceNew") == 0) return (void *)gameInstanceNew;
    if (strcmp(symbol, "_AudioComponentInstanceDispose") == 0) return (void *)gameInstanceDispose;
    return NULL;
  });
}
